import Foundation
import CoreLocation

/// One position fix in a member's trail.
struct LocationFix: Identifiable, Hashable, Sendable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
    let date: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A channel member's latest position plus their breadcrumb trail (≤ 8h).
struct MemberLocation: Identifiable, Sendable {
    let identity: String
    let name: String
    let latest: LocationFix
    let trail: [LocationFix]

    var id: String { identity }
    var coordinate: CLLocationCoordinate2D { latest.coordinate }
}

// MARK: - Backend wire form

struct LocationsResponse: Decodable, Sendable {
    let members: [Member]

    struct Member: Decodable, Sendable {
        let identity: String
        let name: String
        let latest: Fix
        let trail: [Point]
    }
    struct Fix: Decodable, Sendable {
        let lat: Double
        let lon: Double
        let accuracy: Double?
        let ts: Double   // epoch ms
    }
    struct Point: Decodable, Sendable {
        let lat: Double
        let lon: Double
        let ts: Double
    }

    /// Map to display models.
    var memberLocations: [MemberLocation] {
        members.map { m in
            MemberLocation(
                identity: m.identity,
                name: m.name,
                latest: LocationFix(latitude: m.latest.lat, longitude: m.latest.lon,
                                    date: Date(timeIntervalSince1970: m.latest.ts / 1000)),
                trail: m.trail.map {
                    LocationFix(latitude: $0.lat, longitude: $0.lon,
                                date: Date(timeIntervalSince1970: $0.ts / 1000))
                })
        }
    }
}
