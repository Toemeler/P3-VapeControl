import SwiftUI
import WidgetKit

/// The Home Screen widget: the PAX at a glance, without a session running.
///
/// The Lock Screen card only exists while there is something to say. This is
/// the other half — what the device was doing when the app last saw it, and
/// what the day has looked like, which is a record rather than a reading and
/// therefore the one thing a widget can offer that the card cannot.
struct PaxStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PaxWidgetKind.status, provider: PaxSnapshotProvider()) { entry in
            PaxWidgetView(snapshot: entry.snapshot)
                .widgetContainerBackground()
        }
        .configurationDisplayName("PAX")
        .description("Battery, temperature and what the PAX was last doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct PaxSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: PaxSnapshot?
}

struct PaxSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaxSnapshotEntry {
        PaxSnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaxSnapshotEntry) -> Void) {
        completion(PaxSnapshotEntry(date: Date(),
                                    snapshot: context.isPreview ? .preview : PaxSharedStore.read()))
    }

    /// One entry now, and a refresh in a quarter of an hour. The app pushes a
    /// reload whenever the device says something, so this timeline is the floor
    /// rather than the mechanism — it is what keeps the relative age honest on a
    /// phone that has not seen the PAX all afternoon.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PaxSnapshotEntry>) -> Void) {
        let entry = PaxSnapshotEntry(date: Date(), snapshot: PaxSharedStore.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private extension PaxSnapshot {
    static let preview = PaxSnapshot(
        isConnected: true, headline: "Ready", deviceName: "Paxie",
        batteryLevel: 82, isCharging: false, actualTempC: 199, targetTempC: 199,
        useFahrenheit: false, ledColorHex: "#FF6A00", updatedAt: Date(),
        sessionsToday: 3, drawsToday: 14)
}

struct PaxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: PaxSnapshot?

    private var accent: Color {
        snapshot.flatMap { LedColor.fromHex($0.ledColorHex)?.color } ?? LedColor.orange.color
    }

    var body: some View {
        switch family {
        case .accessoryCircular:  circular
        case .accessoryRectangular: rectangular
        case .systemMedium:       medium
        default:                  small
        }
    }

    // MARK: - Families

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)
            Text(snapshot?.temperatureText ?? "--")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(stale ? Color.secondary : Color.primary)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            small
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                stat("\(snapshot?.sessionsToday ?? 0)", "sessions today")
                stat("\(snapshot?.drawsToday ?? 0)", "draws today")
                Spacer(minLength: 0)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot?.deviceName ?? "PAX")
                .font(.headline)
                .lineLimit(1)
            Text("\(snapshot?.temperatureText ?? "--")  ·  \(snapshot?.batteryText ?? "--")")
                .font(.body.monospacedDigit())
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var circular: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.02, Double(snapshot?.batteryLevel ?? 0) / 100))
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(snapshot?.temperatureText ?? "--")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    // MARK: - Parts

    private var stale: Bool { snapshot?.isStale ?? true }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(snapshot?.isConnected == true && !stale ? accent : Color.secondary)
                .frame(width: 7, height: 7)
            Text(snapshot?.deviceName ?? "PAX")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let snapshot, snapshot.isCharging {
                Image(systemName: "bolt.fill").font(.caption2)
            }
            Text(snapshot?.batteryText ?? "--")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Says what it actually knows. A widget that shows a temperature from
    /// three hours ago as though it were live is worse than one that admits the
    /// phone has not seen the device since.
    private var statusLine: String {
        guard let snapshot else { return "Open the app" }
        if snapshot.isStale {
            return "last seen " + snapshot.updatedAt.formatted(.relative(presentation: .numeric))
        }
        return snapshot.headline
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    /// `containerBackground` is iOS 17; before it, a widget drew its own
    /// background and this does nothing.
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
        }
    }
}
