import SwiftUI
import UIKit

/// Measurements lifted from the design canvas, so the screen matches it 1:1.
/// Everything here is in points on a 390 x 844 frame.
enum DS {

    /// The dial is authored on a 380 x 380 canvas. Its arc runs 270 degrees
    /// clockwise from 135 degrees, which leaves the gap centred at the bottom.
    enum Dial {
        static let canvas: CGFloat = 380
        static let radius: CGFloat = 164
        static let stroke: CGFloat = 26
        static let startAngle: Double = 135
        static let sweep: Double = 270
        static let tickRadius: CGFloat = 185
        static let tickDot: CGFloat = 2.6
        /// The warm-up ring sits just inside the main one.
        static let warmUpInset: CGFloat = 19
        static let warmUpStroke: CGFloat = 3.5
        /// The battery ring nests inside both, the way Activity rings nest.
        static let batteryInset: CGFloat = 33
        /// A full battery is a hairline; an empty one is heavy enough to
        /// notice from across the room, which is the point.
        static let batteryStrokeFull: CGFloat = 3
        static let batteryStrokeEmpty: CGFloat = 13
        /// Charging always reads as substantial, whatever the level.
        static let batteryStrokeCharging: CGFloat = 11
        /// Where the oven's ring ends, and the one measurement on this dial
        /// that never moves. A draw thickens the ring *inward* from here, so
        /// no draw — however long — can push it into the preset dots or off
        /// the canvas. The overflow is impossible by construction rather than
        /// by choosing a swell that happens to fit.
        static let outerEdge: CGFloat = radius + stroke / 2
        /// How far the ring can thicken over a draw. It approaches this and
        /// never reaches it (see `DialCurve.saturating`), so the width is
        /// always still climbing while the draw lasts.
        static let inhaleSwellMax: CGFloat = 9.5
        /// Seconds to the half-way point of that climb. Smaller makes the
        /// first second more dramatic.
        static let inhaleHalfLife: Double = 2
        /// The width keeps its bounds; the bloom around it is what carries a
        /// long pull, and it grows on a much slower clock.
        static let bloomHalfLife: Double = 6
        /// Sub-point wobble at the top of a breath. A held lung is never still.
        static let inhaleTremor: Double = 0.34
        /// How far the battery ring's breath moves it, in points either way.
        static let batteryBreathDepth: CGFloat = 1.6
        /// The period of that breath: slow and shallow when there is charge to
        /// spare, quick and deep when there is not.
        static let batteryBreathSlow: Double = 3.4
        static let batteryBreathFast: Double = 1.5
        /// Seconds per revolution of the charging highlight, full and empty.
        static let chargeSpinSlow: Double = 4.2
        static let chargeSpinFast: Double = 2

        /// The time ring, innermost. It times a session off the charger and a
        /// charge on it — the PAX is never both, so the two share one lane and
        /// the dial gains a reading without gaining a ring.
        static let timeRadius: CGFloat = 114
        static let timeStrokeBase: CGFloat = 2
        static let timeStrokeMax: CGFloat = 12
        /// How much of that width a long sitting adds, and how much a lot of
        /// draws adds on top of it.
        static let timeStrokeByTime: CGFloat = 5
        static let timeStrokeByDraws: CGFloat = 3.5
        /// The bump each draw lands as, before it decays back into the baseline.
        static let timeStrokeDrawBump: CGFloat = 1.8
        static let timeBead: CGFloat = 2.2
        /// How long the arc takes to fill, as a time constant. It compresses,
        /// so a session or a charge always has somewhere left to go.
        static let sessionTau: Double = 14 * 60
        static let sessionWeightTau: Double = 12 * 60
        static let chargeTau: Double = 45 * 60
        static let chargeWeightTau: Double = 25 * 60
        /// The bright segment at the leading edge of a session's arc: what is
        /// left of the auto-off window, refilled by every draw.
        static let fuseSweep: Double = 26

        /// How wide the readout in the middle is allowed to be. The innermost
        /// ring's inner edge sits at 108 points; a box 184 wide and 110 tall
        /// has its corners at 107, which is the largest readout that cannot
        /// touch it.
        static let centreWidth: CGFloat = 184

        /// Half the length of the radial target marker.
        static let markerReach: CGFloat = 13
        static let markerWidth: CGFloat = 4.5
        static let markerShadowWidth: CGFloat = 7

