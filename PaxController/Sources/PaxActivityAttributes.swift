import ActivityKit
import Foundation

/// Live Activity payload. Compiled into both the app target (which starts and
/// updates the activity) and the widget extension (which renders it), so it
/// must not reference anything app-only.
struct PaxActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isConnected: Bool
        /// Short headline, e.g. "Ready", "Heating", "Charging", "Waiting for PAX…".
        var headline: String
        var batteryLevel: Int?
        var isCharging: Bool
        var actualTempC: Double?
        var targetTempC: Double?
        var ledColorHex: String
        var useFahrenheit: Bool

        var batteryText: String {
            guard let level = batteryLevel else { return "--" }
            return "\(level)%"
        }

        var actualTempText: String { Self.format(actualTempC, useFahrenheit: useFahrenheit) }
        var targetTempText: String { Self.format(targetTempC, useFahrenheit: useFahrenheit) }

        private static func format(_ celsius: Double?, useFahrenheit: Bool) -> String {
            guard let c = celsius else { return "--" }
            let value = useFahrenheit ? (c * 9 / 5) + 32 : c
            return String(format: "%.0f°%@", value, useFahrenheit ? "F" : "C")
        }
    }

    var deviceName: String
}
