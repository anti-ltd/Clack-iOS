import Foundation
import Observation
import AVFAudio
import UIKit
import OSLog
import LiveKit
#if canImport(PushToTalk)
import PushToTalk
#endif

// Bridge between Apple's PushToTalk framework and the LiveKit voice transport.
//
// Division of labour:
//   • PushToTalk owns the *system UX and the audio session* — the blue pill, the
//     lock-screen talk button, waking the app via `pushtotalk` APNs, and
//     activating/deactivating AVAudioSession. We hand it that control by turning
//     LiveKit's automatic audio-session configuration OFF.
//   • LiveKit owns the *audio* — one room per channel. We connect on join (mic
//     muted), unmute while transmitting, and auto-subscribe to remote speakers.
//   • Clack-Worker glues them: mints LiveKit tokens, stores our ephemeral PTT
//     token, and fans out `pushtotalk` APNs when we start transmitting so other
//     members' phones wake.
//
// PushToTalk needs the entitlement AND a physical device (unavailable in the
// simulator); the `#if canImport(PushToTalk)` fallbacks keep previews building.

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

    /// Last error surfaced to the UI for debugging (PT init/join failures,
    /// LiveKit connect failures). Shown in RootView while we bring transport up.
    private(set) var lastError: String?

    private let settings: AppSettings
    private let transcript: TranscriptStore
    private let location: LocationService
    private let transcriber = SpeechTranscriber()
    nonisolated static let messageTopic = "message"
    private let backend = Backend()
    // Recreated on every connect: reusing a Room across disconnect→reconnect
    // leaves stale m-line state in the peer connection and the next SDP offer
    // fails with "order of m-lines … doesn't match".
    private var room = Room()
    private let log = Logger(subsystem: "ltd.anti.clack", category: "ptt")

    #if canImport(PushToTalk)
    private var manager: PTChannelManager?
    #endif
    private let coordinator = Coordinator()

    /// Set while switching channels: the channel to join once the current one
    /// finishes leaving (PushToTalk allows only one joined channel).
    private var pendingJoin: Channel?

    /// LiveKit connect serialization + dedupe (avoids duplicate-identity).
    private var connectTask: Task<Void, Never>?
    private var desiredChannel: Channel?
    private var activeRoomChannel: Channel?

    /// Backstop that clears a stuck "<name> is talking" if every end-signal
    /// (speaker-empty, track unpublish/mute) is missed.
    private var receiveWatchdog: Timer?
    private let receiveTimeout: TimeInterval = 90

    init(settings: AppSettings, transcript: TranscriptStore, location: LocationService) {
        self.settings = settings
        self.transcript = transcript
        self.location = location
        coordinator.owner = self
        room.add(delegate: coordinator)
    }

    private var identity: String { settings.identity }
    private var displayName: String { settings.displayName }
    private func roomName(_ channel: Channel) -> String { channel.id.uuidString }

    /// Stand up the PTChannelManager and hand audio-session control to it.
    /// Safe to call repeatedly; no-ops once active.
    func activate() async {
        // LiveKit must NOT touch AVAudioSession — PushToTalk activates it for us
        // inside `didActivate`/`didDeactivate`. Keep the engine unavailable until
        // the system opens that window.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
        // Keep the mic capture path warm so transmissions start cleanly instead
        // of spinning the recording engine up cold (a cause of missing audio at
        // the start of a transmission).
        try? await AudioManager.shared.setRecordingAlwaysPreparedMode(true)

        // Ask for speech-recognition permission up front so the first
        // transmission can be transcribed without a mid-talk prompt.
        _ = await SpeechTranscriber.requestAuthorization()

        #if canImport(PushToTalk)
        guard manager == nil else { return }
        do {
            manager = try await PTChannelManager.channelManager(
                delegate: coordinator,
                restorationDelegate: coordinator)
            isActivated = true
            log.info("PTChannelManager activated")
        } catch {
            isActivated = false
            lastError = "PTT init failed: \(error.localizedDescription)"
            log.error("PTChannelManager activate failed: \(error.localizedDescription, privacy: .public)")
        }
        #else
        isActivated = false
        #endif
    }

    /// Join `channel` and present the system PTT UI. The LiveKit room is
    /// connected once the framework confirms the join (`didJoin`).
    ///
    /// PushToTalk only permits ONE joined channel at a time — requesting a join
    /// while already joined fails with `PTChannelErrorChannelLimitReached`
    /// (channel error 2). So if we're switching channels, leave the current one
    /// first and join the new one once `didLeave` lands.
    func join(_ channel: Channel) {
        #if canImport(PushToTalk)
        guard let manager else { return }
        if let current = joinedChannel {
            guard current.id != channel.id else { return }   // already joined
            pendingJoin = channel
            manager.leaveChannel(channelUUID: current.id)
            return
        }
        requestJoin(channel)
        #else
        joinedChannel = channel
        #endif
    }

    #if canImport(PushToTalk)
    private func requestJoin(_ channel: Channel) {
        let descriptor = PTChannelDescriptor(name: channel.name, image: nil)
        manager?.requestJoinChannel(channelUUID: channel.id, descriptor: descriptor)
    }
    #endif

    func leave() {
        #if canImport(PushToTalk)
        guard let manager, let id = joinedChannel?.id else { return }
        manager.leaveChannel(channelUUID: id)
        #else
        joinedChannel = nil
        talkState = .idle
        #endif
    }

    /// Press-and-hold. The framework grants or denies (e.g. refuses during a
    /// phone call); we unmute the mic from the `didBeginTransmitting` callback.
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

    // MARK: - LiveKit room lifecycle

    /// Connect to `channel`'s LiveKit room. Serialized through `connectTask` so
    /// overlapping triggers (didJoin + an incoming push, restoration + join…)
    /// can't run two connects at once — connecting the same identity to the same
    /// room twice is rejected as "duplicate participant identity".
    private func connectRoom(_ channel: Channel) {
        desiredChannel = channel
        let previous = connectTask
        connectTask = Task { [weak self] in
            await previous?.value
            guard let self, self.desiredChannel?.id == channel.id else { return }
            await self.performConnect(channel)
        }
    }

    /// Disconnect, also serialized so it can't interleave with a connect.
    private func disconnectRoom() {
        desiredChannel = nil
        let previous = connectTask
        connectTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.room.disconnect()
            self.activeRoomChannel = nil
        }
    }

    private func performConnect(_ channel: Channel) async {
        // Already on this exact channel — reconnecting would duplicate identity.
        if room.connectionState == .connected, activeRoomChannel?.id == channel.id { return }
        // Tear down any prior connection and start from a FRESH Room so the new
        // SDP negotiation isn't tripped up by leftover m-lines.
        await room.disconnect()
        activeRoomChannel = nil
        let r = Room()
        r.add(delegate: coordinator)
        room = r
        do {
            let res = try await backend.token(
                channel: roomName(channel), identity: identity, name: displayName)
            try await r.connect(url: res.url, token: res.token)
            try await r.localParticipant.set(name: displayName)
            try await r.localParticipant.setMicrophone(enabled: false)
            activeRoomChannel = channel
            await fetchMessageHistory(channel)
            log.info("LiveKit connected to room \(self.roomName(channel), privacy: .public)")
        } catch {
            lastError = "Room connect failed: \(error.localizedDescription)"
            log.error("LiveKit connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setMicrophone(_ enabled: Bool) async {
        try? await room.localParticipant.setMicrophone(enabled: enabled)
    }

    /// Push the current display name to the connected LiveKit participant so the
    /// live "<name> is talking" label (driven by LiveKit speaker events) reflects
    /// a rename instead of falling back to the name set at connect time.
    func updateDisplayName() {
        Task { try? await room.localParticipant.set(name: displayName) }
    }

    // MARK: - Callbacks from the framework / room (hopped onto the main actor)

    fileprivate func didJoin(_ uuid: UUID) {
        log.info("didJoinChannel \(uuid, privacy: .public)")
        let channel = joinedChannel?.id == uuid ? joinedChannel : Channel.sample(for: uuid)
        guard let channel else { return }
        joinedChannel = channel
        lastError = nil
        location.setChannel(channel)
        connectRoom(channel)
    }

    fileprivate func joinFailed(uuid: UUID, limitReached: Bool, message: String) {
        #if canImport(PushToTalk)
        if limitReached {
            // The single PT channel slot is occupied by a channel we've lost
            // track of (a stale restore, or an old build's random-UUID channel).
            // Queue the requested channel and leave every channel we might be in
            // — whichever leave succeeds fires `didLeave`, which then joins the
            // queued one.
            pendingJoin = Channel.sample(for: uuid)
            log.error("join hit channel limit; leaving known channels to free the slot")
            for ch in Channel.samples { manager?.leaveChannel(channelUUID: ch.id) }
            return
        }
        #endif
        lastError = "Join failed: \(message)"
        log.error("failedToJoinChannel: \(message, privacy: .public)")
    }

    fileprivate func didLeave() {
        joinedChannel = nil
        talkState = .idle
        location.setChannel(nil)
        #if canImport(PushToTalk)
        // Mid-switch: join the queued channel now that the old one is released.
        // connectRoom() handles dropping the old LiveKit room, so don't
        // disconnect here or we'd race the upcoming connect.
        if let next = pendingJoin {
            pendingJoin = nil
            requestJoin(next)
            return
        }
        #endif
        disconnectRoom()
    }

    fileprivate func beganTransmitting() {
        talkState = .transmitting
        guard let channel = joinedChannel else { return }
        Task {
            await setMicrophone(true)
            // Tap the freshly-published mic track and start transcribing.
            transcriber.start()
            localMicTrack()?.add(audioRenderer: transcriber)
            try? await backend.transmitStart(
                channel: roomName(channel), identity: identity, name: displayName)
        }
    }

    fileprivate func endedTransmitting() {
        talkState = .idle
        // Stop tapping, flush the transcript, THEN unpublish the mic. We
        // deliberately don't send a "stop" push: a pushtotalk push can only
        // return an *active* participant (the PTPushResult enum has no "nobody
        // talking" case), so it would re-wedge the receiver on "… is talking".
        // The receiver clears when LiveKit reports the speaker stopped.
        localMicTrack()?.remove(audioRenderer: transcriber)
        Task {
            let text = await transcriber.finish()
            await setMicrophone(false)
            await publishTranscript(text)
        }
    }

    private func localMicTrack() -> LocalAudioTrack? {
        room.localParticipant.localAudioTracks.first?.track as? LocalAudioTrack
    }

    /// Share a voice transcript with the channel.
    private func publishTranscript(_ text: String) async {
        guard !text.isEmpty else { return }
        let lang = Transmission.detectLanguage(text) ?? transcriber.localeIdentifier
        let entry = Transmission(id: UUID(), speaker: displayName, kind: .voice,
                                 sourceLanguage: lang,
                                 text: text, translatedText: nil, date: Date())
        transcript.add(entry)
        await broadcast(entry)
    }

    /// Send a typed text message to the channel.
    func sendText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, joinedChannel != nil else { return }
        let lang = Transmission.detectLanguage(text) ?? Locale.current.language.languageCode?.identifier ?? "en"
        let entry = Transmission(id: UUID(), speaker: displayName, kind: .text,
                                 sourceLanguage: lang,
                                 text: text, translatedText: nil, date: Date())
        transcript.add(entry)
        Task { await broadcast(entry) }
    }

    /// Deliver a message live over the LiveKit data channel AND persist it to the
    /// backend for history (members who were offline pick it up on next fetch).
    private func broadcast(_ entry: Transmission) async {
        let message = TranscriptMessage(entry)
        if let data = try? JSONEncoder().encode(message) {
            let opts = DataPublishOptions(topic: Self.messageTopic, reliable: true)
            try? await room.localParticipant.publish(data: data, options: opts)
        }
        if let channel = joinedChannel {
            try? await backend.postMessage(channel: roomName(channel), identity: identity, message)
        }
    }

    /// A message arrived from another participant over the data channel.
    fileprivate func didReceiveTranscript(_ message: TranscriptMessage) {
        var entry = message.transmission
        // Re-derive the language from the words — the sender's locale is an
        // unreliable hint (e.g. an English recogniser transcribing "Hola").
        if let detected = Transmission.detectLanguage(entry.text) {
            entry.sourceLanguage = detected
        }
        transcript.add(entry)
    }

    /// Pull the channel's message history (≤24h) and merge it into the store.
    private func fetchMessageHistory(_ channel: Channel) async {
        if let items = try? await backend.fetchMessages(channel: roomName(channel)) {
            transcript.merge(items)
        }
    }

    /// Driven by LiveKit's active-speaker updates. While we're transmitting we
    /// ignore them (our own voice); otherwise the first remote speaker drives
    /// the "<name> is talking" state. Empty → the transmission ended.
    fileprivate func remoteSpeaking(_ names: [String]) {
        if case .transmitting = talkState { return }
        if let speaker = names.first {
            enterReceiving(speaker)
        } else {
            clearReceiving()
        }
    }

    /// A remote audio track was unpublished or muted — a definitive end signal,
    /// more reliable than waiting for an empty speaker update.
    fileprivate func remoteStopped() {
        if case .receiving = talkState { clearReceiving() }
    }

    private func enterReceiving(_ speaker: String) {
        talkState = .receiving(speaker)
        // (Re)arm the backstop in case every explicit end-signal is missed.
        receiveWatchdog?.invalidate()
        receiveWatchdog = Timer.scheduledTimer(withTimeInterval: receiveTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.remoteStopped() }
        }
    }

    private func clearReceiving() {
        receiveWatchdog?.invalidate()
        receiveWatchdog = nil
        if case .transmitting = talkState { return }
        talkState = .idle
        endIncoming()
    }

    /// Tell the system the incoming transmission is over so it tears the audio
    /// session back down.
    private func endIncoming() {
        #if canImport(PushToTalk)
        guard let manager, let id = joinedChannel?.id else { return }
        manager.setActiveRemoteParticipant(nil, channelUUID: id, completionHandler: nil)
        #endif
    }

    fileprivate func registerPushToken(_ token: Data) {
        guard let channel = joinedChannel else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task {
            try? await backend.registerPushToken(
                channel: roomName(channel), identity: identity, name: displayName, token: hex)
        }
    }

    /// A `pushtotalk` push woke us for an incoming transmission. Resolve the
    /// channel, ensure the LiveKit room is connected so the audio plays, and
    /// reflect the speaker.
    fileprivate func handleIncoming(channelUUID uuid: UUID, speaker: String) {
        let channel = joinedChannel?.id == uuid ? joinedChannel : Channel.sample(for: uuid)
        guard let channel else { return }
        joinedChannel = channel
        enterReceiving(speaker)
        location.setChannel(channel)
        connectRoom(channel)
    }

    /// PushToTalk restored a channel joined in a previous session (the app was
    /// killed while joined). Reflect it as joined and reconnect the room so our
    /// state matches the system's — otherwise we'd think nothing is joined and a
    /// fresh join would fail with `PTChannelErrorChannelLimitReached`.
    fileprivate func handleRestored(_ uuid: UUID) {
        guard joinedChannel?.id != uuid else { return }
        guard let channel = Channel.sample(for: uuid) else {
            // Unknown channel — e.g. an old build's random-UUID channel still
            // occupying the single PT slot. Abandon it so the user can join a
            // real channel.
            #if canImport(PushToTalk)
            log.error("restored unknown channel \(uuid, privacy: .public); leaving it")
            manager?.leaveChannel(channelUUID: uuid)
            #endif
            return
        }
        joinedChannel = channel
        log.info("restored channel \(uuid, privacy: .public)")
        location.setChannel(channel)
        connectRoom(channel)
    }

    // MARK: - Audio session (PushToTalk owns it)

    fileprivate func audioSessionActivated(_ session: AVAudioSession) {
        // The system has activated the session; configure it for voice and open
        // the LiveKit engine so capture/playback can run. `.defaultToSpeaker`
        // routes playback to the loudspeaker (a walkie-talkie is held in front
        // of you). Deliberately NO `.allowBluetooth` (BT route scanning thrashes
        // mid-call → dropouts), NO `.mixWithOthers` (lets other audio duck us),
        // and NO explicit overrideOutputAudioPort (forcing the route on every
        // activation glitches active audio — `.defaultToSpeaker` is enough).
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try? AudioManager.shared.setEngineAvailability(.default)
        log.info("audio session activated → engine .default, speaker route")
    }

    fileprivate func audioSessionDeactivated() {
        try? AudioManager.shared.setEngineAvailability(.none)
    }
}

