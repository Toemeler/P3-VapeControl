import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the Home Screen widget knows.
///
/// A widget runs in its own process with its own container, so the only way it
/// sees anything is through a shared app group. This is the whole of what
/// crosses that boundary: small, flat, and written often enough that a glance
/// at the Home Screen is worth taking.
///
/// It degrades rather than failing. If the group is not available — an install
/// signed without it, or a first launch before anything has been written — the
/// snapshot comes back nil and the widget says so instead of showing zeroes
/// that look like readings.
struct PaxSnapshot: Codable, Equatable {
    var isConnected: Bool
    var headline: String
    var deviceName: String
    var batteryLevel: Int?
    var isCharging: Bool
    var actualTempC: Double?
    var targetTempC: Double?
    var useFahrenheit: Bool
    var ledColorHex: String
    var updatedAt: Date
    /// Sessions and draws today, which is the part a widget can say that the
    /// Lock Screen card cannot — it is a record rather than a live reading.
    var sessionsToday: Int
    var drawsToday: Int

    var temperatureText: String {
        guard let celsius = actualTempC else { return "--" }
        let value = useFahrenheit ? (celsius * 9 / 5) + 32 : celsius
        return String(format: "%.0f°", value)
    }

    var batteryText: String {
        batteryLevel.map { "\($0)%" } ?? "--"
    }

    /// Anything older than this is not worth showing as current: the app has
    /// not been connected, and the widget should say it is out of date rather
    /// than quietly presenting a stale temperature as live.
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 30 * 60
    }
}

/// The shared container, and the one place its name is written down.
enum PaxSharedStore {
    /// Matches the group in both targets' entitlements. A build signed without
    /// it simply gets nil here, which every reader is written to handle.
    static let appGroup = "group.io.github.toemeler.PaxController"
    private static let key = "paxSnapshot"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func write(_ snapshot: PaxSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func read() -> PaxSnapshot? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PaxSnapshot.self, from: data)
    }

    /// Asks the system to redraw the widget. Rate-limited by iOS, so this is a
    /// request rather than a guarantee — which is why the widget also refreshes
    /// on its own timeline.
    static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: PaxWidgetKind.status)
        #endif
    }
}

/// What the watch and the phone say to each other.
///
/// Deliberately small. The phone pushes its snapshot whenever something
/// changes, and the watch sends one of a handful of commands back. Nothing here
/// knows about Bluetooth, packets or heating parameters — the phone is the only
/// thing that talks to the device, and the watch is a remote for it.
enum PaxWatchMessage {
    static let commandKey = "command"
    static let valueKey = "value"
    static let snapshotKey = "snapshot"

    enum Command: String {
        case requestState
        case setTemperature
        case stepTemperature
        case ovenOn
        case ovenOff
        case applyProfile
    }
}

enum PaxWidgetKind {
    static let status = "PaxStatusWidget"
}
