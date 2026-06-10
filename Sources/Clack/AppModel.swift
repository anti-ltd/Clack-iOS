import SwiftUI

@Observable
@MainActor
final class AppModel {
    /// Bridge to Apple's PushToTalk framework — owns the active channel,
    /// transmit/receive state, and the system PTT UI.
    let channels = ChannelManager()

    /// The channels the user can talk on. Placeholder seed until we wire up
    /// real channel storage / invites.
    var channels_directory: [Channel] = Channel.samples
}

/// A talk channel. Maps onto a PushToTalk `PTChannel` once joined.
struct Channel: Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String   // SF Symbol shown on the channel row

    static let samples: [Channel] = [
        Channel(id: UUID(), name: "Family", symbol: "house.fill"),
        Channel(id: UUID(), name: "Crew", symbol: "person.3.fill"),
        Channel(id: UUID(), name: "Trail", symbol: "figure.hiking"),
    ]
}