#if canImport(PushToTalk)
// The framework's delegates and LiveKit's RoomDelegate are plain (non-main)
// callbacks. The coordinator hops every event onto the ChannelManager's main
// actor, extracting only Sendable values (UUIDs, Strings) before the hop.
private final class Coordinator: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate, RoomDelegate, @unchecked Sendable {
    weak var owner: ChannelManager?

    // MARK: PTChannelManagerDelegate

    func channelManager(_ m: PTChannelManager, didJoinChannel uuid: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor in owner?.didJoin(uuid) }
    }

    func channelManager(_ m: PTChannelManager, didLeaveChannel uuid: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor in owner?.didLeave() }
    }

    func channelManager(_ m: PTChannelManager, failedToJoinChannel uuid: UUID, error: Error) {
        let ns = error as NSError
        // PTChannelErrorChannelLimitReached = 2, domain com.apple.pushtotalk.channel.
        let limitReached = ns.code == 2 && ns.domain.contains("pushtotalk.channel")
        let message = error.localizedDescription
        Task { @MainActor in owner?.joinFailed(uuid: uuid, limitReached: limitReached, message: message) }
    }

    func channelManager(_ m: PTChannelManager, failedToLeaveChannel uuid: UUID, error: Error) {
        // Expected during recovery (we leave channels we may not be joined to);
        // not a user-facing error, so ignore.
    }

    func channelManager(_ m: PTChannelManager, channelUUID uuid: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in owner?.beganTransmitting() }
    }

    func channelManager(_ m: PTChannelManager, channelUUID uuid: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in owner?.endedTransmitting() }
    }

    func channelManager(_ m: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        Task { @MainActor in owner?.registerPushToken(pushToken) }
    }

    func incomingPushResult(channelManager m: PTChannelManager, channelUUID uuid: UUID, pushPayload: [String: Any]) -> PTPushResult {
        let speaker = pushPayload["speaker"] as? String ?? "Someone"
        Task { @MainActor in owner?.handleIncoming(channelUUID: uuid, speaker: speaker) }
        return .activeRemoteParticipant(PTParticipant(name: speaker, image: nil))
    }

    func channelManager(_ m: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in owner?.audioSessionActivated(audioSession) }
    }

    func channelManager(_ m: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in owner?.audioSessionDeactivated() }
    }

    // MARK: PTChannelRestorationDelegate

    func channelDescriptor(restoredChannelUUID uuid: UUID) -> PTChannelDescriptor {
        Task { @MainActor in owner?.handleRestored(uuid) }
        let name = Channel.sample(for: uuid)?.name ?? "Clack"
        return PTChannelDescriptor(name: name, image: nil)
    }

    // MARK: RoomDelegate

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        // Only remote speakers matter for the receive UI; extract names off the
        // delegate thread and hand the Sendable array to the main actor.
        let names = participants
            .filter { $0 != room.localParticipant }
            .map { $0.name ?? $0.identity?.stringValue ?? "Someone" }
        Task { @MainActor in owner?.remoteSpeaking(names) }
    }

    // A remote stopping transmission unpublishes (or mutes) their mic — clear
    // the receive state immediately rather than waiting for a speaker update.
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio else { return }
        Task { @MainActor in owner?.remoteStopped() }
    }

    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        guard isMuted, trackPublication.kind == .audio,
              participant != room.localParticipant else { return }
        Task { @MainActor in owner?.remoteStopped() }
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == ChannelManager.messageTopic,
              let message = try? JSONDecoder().decode(TranscriptMessage.self, from: data)
        else { return }
        Task { @MainActor in owner?.didReceiveTranscript(message) }
    }
}
#endif
