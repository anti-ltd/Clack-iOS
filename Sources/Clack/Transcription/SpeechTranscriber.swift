import Foundation
import Speech
import AVFAudio
import LiveKit

// Transcribes the local speaker's outgoing audio. Rather than open a second mic
// session (which would fight PushToTalk + LiveKit for the audio engine), it taps
// LiveKit's local microphone track as an `AudioRenderer` and feeds those PCM
// buffers to Apple's on-device speech recognizer. Best quality, since it sees
// the clean captured audio, and zero extra audio-session contention.
final class SpeechTranscriber: NSObject, AudioRenderer, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""

    /// Locale of the recognizer — sent with the transcript so receivers know the
    /// source language to translate from.
    let localeIdentifier: String

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
        localeIdentifier = locale.identifier
    }

    /// Prompt for speech-recognition permission. Mic permission is already
    /// covered by PushToTalk. Call once at startup.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Begin a recognition pass. Call right before attaching as a renderer.
    func start() {
        guard let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device when the locale model is installed (private, offline).
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        lock.withLock { latest = "" }
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            self.lock.withLock { self.latest = result.bestTranscription.formattedString }
        }
        request = req
    }

    // Called on LiveKit's audio thread for every captured buffer.
    func render(pcmBuffer: AVAudioPCMBuffer) {
        request?.append(pcmBuffer)
    }

    /// Stop capture, give the recognizer a beat to flush the final result, and
    /// return the transcript (may be empty if nothing intelligible was said).
    func finish() async -> String {
        request?.endAudio()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let text = lock.withLock { latest }
        task?.finish()
        task = nil
        request = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
