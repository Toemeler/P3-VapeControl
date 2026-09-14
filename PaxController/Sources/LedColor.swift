import SwiftUI
import UIKit

/// A user-selectable LED color, persisted as "#RRGGBB" via `@AppStorage`.
/// Sent to the device on connect (and whenever changed) as a best-effort
/// ShellColor (0x1C) command — see PaxProtocol.setShellColor for the caveat
/// that the device-side payload format is unconfirmed.
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

    static let presets: [LedColor] = [
        .orange,
        LedColor(name: "Red",    red: 0xE5, green: 0x1F, blue: 0x1F),
        LedColor(name: "Purple", red: 0x8E, green: 0x2D, blue: 0xE0),
        LedColor(name: "Blue",   red: 0x1E, green: 0x6F, blue: 0xE5),
        LedColor(name: "Teal",   red: 0x00, green: 0xB3, blue: 0x9E),
        LedColor(name: "Green",  red: 0x2E, green: 0xB8, blue: 0x2E),
        LedColor(name: "White",  red: 0xFF, green: 0xFF, blue: 0xFF),
    ]

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
