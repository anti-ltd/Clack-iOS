import Foundation
import NaturalLanguage

/// Whether a message was spoken (voice transcript) or typed.
enum MessageKind: String, Codable, Sendable {
    case voice
    case text
}

/// One channel message — a voice transcript or a typed message — shared over
/// the LiveKit data channel and persisted to the backend for history.
struct Transmission: Identifiable, Hashable, Sendable {
    let id: UUID
    let speaker: String
    let kind: MessageKind
    /// Language code of the *text* (e.g. "es", "nl"). Detected from the words,
    /// not the speaker's keyboard locale — the recogniser may transcribe foreign
    /// words under its own locale, so the text is the source of truth.
    var sourceLanguage: String
    let text: String
    var translatedText: String?
    /// Set once we've run a translation pass for this line (success or not), so
    /// a language pair that can't translate doesn't get retried forever.
    var translationAttempted = false
    let date: Date

    /// Detect the dominant language of `text` ("es", "en", "nl", …).
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

/// The wire form sent over the LiveKit data channel (topic "message") and the
/// backend message store.
struct TranscriptMessage: Codable, Sendable {
    let id: UUID
    let speaker: String
    let kind: MessageKind
    let lang: String
    let text: String
    let ts: Double   // epoch seconds

    init(_ t: Transmission) {
        id = t.id
        speaker = t.speaker
        kind = t.kind
        lang = t.sourceLanguage
        text = t.text
        ts = t.date.timeIntervalSince1970
    }

    var transmission: Transmission {
        Transmission(id: id, speaker: speaker, kind: kind, sourceLanguage: lang,
                     text: text, translatedText: nil, date: Date(timeIntervalSince1970: ts))
    }
}

/// Backend message-history response (`GET /v1/messages`).
struct MessagesResponse: Decodable, Sendable {
    let messages: [Row]

    struct Row: Decodable, Sendable {
        let id: String
        let name: String
        let kind: MessageKind
        let lang: String?
        let text: String
        let ts: Double   // epoch ms
    }

    var transmissions: [Transmission] {
        messages.compactMap { r in
            guard let uuid = UUID(uuidString: r.id) else { return nil }
            return Transmission(
                id: uuid, speaker: r.name, kind: r.kind,
                sourceLanguage: r.lang ?? Transmission.detectLanguage(r.text) ?? "en",
                text: r.text, translatedText: nil,
                date: Date(timeIntervalSince1970: r.ts / 1000))
        }
    }
}

/// In-memory store of recent channel messages (voice transcripts + text),
/// oldest → newest. Capped; the backend holds the durable history.
@Observable
@MainActor
final class TranscriptStore {
    private(set) var entries: [Transmission] = []   // oldest → newest
    private let limit = 200

    func add(_ t: Transmission) {
        // Ignore duplicates (our own echo, redelivery).
        guard !entries.contains(where: { $0.id == t.id }) else { return }
        entries.append(t)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// Merge fetched history: add new entries, keep chronological, cap.
    func merge(_ items: [Transmission]) {
        let existing = Set(entries.map(\.id))
        let fresh = items.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        entries = (entries + fresh).sorted { $0.date < $1.date }
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func setTranslation(_ id: UUID, _ translated: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].translatedText = translated
        entries[i].translationAttempted = true
    }

    func markTranslationAttempted(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].translationAttempted = true
    }

    func clear() { entries.removeAll() }
}
