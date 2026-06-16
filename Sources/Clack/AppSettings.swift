import SwiftUI
import UIKit

@Observable
final class AppSettings {
    /// Stable per-install identity used as the LiveKit participant identity and
    /// the key the backend stores PushToTalk tokens under. Generated once and
    /// persisted; never changes for the life of the install.
    let identity: String

    /// Human-facing name shown in the system PTT UI ("<name> is talking") and
    /// to other participants. Defaults to the device name, user-editable later.
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.displayName) }
    }

    /// Opt-in: share live location with the joined channel (lone-worker safety).
    /// Off by default — location sharing is sensitive and must be deliberate.
    var shareLocation: Bool {
        didSet { UserDefaults.standard.set(shareLocation, forKey: Keys.shareLocation) }
    }

    private enum Keys {
        static let identity = "clack.identity"
        static let displayName = "clack.displayName"
        static let shareLocation = "clack.shareLocation"
    }

    init() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Keys.identity) {
            identity = existing
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Keys.identity)
            identity = fresh
        }
        displayName = defaults.string(forKey: Keys.displayName)
            ?? UIDevice.current.name
        shareLocation = defaults.bool(forKey: Keys.shareLocation)
    }
}
