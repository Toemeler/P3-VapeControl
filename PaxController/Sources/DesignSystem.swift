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
        /// How much thicker the oven's ring swells over a draw.
        static let inhaleSwell: CGFloat = 9
        /// Half the length of the radial target marker.
        static let markerReach: CGFloat = 13
        static let markerWidth: CGFloat = 4.5
        static let markerShadowWidth: CGFloat = 7
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
        /// The ceiling the device itself reports through HeaterRanges (0x11),
        /// whose ladder ends at 245.0 °C. PAX's own app stopped at 215.
        static let max: Double = 245
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
