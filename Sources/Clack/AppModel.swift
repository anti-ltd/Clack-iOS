import SwiftUI

@Observable
@MainActor
final class AppModel {
    /// Persisted identity + display name; shared with the channel manager.
    let settings = AppSettings()

    /// Recent transmission transcripts (live captions + history).
    let transcript = TranscriptStore()

    /// Lone-worker location sharing + the channel map.
    let location: LocationService

    /// Bridge to Apple's PushToTalk framework + LiveKit transport — owns the
    /// active channel, transmit/receive state, and the system PTT UI.
    let channels: ChannelManager

    /// The channels the user can talk on. Placeholder seed until we wire up
    /// real channel storage / invites.
    var channels_directory: [Channel] = Channel.samples

    init() {
        let location = LocationService(settings: settings)
        self.location = location
        channels = ChannelManager(settings: settings, transcript: transcript, location: location)
    }
}

/// A talk channel. Maps onto a PushToTalk `PTChannel` once joined, and a LiveKit
/// room named by `id.uuidString`.
struct Channel: Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String   // SF Symbol shown on the channel row

    // Channel ids must be STABLE and identical across devices — they key both
    // the LiveKit room and the PushToTalk channel, so two phones only meet if
    // they share the same UUID. Hard-coded until real channel storage/invites
    // land (random per-launch UUIDs would put every device in its own room).
    static let samples: [Channel] = [
        Channel(id: UUID(uuidString: "C1AC0000-0000-4000-8000-000000000001")!, name: "Family", symbol: "house.fill"),
        Channel(id: UUID(uuidString: "C1AC0000-0000-4000-8000-000000000002")!, name: "Crew", symbol: "person.3.fill"),
        Channel(id: UUID(uuidString: "C1AC0000-0000-4000-8000-000000000003")!, name: "Trail", symbol: "figure.hiking"),
    ]

    /// Resolve a channel by its UUID — used when PushToTalk hands us back a bare
    /// channel id (restoration, incoming push).
    static func sample(for id: UUID) -> Channel? {
        samples.first { $0.id == id }
    }
}
