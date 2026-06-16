import SwiftUI
import MapKit

/// Channel map with an 8h time scrubber. Live (slider at the end) shows current
/// positions; dragging back moves every pin to where that member was at the
/// scrubbed time, and trails grow up to that moment.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition = .automatic
    /// 0 = oldest breadcrumb, 1 = now (live).
    @State private var scrub: Double = 1

    private var members: [MemberLocation] { model.location.members }

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(members) { member in
                let fix = position(of: member)
                Marker(member.name, systemImage: "dot.radiowaves.left.and.right",
                       coordinate: fix.coordinate)
                let path = trail(of: member)
                if path.count > 1 {
                    MapPolyline(coordinates: path.map(\.coordinate))
                        .stroke(.tint, lineWidth: 3)
                }
            }
        }
        .mapControls { MapUserLocationButton() }
        .safeAreaInset(edge: .bottom) { controls }
        .navigationTitle("Channel Map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await poll() }
        .overlay {
            if members.isEmpty {
                ContentUnavailableView("No locations yet",
                    systemImage: "location.slash",
                    description: Text("Members appear here once they share location."))
            }
        }
    }

    // MARK: - Time scrubbing

    /// Time window spanning all members' trails.
    private var timeRange: ClosedRange<Date>? {
        let dates = members.flatMap { $0.trail.map(\.date) }
        guard let earliest = dates.min() else { return nil }
        let latest = members.map { $0.latest.date }.max() ?? Date()
        guard earliest < latest else { return nil }
        return earliest...latest
    }

    private var isLive: Bool { scrub >= 0.999 }

    private var scrubDate: Date {
        guard let range = timeRange else { return Date() }
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        return range.lowerBound.addingTimeInterval(span * scrub)
    }

    /// Where `member` was at the scrubbed time (last breadcrumb at/before it).
    private func position(of member: MemberLocation) -> LocationFix {
        if isLive { return member.latest }
        return member.trail.last { $0.date <= scrubDate } ?? member.trail.first ?? member.latest
    }

    /// Trail clipped to the scrubbed time so the path "grows" as you scrub.
    private func trail(of member: MemberLocation) -> [LocationFix] {
        if isLive { return member.trail }
        return member.trail.filter { $0.date <= scrubDate }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text(isLive ? "Live" : scrubDate.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isLive ? .green : .primary)
                Spacer()
                if !isLive {
                    Button("Live") { withAnimation { scrub = 1 } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            if timeRange != nil {
                Slider(value: $scrub, in: 0...1)
            }
            if !members.isEmpty {
                memberSummary
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var memberSummary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(members) { member in
                    let fix = position(of: member)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name).font(.caption.weight(.semibold))
                        Text(fix.date, style: isLive ? .relative : .time)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await model.location.refreshMembers()
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
