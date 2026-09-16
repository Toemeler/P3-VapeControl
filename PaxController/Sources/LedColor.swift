import SwiftUI
import UIKit

/// A user-selectable LED color, persisted as "#RRGGBB" by `AppSettings`. Drives
/// `DS.Palette.accent`, and is pushed to the device when its firmware reports an
/// LED attribute it will accept — see PaxDeviceViewModel's capability discovery.
struct LedColor: Identifiable, Equatable {
    let name: String
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var id: String { hex }

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    static let orange = LedColor(name: "Orange", red: 0xFF, green: 0x6A, blue: 0x00)

    /// Where `AppSettings` persists the choice.
    static let defaultsKey = "ledColorHex"

    /// The current choice, read straight from UserDefaults rather than through
    /// `AppSettings`. `DS.Palette.accent` is a plain static with no actor
    /// isolation, so it cannot touch a main-actor-isolated property; reading
    /// the defaults directly keeps the palette usable from any context. Views
    /// still re-render on a change because they observe `AppSettings`.
    static var current: LedColor {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(fromHex) ?? .orange
    }

    static let presets: [LedColor] = [
        .orange,
        LedColor(name: "Red",    red: 0xE5, green: 0x1F, blue: 0x1F),
        LedColor(name: "Purple", red: 0x8E, green: 0x2D, blue: 0xE0),
        LedColor(name: "Blue",   red: 0x1E, green: 0x6F, blue: 0xE5),
        LedColor(name: "Teal",   red: 0x00, green: 0xB3, blue: 0x9E),
        LedColor(name: "Green",  red: 0x2E, green: 0xB8, blue: 0x2E),
        LedColor(name: "White",  red: 0xFF, green: 0xFF, blue: 0xFF),
    ]

    /// The colours each PAX state starts out with. Four combinations, one per
    /// state and none of them repeated, so the device says what it is doing
    /// from across the room. Eight entries: colour 1 then colour 2 for startup,
    /// heating, regulating and standby.
    static let cleanStateHexes = [
        "#FFFFFF", "#8E5CFF",   // startup: white flaring into violet
        "#2EB82E", "#FF6A00",   // heating: green climbing to orange
        "#7FD6FF", "#1E9BE5",   // at temperature: light blue with some depth
        "#A34D00", "#FF8A3D",   // standby: a soft orange, breathing
    ]

    /// Palettes earlier builds shipped. One of these still stored means nobody
    /// has touched the colours, so a new palette can replace it; anything else
    /// was chosen by hand and is left alone.
    static let supersededStateHexes: [[String]] = [
        [   // 1.0.61: light blue in three of the eight slots
            "#7FD6FF", "#FFFFFF",
            "#2EB82E", "#FF6A00",
            "#7FD6FF", "#7FD6FF",
            "#A34D00", "#FF8A3D",
        ],
    ]

    /// What the second colour becomes when one colour is driving every state:
    /// the PAX moves between the two, and a colour paired with white reads as
    /// that colour rather than as a flat block. Orange and white by default.
    static let pairedWith = LedColor(name: "White", red: 0xFF, green: 0xFF, blue: 0xFF)

    /// Where the warm-up ramp sits at `progress` (0 at the start of the
    /// heat-up, 1 at the set point): green, through yellow, to orange.
    static func warmUp(progress: Double) -> LedColor {
        let p = min(1, max(0, progress))
        let green  = LedColor(name: "Warm-up", red: 0x2E, green: 0xB8, blue: 0x2E)
        let yellow = LedColor(name: "Warm-up", red: 0xFF, green: 0xD0, blue: 0x00)
        let orange = LedColor(name: "Warm-up", red: 0xFF, green: 0x6A, blue: 0x00)
        return p < 0.5
            ? blend(green, yellow, p / 0.5)
            : blend(yellow, orange, (p - 0.5) / 0.5)
    }

