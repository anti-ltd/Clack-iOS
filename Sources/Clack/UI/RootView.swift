import SwiftUI
import iUXiOS

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
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
            }
            .navigationTitle("Clack")
            .safeAreaInset(edge: .bottom) {
                TalkButton(state: model.channels.talkState,
                           joined: model.channels.joinedChannel != nil,
                           onDown: { model.channels.beginTransmitting() },
                           onUp: { model.channels.stopTransmitting() })
                    .padding()
            }
        }
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