        /// The dial is authored at `canvas` points across. On a narrower phone
        /// — or a shorter one — everything is scaled by a single factor so the
        /// layout keeps its proportions instead of being clipped.
        static func scale(in size: CGSize) -> CGFloat {
            let width = size.width - 2 * Metric.gutter
            // What the rest of the connected screen needs below the dial: the
            // target row, the presets, the mode tiles and their padding.
            let reserved: CGFloat = Metric.topBarHeight + 262
            let height = size.height - reserved
            guard width > 0, height > 0 else { return 1 }
            return Swift.min(1, Swift.min(width / canvas, height / canvas))
        }
    }

    enum Metric {
        static let gutter: CGFloat = 16
        static let topBarHeight: CGFloat = 52
        static let capsuleHeight: CGFloat = 38
        static let roundButton: CGFloat = 38
        static let stepButton: CGFloat = 52
        static let presetHeight: CGFloat = 40
        static let modeHeight: CGFloat = 72
        static let modeRadius: CGFloat = 18
        static let statusDot: CGFloat = 8
    }

    enum Palette {
        /// The screen itself. Not black: a dial and three rings sitting on pure
        /// black have no ground to sit on, and every edge in the layout becomes
        /// a hard cut. This is a near-neutral charcoal with a trace of warmth
        /// to meet the orange, and an off-white in light mode for the same
        /// reason — paper rather than glare.
        static let canvas = dynamic(dark: 0x17171A, light: 0xF4F3F1)
        /// Capsules, chips and mode tiles: one step up from the canvas.
        static let fill = dynamic(dark: 0x2A2A2F, light: 0xE6E4E1)
        /// The unfilled part of a ring.
        static let track = dynamic(dark: 0x2F2F35, light: 0xDCDAD6)
        /// The LED color chosen in settings, orange until changed. Computed so
        /// every existing call site re-themes without being rewired; views
        /// re-render on change because they observe AppSettings.
        static var accent: Color { LedColor.current.color }
        static var accentTint: Color { accent.opacity(0.15) }
        /// A battery with almost nothing left.
        static let low = Color(red: 1, green: 0.27, blue: 0.23)
        /// A battery filling.
        static let charge = Color(red: 0.19, green: 0.82, blue: 0.35)

        private static func dynamic(dark: UInt32, light: UInt32) -> Color {
            Color(UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255,
                               alpha: 1)
            })
        }
    }

    /// The oven's usable range. `PaxPresetTemp` sits inside it.
    enum Range {
        static let min: Double = 180
        /// The device's own HeaterRanges (0x11) ladder runs to 245.0 °C, but the
        /// dial stops at 225: past about there the oven is scorching rather
        /// than vaporising, so the last twenty degrees the firmware allows are
        /// not degrees anyone wants to land on by dragging a ring.
        static let max: Double = 225
        /// Where PAX's app stopped. The dial marks everything past it, because
        /// plant material scorches somewhere around here and the person turning
        /// the ring should be able to see where they are.
        static let vendorMax: Double = 215
        static var span: Double { Self.max - Self.min }

        static func fraction(of celsius: Double) -> Double {
            guard span > 0 else { return 0 }
            return Swift.min(1, Swift.max(0, (celsius - Self.min) / Self.span))
        }

        static func celsius(atFraction f: Double) -> Double {
            Self.min + Swift.min(1, Swift.max(0, f)) * Self.span
        }
    }

    /// The climb from cold up to the bottom of the dial's scale. The oven
    /// spends most of a warm-up here, where the main arc has nothing to show:
    /// without this the ring sits empty for thirty seconds and then leaps.
    enum WarmUp {
        static let floor: Double = 30

        static func fraction(of celsius: Double) -> Double {
            let span = Range.min - floor
            guard span > 0 else { return 0 }
            return Swift.min(1, Swift.max(0, (celsius - floor) / span))
        }
    }
}

/// Gives a control the small give of something being pressed. SwiftUI's plain
/// style reports nothing at all, which leaves every chip and tile in this app
/// feeling like a printed label rather than a button.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}

// MARK: - Shared formatting

enum TemperatureUnit: String {
    case celsius
    case fahrenheit

    var symbol: String {
        switch self {
        case .celsius:    return "°C"
        case .fahrenheit: return "°F"
        }
    }

    func convert(celsius: Double) -> Double {
        switch self {
        case .celsius:    return celsius
        case .fahrenheit: return (celsius * 9 / 5) + 32
        }
    }

    func format(_ celsius: Double, decimals: Int = 0, includeSymbol: Bool = true) -> String {
        let value = String(format: "%.\(decimals)f", convert(celsius: celsius))
        return includeSymbol ? value + symbol : value
    }
}