    private static func blend(_ a: LedColor, _ b: LedColor, _ t: Double) -> LedColor {
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded())
        }
        return LedColor(name: "Warm-up",
                        red: mix(a.red, b.red),
                        green: mix(a.green, b.green),
                        blue: mix(a.blue, b.blue))
    }

    static func fromHex(_ hex: String) -> LedColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = UInt8((value >> 16) & 0xFF)
        let g = UInt8((value >> 8) & 0xFF)
        let b = UInt8(value & 0xFF)
        let name = presets.first { $0.red == r && $0.green == g && $0.blue == b }?.name ?? "Custom"
        return LedColor(name: name, red: r, green: g, blue: b)
    }

    static func fromColor(_ color: Color) -> LedColor? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return fromHex(String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b)))
    }

    private static func channel(_ value: CGFloat) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }

    /// Whether a checkmark drawn on this color needs to be dark to stay legible.
    var isLight: Bool {
        let luma = (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255
        return luma > 0.6
    }
}

/// The app's own colours, as opposed to the device's.
///
/// These two were the same thing until now, and that was the bug: the app's
/// accent was `LedColor.current`, so choosing a green LED turned the whole
/// interface green. The LED is a property of the vaporizer sitting on the
/// table; the accent is the identity of the app. They are separate ideas and
/// are now separate values.
///
/// **Orange leads, always.** White is the second voice, yellow marks caution
/// and light blue carries calm information — charging, connection, facts that
/// are neither good nor bad.
///
/// Every pair below is measured against the canvas it sits on rather than
/// picked by eye: the light variants are darker than they look like they should
/// be because orange on near-white is the hard case, and each clears 4.5:1 for
/// body text.
///
/// Lives here rather than in the design system because this file is in every
/// target — app, widget, Live Activity and watch — and the accent has to be one
/// colour across all four.
enum Brand {
    /// The one accent. Everything else is a supporting role.
    static let accent = adaptive(dark: 0xFF7A1A, light: 0xA84600)

    /// What goes *on top of* a filled accent shape.
    ///
    /// Ink, not white. White on this orange measures 2.6:1, which is below any
    /// standard and unreadable in sunlight; the same ink measures 6.9:1. White
    /// is the second colour of this app everywhere it sits on the canvas — in
    /// text, in the dial's marker — just never on top of the orange.
    static let onAccent = Color(hexValue: 0x17171A)

    /// Approaching a limit: the last stretch of the temperature dial, a battery
    /// getting low enough to mention but not low enough to worry about.
    static let caution = adaptive(dark: 0xFFC53D, light: 0x8A5E00)

    /// Neither good nor bad, just true: charging, connected, a measured figure.
    static let info = adaptive(dark: 0x7FD6FF, light: 0x0B5E8F)

    /// Something actually wrong. Kept in the warm family so it belongs to the
    /// same palette rather than arriving from a different app.
    static let critical = adaptive(dark: 0xFF6B52, light: 0xB03024)

    /// The warm-up ramp for the app's own rings: cold light blue, through
    /// yellow, arriving at the accent. Three colours of this palette and no
    /// others, so a heating ring never leaves the app's identity on its way up.
    ///
    /// The device has a ramp of its own in `LedColor.warmUp`, which starts from
    /// green. That one is about the object on the table rather than the
    /// interface, and it stays as it is.
    static func warmUp(progress: Double) -> Color {
        let p = min(1, max(0, progress))
        let cold = (127.0, 214.0, 255.0)
        let mid  = (255.0, 197.0,  61.0)
        let hot  = (255.0, 122.0,  26.0)
        let (from, to, t) = p < 0.5 ? (cold, mid, p / 0.5) : (mid, hot, (p - 0.5) / 0.5)
        func mix(_ x: Double, _ y: Double) -> Double { (x + (y - x) * t) / 255 }
        return Color(red: mix(from.0, to.0),
                     green: mix(from.1, to.1),
                     blue: mix(from.2, to.2))
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        #if os(watchOS)
        // The watch is always dark, and UIColor has no dynamic provider there.
        return Color(hexValue: dark)
        #else
        return Color(UIColor { traits in
            UIColor(hexValue: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

extension Color {
    init(hexValue: UInt32) {
        self.init(red: Double((hexValue >> 16) & 0xFF) / 255,
                  green: Double((hexValue >> 8) & 0xFF) / 255,
                  blue: Double(hexValue & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hexValue: UInt32) {
        self.init(red: CGFloat((hexValue >> 16) & 0xFF) / 255,
                  green: CGFloat((hexValue >> 8) & 0xFF) / 255,
                  blue: CGFloat(hexValue & 0xFF) / 255,
                  alpha: 1)
    }
}
