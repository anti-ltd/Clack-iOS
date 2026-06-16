import Foundation
import CoreLocation
import Observation
import OSLog

// Lone-worker location sharing. When the user opts in (`AppSettings.shareLocation`)
// and is in a channel, this streams throttled CoreLocation fixes to the backend
// (which keeps an 8h trail). It also fetches everyone's positions for the map.
//
// Throttle: post on ≥50 m movement OR every 60 s (a stationary worker still
// beacons in the foreground). "Always" authorization + the `location` background
// mode keep updates flowing while the phone is pocketed.
@Observable
@MainActor
final class LocationService {
    private(set) var members: [MemberLocation] = []
    private(set) var authorization: CLAuthorizationStatus

    private let settings: AppSettings
    private let backend = Backend()
    private let manager = CLLocationManager()
    private let coordinator = Coordinator()
    private let log = Logger(subsystem: "ltd.anti.clack", category: "location")

    private var channel: Channel?
    private var lastPostedAt: Date = .distantPast
    private var lastPostedLocation: CLLocation?
    private var beaconTimer: Timer?

    private let minDistance: CLLocationDistance = 50   // metres
    private let minInterval: TimeInterval = 60         // seconds

    init(settings: AppSettings) {
        self.settings = settings
        authorization = manager.authorizationStatus
        coordinator.owner = self
        manager.delegate = coordinator
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isSharing: Bool { settings.shareLocation }

    /// Turn sharing on/off (drives the persisted setting + CoreLocation).
    func setSharing(_ on: Bool) {
        settings.shareLocation = on
        if on { manager.requestAlwaysAuthorization() }
        reevaluate()
    }

    /// Called when the joined channel changes.
    func setChannel(_ channel: Channel?) {
        self.channel = channel
        reevaluate()
    }

    /// Fetch every member's latest position + trail for the map.
    func refreshMembers() async {
        guard let channel else { return }
        do {
            let response = try await backend.fetchLocations(channel: channel.id.uuidString)
            members = response.memberLocations
        } catch {
            log.error("fetchLocations failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private func reevaluate() {
        let active = settings.shareLocation && channel != nil
            && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse)
        if active {
            manager.startUpdatingLocation()
            startBeaconTimer()
        } else {
            manager.stopUpdatingLocation()
            beaconTimer?.invalidate()
            beaconTimer = nil
        }
    }

    private func startBeaconTimer() {
        guard beaconTimer == nil else { return }
        // Foreground stationary beacon — movement updates cover the moving case.
        beaconTimer = Timer.scheduledTimer(withTimeInterval: minInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beaconLastKnown() }
        }
    }

    private func beaconLastKnown() {
        guard let loc = manager.location else { return }
        post(loc, force: true)
    }

    fileprivate func didUpdate(_ location: CLLocation) {
        post(location, force: false)
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        reevaluate()
    }

    /// Throttled POST: only when moved far enough or enough time has passed.
    private func post(_ location: CLLocation, force: Bool) {
        guard settings.shareLocation, let channel else { return }
        let movedEnough = lastPostedLocation.map { location.distance(from: $0) >= minDistance } ?? true
        let timeElapsed = Date().timeIntervalSince(lastPostedAt) >= minInterval
        guard force || movedEnough || timeElapsed else { return }
        lastPostedAt = Date()
        lastPostedLocation = location
        let coord = location.coordinate
        let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        Task {
            try? await backend.postLocation(
                channel: channel.id.uuidString,
                identity: settings.identity, name: settings.displayName,
                lat: coord.latitude, lon: coord.longitude, accuracy: accuracy)
        }
    }
}

// CLLocationManagerDelegate is a plain (non-main) callback surface; hop Sendable
// values onto the main actor.
private final class Coordinator: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    weak var owner: LocationService?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in owner?.didUpdate(location) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in owner?.authorizationChanged(status) }
    }
}
