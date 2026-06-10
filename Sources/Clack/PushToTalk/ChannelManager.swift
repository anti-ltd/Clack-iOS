import Foundation
import Observation
#if canImport(PushToTalk)
import PushToTalk
#endif

// Bridge to Apple's PushToTalk framework.
//
// PushToTalk is what makes Clack a *real* walkie-talkie rather than a foreground
// VoIP toy: joining a channel hands iOS a `PTChannelManager`, and from then on
// the system owns the UX — the blue status pill, the lock-screen "joined"
// banner, the leading lock-screen talk button, and audio-session ducking. Our
// job is just to (1) join/leave, (2) ask to begin/stop transmitting, and (3)
// hand the framework an APNs token so incoming transmissions can wake the app.
//
// SKELETON: the actual voice transport (capturing the mic, shipping packets to
// peers, and your server sending `pushtotalk` APNs payloads to invoke
// `incomingPushResult`) is not implemented here — that's the next milestone.
// What exists is the full PTChannelManager lifecycle so the system UI lights up
// on a real device. Note: PushToTalk needs the entitlement AND a physical
// device; it is unavailable in the simulator.

@Observable
@MainActor
final class ChannelManager {
    enum TalkState: Equatable {
        case idle              // not transmitting; may or may not be joined
        case transmitting      // local user is holding the talk button
        case receiving(String) // a remote participant is talking
    }

    private(set) var joinedChannel: Channel?
    private(set) var talkState: TalkState = .idle
    private(set) var isActivated = false

    #if canImport(PushToTalk)
    private var manager: PTChannelManager?
    private let coordinator = Coordinator()
    #endif

    /// Stand up the PTChannelManager. Safe to call repeatedly; no-ops once active.
    func activate() async {
        #if canImport(PushToTalk)
        guard manager == nil else { return }
        coordinator.owner = self
        do {
            manager = try await PTChannelManager.channelManager(
                delegate: coordinator,
                restorationDelegate: coordinator)
            isActivated = true
        } catch {
            // TODO: surface a "PushToTalk unavailable" state to the UI.
            isActivated = false
        }
        #else
        isActivated = false
        #endif
    }

    /// Join `channel` and present the system PTT UI.
    func join(_ channel: Channel) {
        #if canImport(PushToTalk)
        guard let manager else { return }
        let descriptor = PTChannelDescriptor(name: channel.name, image: nil)
        manager.requestJoinChannel(channelUUID: channel.id, descriptor: descriptor)
        #else
        joinedChannel = channel   // preview / simulator fallback
        #endif
    }

    func leave() {
        #if canImport(PushToTalk)
        guard let manager, let id = joinedChannel?.id else { return }
        manager.leaveChannel(channelUUID: id)
        #else
        joinedChannel = nil
        talkState = .idle
        #endif
    }

    /// Press-and-hold the talk button. The system grants or denies the request
    /// (it can refuse e.g. while on a phone call); we reflect its callback.
    func beginTransmitting() {
        #if canImport(PushToTalk)
        guard let manager, let id = joinedChannel?.id else { return }
        manager.requestBeginTransmitting(channelUUID: id)
        #else
        talkState = .transmitting
        #endif
    }

    func stopTransmitting() {
        #if canImport(PushToTalk)
        guard let manager, let id = joinedChannel?.id else { return }
        manager.stopTransmitting(channelUUID: id)
        #else
        talkState = .idle
        #endif
    }

    // MARK: - Callbacks from the framework (hopped back onto the main actor)

    fileprivate func didJoin(_ uuid: UUID) {
        joinedChannel = (joinedChannel?.id == uuid)
            ? joinedChannel
            : nil   // resolved against the directory by the caller in a real build
    }

    fileprivate func didLeave() {
        joinedChannel = nil
        talkState = .idle
    }

    fileprivate func beganTransmitting() { talkState = .transmitting }
    fileprivate func endedTransmitting() { talkState = .idle }
    fileprivate func remoteBegan(_ name: String) { talkState = .receiving(name) }
    fileprivate func remoteEnded() { talkState = .idle }
}

#if canImport(PushToTalk)
// The framework's delegates are plain (non-main-actor) callbacks, so the
// coordinator is a separate NSObject that hops every event back onto the
// ChannelManager's main actor. Keeps the Observable model concurrency-clean.
private final class Coordinator: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate, @unchecked Sendable {
    weak var owner: ChannelManager?

    // MARK: PTChannelManagerDelegate

    func channelManager(_ m: PTChannelManager, didJoinChannel uuid: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor in owner?.didJoin(uuid) }
    }

    func channelManager(_ m: PTChannelManager, didLeaveChannel uuid: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor in owner?.didLeave() }
    }

    func channelManager(_ m: PTChannelManager, channelUUID uuid: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in owner?.beganTransmitting() }
    }

    func channelManager(_ m: PTChannelManager, channelUUID uuid: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in owner?.endedTransmitting() }
    }

    func channelManager(_ m: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        // TODO: ship this token to our server so it can send `pushtotalk`
        // APNs payloads that wake Clack for incoming transmissions.
    }

    func incomingPushResult(channelManager m: PTChannelManager, channelUUID uuid: UUID, pushPayload: [String: Any]) -> PTPushResult {
        // TODO: decode the speaker from the payload and return an active
        // participant so the system shows who's talking.
        let speaker = pushPayload["speaker"] as? String ?? "Someone"
        Task { @MainActor in owner?.remoteBegan(speaker) }
        return .leaveChannel   // placeholder — replace with .activeRemoteParticipant(...)
    }

    func channelManager(_ m: PTChannelManager, didActivate audioSession: AVAudioSession) {
        // Configure/begin audio capture here once voice transport lands.
    }

    func channelManager(_ m: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in owner?.remoteEnded() }
    }

    // MARK: PTChannelRestorationDelegate

    func channelDescriptor(restoredChannelUUID uuid: UUID) -> PTChannelDescriptor {
        // Called when iOS restores a channel after the app was killed. Look the
        // channel up by UUID in real storage; placeholder name for now.
        PTChannelDescriptor(name: "Clack", image: nil)
    }
}
#endif
