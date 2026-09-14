import SwiftUI

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
        /// Capsules and inactive chips.
        static let fill = Color(.tertiarySystemFill)
        /// The unfilled part of the dial arc.
        static let track = Color(.secondarySystemFill)
        /// The LED color chosen in settings, orange until changed. Computed so
        /// every existing call site re-themes without being rewired; views
        /// re-render on change because they observe AppSettings.
        static var accent: Color { LedColor.current.color }
        static var accentTint: Color { accent.opacity(0.15) }
    }

    /// The oven's usable range. `PaxPresetTemp` sits inside it.
    enum Range {
        static let min: Double = 180
        static let max: Double = 215
        static var span: Double { Self.max - Self.min }

        static func fraction(of celsius: Double) -> Double {
            guard span > 0 else { return 0 }
            return Swift.min(1, Swift.max(0, (celsius - Self.min) / Self.span))
        }

        static func celsius(atFraction f: Double) -> Double {
            Self.min + Swift.min(1, Swift.max(0, f)) * Self.span
        }
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
