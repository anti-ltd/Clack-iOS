import SwiftUI
import iUXiOS
@preconcurrency import Translation

struct RootView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composeFocused: Bool

    var body: some View {
        content
            .modifier(TranscriptTranslation(store: model.transcript))
    }

    private var content: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Your name") {
                        TextField("Your name", text: Binding(
                            get: { model.settings.displayName },
                            set: { model.settings.displayName = $0 }))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    }
                    LabeledContent("PushToTalk",
                                   value: model.channels.isActivated ? "Ready" : "Not ready")
                    if let error = model.channels.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Toggle("Share my location", isOn: Binding(
                        get: { model.location.isSharing },
                        set: { model.location.setSharing($0) }))
                    NavigationLink {
                        MapScreen()
                    } label: {
                        Label("Channel map", systemImage: "map")
                    }
                }
                Section("Channels") {
                    ForEach(model.channels_directory) { channel in
                        ChannelRow(
                            channel: channel,
                            isJoined: model.channels.joinedChannel?.id == channel.id
                        ) {
                            if model.channels.joinedChannel?.id == channel.id {
                                model.channels.leave()
                            } else {
                                model.channels.join(channel)
                            }
                        }
                    }
                }
                if !model.transcript.entries.isEmpty {
                    Section("Messages") {
                        // Newest first so the latest message is at the top.
                        ForEach(model.transcript.entries.reversed()) { entry in
                            TranscriptRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle("Clack")
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.settings.displayName) { _, _ in
                model.channels.updateDisplayName()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if model.channels.joinedChannel != nil {
                        ComposeBar(focused: $composeFocused) { model.channels.sendText($0) }
                    }
                    // Hide the talk button while typing — frees room for the
                    // keyboard and avoids an accidental transmit.
                    if model.channels.joinedChannel != nil && !composeFocused {
                        TalkButton(state: model.channels.talkState,
                                   joined: true,
                                   onDown: { model.channels.beginTransmitting() },
                                   onUp: { model.channels.stopTransmitting() })
                    } else if model.channels.joinedChannel == nil {
                        TalkButton(state: model.channels.talkState,
                                   joined: false,
                                   onDown: {}, onUp: {})
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .animation(.easeInOut(duration: 0.2), value: composeFocused)
            }
        }
    }
}

/// Text compose bar — type a message to the channel and send.
private struct ComposeBar: View {
    @FocusState.Binding var focused: Bool
    let onSend: (String) -> Void
    @State private var draft = ""

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            if focused {
                Button { focused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .transition(.scale.combined(with: .opacity))
            }
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? Color.accentColor : .secondary)
            }
            .disabled(!canSend)
        }
        .animation(.easeInOut(duration: 0.15), value: focused)
    }

    private func send() {
        let text = draft
        draft = ""
        onSend(text)
    }
}

/// One channel in the directory. Tapping joins/leaves via PushToTalk.
private struct ChannelRow: View {
    let channel: Channel
    let isJoined: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: channel.symbol)
                    .frame(width: 28)
                Text(channel.name)
                Spacer()
                if isJoined {
                    Text("Joined")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

/// One transmission in the transcript history: who said it, when, and the text.
/// The translated line (added in the translation pass) sits under the original.
private struct TranscriptRow: View {
    let entry: Transmission

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: entry.kind == .voice ? "speaker.wave.2.fill" : "text.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(entry.text)
                .font(.body)
            if let translated = entry.translatedText {
                Text(translated)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The big press-and-hold talk surface. Holds = transmit, release = stop.
private struct TalkButton: View {
    let state: ChannelManager.TalkState
    let joined: Bool
    let onDown: () -> Void
    let onUp: () -> Void

    private var label: String {
        switch state {
        case .idle:               return joined ? "Hold to Talk" : "Join a channel"
        case .transmitting:       return "Talking…"
        case .receiving(let who): return "\(who) is talking"
        }
    }

    private let shape = RoundedRectangle(cornerRadius: 28)

    var body: some View {
        Text(label)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 96)
            .modifier(TalkSurfaceBackground(shape: shape, isTransmitting: state == .transmitting))
            .foregroundStyle(state == .transmitting ? .white : .primary)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if joined, state != .transmitting { onDown() } }
                    .onEnded { _ in if joined { onUp() } }
            )
            .disabled(!joined)
            .animation(.easeOut(duration: 0.15), value: state)
    }
}

/// Glass on iOS 26+, solid tinted fill below — progressive enhancement so the
/// 17+ base still gets a clean talk surface.
private struct TalkSurfaceBackground: ViewModifier {
    let shape: RoundedRectangle
    let isTransmitting: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *), !isTransmitting {
            // Idle/receiving: let the glass read through. While transmitting we
            // want a loud, opaque tint, so we fall through to the solid fill.
            content.glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: shape)
        } else {
            content.background(
                .tint.opacity(isTransmitting ? 0.9 : 0.15), in: shape)
        }
    }
}

/// Translates foreign transcript lines to the device language via Apple's
/// on-device Translation framework (iOS 18+). A no-op below that.
private struct TranscriptTranslation: ViewModifier {
    let store: TranscriptStore

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(TranslationDriver(store: store))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct TranslationDriver: ViewModifier {
    let store: TranscriptStore
    @State private var config: TranslationSession.Configuration?
    /// Source language the current config is translating from.
    @State private var activeSource: String?

    private var deviceCode: String? { Locale.current.language.languageCode?.identifier }

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                guard let source = activeSource else { return }
                // Translate every untranslated line in the *current* source
                // language. Mark each attempted so a pair that can't translate
                // isn't retried endlessly.
                let targets = store.entries.filter {
                    $0.translatedText == nil && !$0.translationAttempted
                        && $0.sourceLanguage == source
                }
                for entry in targets {
                    if let response = try? await session.translate(entry.text),
                       response.targetText != entry.text {
                        store.setTranslation(entry.id, response.targetText)
                    } else {
                        store.markTranslationAttempted(entry.id)
                    }
                }
                // Move on to the next language that still needs translating.
                advance()
            }
            .onAppear { advance() }
            .onChange(of: store.entries.count) { _, _ in if config == nil { advance() } }
    }

    /// Pick the next untranslated foreign language and configure a session for
    /// it (explicit source → the framework knows which model to load). Clearing
    /// the config when nothing's left lets the next incoming line restart us.
    private func advance() {
        guard let device = deviceCode else { config = nil; activeSource = nil; return }
        let next = store.entries.first {
            $0.translatedText == nil && !$0.translationAttempted
                && !$0.sourceLanguage.hasPrefix(device)
        }?.sourceLanguage
        if let next {
            activeSource = next
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: next),
                target: Locale.current.language)
        } else {
            activeSource = nil
            config = nil
        }
    }
}
