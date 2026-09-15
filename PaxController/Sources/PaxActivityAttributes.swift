import ActivityKit
import Foundation

/// The dial's range, here rather than in `DesignSystem` because the widget
/// extension compiles this file and not that one, and the Lock Screen ring has
/// to land on the same scale as the ring in the app.
enum PaxDialRange {
    static let min: Double = 180
    static let max: Double = 225
    static var span: Double { max - min }
    /// Below the dial's floor the oven is still climbing from room temperature,
    /// and the card shows that climb rather than an empty arc.
    static let coldFloor: Double = 30
}

/// Live Activity payload. Compiled into both the app target (which starts and
/// updates the activity) and the widget extension (which renders it), so it
/// must not reference anything app-only.
struct PaxActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// What the card is actually showing. The Lock Screen keeps one layout
        /// across all of them — the eye learns a single card — and this decides
        /// what the ring means and which number leads.
        enum Phase: String, Codable, Hashable {
            case waiting, charging, heating, ready, drawing, cooling, standby, ovenOff
        }

        var phase: Phase = .waiting
        /// Last time the PAX was seen, for the waiting card. Rendered with
        /// SwiftUI's relative date style so it keeps counting without an update.
        var lastSeen: Date?
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

        /// How far round the ring goes, 0…1, and what that fraction means
        /// depends on the phase: the charge level while charging, otherwise
        /// where the oven is — its climb from cold below the dial's floor, and
        /// its place on the dial above it.
        var ringFraction: Double {
            switch phase {
            case .charging:
                return Double(batteryLevel ?? 0) / 100
            case .waiting:
                return 1
            default:
                guard let t = actualTempC else { return 0 }
                if t < PaxDialRange.min {
                    // Below the dial's floor there is no reading to place on
                    // the scale, but a ring at zero says "nothing happening"
                    // when the oven is in fact climbing. The cold climb gets
                    // the first sliver of the arc so it is visibly moving.
                    let span = PaxDialRange.min - PaxDialRange.coldFloor
                    let climb = Swift.min(1, Swift.max(0, (t - PaxDialRange.coldFloor) / span))
                    return climb * 0.08
                }
                // And it starts from that sliver rather than from nothing, so
                // crossing 180 does not jump backwards.
                let onScale = Swift.min(1, Swift.max(0, (t - PaxDialRange.min) / PaxDialRange.span))
                return 0.08 + onScale * 0.92
            }
        }

        /// The climb from cold to the set point, which is what the ring's colour
        /// follows while the oven is working — green through to orange, the same
        /// gradient the PAX's own LEDs show.
        var warmUpFraction: Double {
            guard let actual = actualTempC, let target = targetTempC, target > PaxDialRange.coldFloor
            else { return 1 }
            let span = target - PaxDialRange.coldFloor
            return Swift.min(1, Swift.max(0, (actual - PaxDialRange.coldFloor) / span))
        }

        /// The one number the card leads with, which is the one the state is
        /// about: the temperature while the oven is doing something, the charge
        /// while it is on the charger, and nothing worth printing when the PAX
        /// is not there.
        ///
        /// Here rather than beside the views because it is a fact about the
        /// state, not a presentation choice — and because the widget extension
        /// is not the only thing that needs to agree about it.
        var leadNumber: String {
            switch phase {
            case .waiting:  return "--"
            case .charging: return batteryText
            default:        return actualTempText
            }
        }

        /// The compact Dynamic Island slot is a few characters wide. Same
        /// choice, and for now the same answer.
        var compactNumber: String { leadNumber }

        var isOvenActive: Bool {
            switch phase {
            case .heating, .ready, .drawing, .cooling: return true
            default: return false
            }
        }

        private static func format(_ celsius: Double?, useFahrenheit: Bool) -> String {
            guard let c = celsius else { return "--" }
            let value = useFahrenheit ? (c * 9 / 5) + 32 : c
            return String(format: "%.0f°%@", value, useFahrenheit ? "F" : "C")
        }
    }

    var deviceName: String
}
