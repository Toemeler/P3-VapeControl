import SwiftUI
import UIKit

/// A colour in a theme file: `#RGB`, `#RRGGBB` or `#RRGGBBAA`, so a theme stays
/// readable and hand-editable JSON rather than a binary blob.
struct ThemeColor: Codable, Equatable, Hashable {
    var hex: String

    init(_ hex: String) { self.hex = hex }

    init(from decoder: Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var color: Color { Color(uiColor) }

    var uiColor: UIColor { Self.parse(hex) ?? .magenta }

    /// Lenient on purpose: an imported theme with a stray `0x`, missing `#` or
    /// lowercase digits should still load. Anything genuinely unparseable
    /// returns nil so the caller can fall back rather than paint garbage.
    static func parse(_ raw: String) -> UIColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0X") { s.removeFirst(2) }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8,
              s.allSatisfy({ $0.isHexDigit }),
              let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    static func from(_ color: UIColor) -> ThemeColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        return ThemeColor(a < 0.999 ? hex + String(format: "%02X", Int(a * 255)) : hex)
    }
}

// MARK: - Roles

/// The colour slots a theme fills in. Stored as strings in the file so a theme
/// that omits a slot, or names one this build does not know, still loads.
enum ColorRole: String, CaseIterable {
    /// The screen itself.
    case canvas
    /// Capsules, plates, cards, tiles — one step off the canvas.
    case plate
    /// The unfilled part of any scale, ring or bar.
    case track
    /// Primary text and the filled part of a scale.
    case ink
    /// Secondary text and labels.
    case muted
    /// Rules, borders, separators.
    case hairline
    /// The one colour bound to the temperature you set.
    case accent
    /// Text sitting on top of an accent fill.
    case onAccent
    case ready, heating, cooling, charging, offline
    /// A battery with almost nothing left.
    case low
    /// The filled region of whatever the hero draws: the field in `field`, the
    /// column in `column`, the chamber in `object`. Two stops, bottom to top.
    case heroFill, heroFillEnd
}

/// Numbers a theme can move. Points, except the few marked otherwise.
enum MetricRole: String, CaseIterable {
    case gutter, radius, plateRadius
    case hairlineWidth
    /// The big temperature readout.
    case heroSize
    /// Height of a preset chip, plate or word row.
    case presetHeight
    /// Height of a mode tile, key or row.
    case modeHeight
    /// Diameter of a round step button, or height of a plate one.
    case stepSize
    case capsuleHeight
    case headerHeight
    /// Stroke of whatever the hero draws its scale with.
    case scaleStroke
    /// Vertical air between the stacked sections.
    case sectionGap
}

enum ThemeShell: String {
    /// Header, hero, target, presets, modes, stacked down the screen.
    case stacked
    /// The session's trace is the screen.
    case chart
    /// The whole display is the control.
    case field
    /// The state is a sentence.
    case prose
    /// The device is the hero and the data is furniture.
    case object
    /// Time takes the top third, temperature drops to a table.
    case countdown
}

enum ThemeHero: String {
    case arc, linearScale, rule, card, column, gauge, none
}

enum ThemeTargetStyle: String {
    case stepperRound, stepperPlate, stepperHairline, slider, detents, none
}

enum ThemePresetStyle: String {
    case capsules, plates, words, segmented, table, detents, none
}

enum ThemeModeStyle: String {
    case tiles, switchBar, keys, list, words, selector, dots, none
}

enum ThemeLabelCase: String {
    case lower, sentence, upper
}

/// Whether a theme draws its containers as filled plates or as hairlines. Rows
/// and lists read completely differently between the two, and it used to be
/// inferred from the corner radius -- which held for the themes that ship here
/// and would have quietly picked wrong for an imported one.
enum ThemeChrome: String {
    case fills, hairlines
}

// MARK: - Typography

/// Every field is optional so a theme can name only what it cares about.
///
/// `family` names a font by its PostScript/family name and is used only when
/// that font is actually available — bundled in the app or installed on the
/// device. When it is not, the theme falls back to `design`, which is one of
/// the system families. See `Theme/FONTS.md`: the shipped themes were drawn
/// with webfonts that are not redistributed here, so out of the box they are
/// 1:1 in layout, colour, metric and hierarchy, and approximate in typeface.
struct ThemeTypography: Codable, Equatable {
    /// "default", "serif", "rounded" or "monospaced".
    var design: String?
    /// The same, for the big readout and display type.
    var displayDesign: String?
    /// "standard", "condensed" or "expanded" (iOS 16+).
    var width: String?
    var family: String?
    var displayFamily: String?
    /// "lower", "sentence" or "upper".
    var labelCase: String?
    var labelTracking: Double?
    var labelSize: Double?
    var labelWeight: String?
    var heroWeight: String?
    var heroTracking: Double?
    var bodyWeight: String?
    var tabular: Bool?

    static func weight(_ name: String?, default fallback: Font.Weight) -> Font.Weight {
        switch name?.lowercased() {
        case "ultralight": return .ultraLight
        case "thin":       return .thin
        case "light":      return .light
        case "regular":    return .regular
        case "medium":     return .medium
        case "semibold":   return .semibold
        case "bold":       return .bold
        case "heavy":      return .heavy
        case "black":      return .black
        default:           return fallback
        }
    }
}

// MARK: - The theme

/// One theme: which composition the screen uses, and every token it draws with.
///
/// Deliberately flat and string-keyed. Enum cases and colour roles this build
/// does not recognise are ignored rather than fatal, so a theme written for a
/// later version still opens, and one written by hand does not have to name
/// every slot.
struct AppTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var author: String?
    var summary: String?

    var shell: String?
    var hero: String?
    var target: String?
    var presets: String?
    var modes: String?

    var typography: ThemeTypography?
    var light: [String: ThemeColor]?
    var dark: [String: ThemeColor]?
    var metrics: [String: Double]?

    /// Whether the accent follows the LED colour chosen in settings. The
    /// shipped `classic` theme does, which is how that feature has always
    /// worked; a theme with a considered palette of its own says false.
    var accentFollowsLed: Bool?

    /// Bumped if the shape of this file ever changes incompatibly. Absent is
    /// treated as version 1.
    var formatVersion: Int?

    /// "fills" or "hairlines". Absent falls back to the corner radius, which is
    /// what this was inferred from before it could be stated.
    var chrome: String?

    var shellKind: ThemeShell { ThemeShell(rawValue: shell ?? "") ?? .stacked }
    var heroKind: ThemeHero { ThemeHero(rawValue: hero ?? "") ?? .arc }
    var targetKind: ThemeTargetStyle { ThemeTargetStyle(rawValue: target ?? "") ?? .stepperRound }
    var presetKind: ThemePresetStyle { ThemePresetStyle(rawValue: presets ?? "") ?? .capsules }
    var modeKind: ThemeModeStyle { ThemeModeStyle(rawValue: modes ?? "") ?? .tiles }
    var followsLed: Bool { accentFollowsLed ?? false }

    var chromeKind: ThemeChrome {
        if let named = ThemeChrome(rawValue: chrome ?? "") { return named }
        return (metrics?[MetricRole.radius.rawValue] ?? 18) > 4 ? .fills : .hairlines
    }
}

// MARK: - Resolved tokens

/// A theme resolved against the current appearance, so views ask for a role and
/// get a `Color` rather than doing the light/dark dance at every call site.
struct ThemeTokens {
    let theme: AppTheme
    let scheme: ColorScheme
    private let colors: [String: ThemeColor]
    private let accentOverride: Color?

    init(theme: AppTheme, scheme: ColorScheme, accentOverride: Color? = nil) {
        self.theme = theme
        self.scheme = scheme
        let table = scheme == .dark ? (theme.dark ?? theme.light) : (theme.light ?? theme.dark)
        self.colors = table ?? [:]
        self.accentOverride = accentOverride
    }

    // MARK: Colours

    func color(_ role: ColorRole) -> Color {
        if role == .accent, let accentOverride { return accentOverride }
        // A theme that names no hero fill gets its accent, which is what most
        // of them would have said anyway.
        if role == .heroFill || role == .heroFillEnd, colors[role.rawValue] == nil {
            return color(.accent)
        }
        if let named = colors[role.rawValue], let parsed = ThemeColor.parse(named.hex) {
            return Color(parsed)
        }
        return Self.fallback(role, scheme: scheme)
    }

    var canvas: Color { color(.canvas) }
    var plate: Color { color(.plate) }
    var track: Color { color(.track) }
    var ink: Color { color(.ink) }
    var muted: Color { color(.muted) }
    var hairline: Color { color(.hairline) }
    var accent: Color { color(.accent) }
    var onAccent: Color { color(.onAccent) }

    /// A wash of the accent, for a selected chip that should not shout.
    var accentWash: Color { accent.opacity(0.15) }

    /// The colour standing for what the oven is doing right now.
    func stateColor(_ state: PaxHeatingState?, charging: Bool, connected: Bool) -> Color {
        guard connected else { return color(.offline) }
        if charging { return color(.charging) }
        switch state {
        case .heating, .boosting:              return color(.heating)
        case .ready:                           return color(.ready)
        case .cooling:                         return color(.cooling)
        case .standby, .ovenOff, .tempSetMode: return muted
        case .none:                            return muted
        }
    }

    /// The last resort when a theme names no colour for a role: the shipped
    /// dark or light palette, so a one-line theme file still renders.
    static func fallback(_ role: ColorRole, scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch role {
        case .canvas:   return hex(dark ? 0x17171A : 0xF4F3F1)
        case .plate:    return hex(dark ? 0x2A2A2F : 0xE6E4E1)
        case .track:    return hex(dark ? 0x2F2F35 : 0xDCDAD6)
        case .ink:      return dark ? .white : hex(0x111111)
        case .muted:    return dark ? Color.white.opacity(0.6) : Color.black.opacity(0.55)
        case .hairline: return dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)
        case .accent:   return hex(0xFF6A00)
        case .onAccent: return .white
        case .ready:    return hex(0x30D158)
        case .heating:  return hex(0xFF6A00)
        case .cooling:  return hex(0x0A84FF)
        case .charging: return hex(0x30D158)
        case .offline:  return dark ? Color.white.opacity(0.4) : Color.black.opacity(0.4)
        case .low:      return hex(0xFF453A)
        case .heroFill, .heroFillEnd: return hex(0xFF6A00)
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    // MARK: Metrics

    func metric(_ role: MetricRole) -> CGFloat {
        if let value = theme.metrics?[role.rawValue] { return CGFloat(value) }
        return Self.defaultMetric(role)
    }

    static func defaultMetric(_ role: MetricRole) -> CGFloat {
        switch role {
        case .gutter:         return 16
        case .radius:         return 18
        case .plateRadius:    return 19
        case .hairlineWidth:  return 1
        case .heroSize:       return 66
        case .presetHeight:   return 44
        case .modeHeight:     return 72
        case .stepSize:       return 52
        case .capsuleHeight:  return 38
        case .headerHeight:   return 52
        case .scaleStroke:    return 26
        case .sectionGap:     return 22
        }
    }

    var gutter: CGFloat { metric(.gutter) }
    var radius: CGFloat { metric(.radius) }
    var hairlineWidth: CGFloat { metric(.hairlineWidth) }

    // MARK: Type

    private var type: ThemeTypography { theme.typography ?? ThemeTypography() }

    private func design(_ name: String?) -> Font.Design {
        switch name?.lowercased() {
        case "serif":      return .serif
        case "rounded":    return .rounded
        case "monospaced": return .monospaced
        default:           return .default
        }
    }

    private var fontWidth: Font.Width {
        switch type.width?.lowercased() {
        case "condensed": return .condensed
        case "expanded":  return .expanded
        default:          return .standard
        }
    }

    /// A theme's own face when it is genuinely installed, otherwise the system
    /// family it nominated. Checked against UIFont so a missing font degrades
    /// to something considered rather than to Helvetica.
    private func font(family: String?, size: CGFloat, weight: Font.Weight, design name: String?) -> Font {
        if let family, !family.isEmpty, Self.isAvailable(family) {
            return Font.custom(family, size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: design(name)).width(fontWidth)
    }

    private static var availabilityCache: [String: Bool] = [:]

    static func isAvailable(_ family: String) -> Bool {
        if let known = availabilityCache[family] { return known }
        let found = UIFont(name: family, size: 12) != nil
            || UIFont.familyNames.contains { $0.caseInsensitiveCompare(family) == .orderedSame }
        availabilityCache[family] = found
        return found
    }

    /// Body and control text.
    func body(_ size: CGFloat, _ weight: Font.Weight? = nil) -> Font {
        font(family: type.family,
             size: size,
             weight: weight ?? ThemeTypography.weight(type.bodyWeight, default: .regular),
             design: type.design)
    }

    /// Display type: the readout, and anything set large.
    func display(_ size: CGFloat, _ weight: Font.Weight? = nil) -> Font {
        font(family: type.displayFamily ?? type.family,
             size: size,
             weight: weight ?? ThemeTypography.weight(type.heroWeight, default: .semibold),
             design: type.displayDesign ?? type.design)
    }

    /// The small tracked-out labels over each section.
    func label() -> Font {
        font(family: type.family,
             size: CGFloat(type.labelSize ?? 12),
             weight: ThemeTypography.weight(type.labelWeight, default: .semibold),
             design: type.design)
    }

    var labelTracking: CGFloat { CGFloat(type.labelTracking ?? 1.2) }
    var heroTracking: CGFloat { CGFloat(type.heroTracking ?? -2.3) }
    var heroSize: CGFloat { metric(.heroSize) }
    var tabular: Bool { type.tabular ?? true }

    var labelCase: ThemeLabelCase {
        ThemeLabelCase(rawValue: type.labelCase ?? "upper") ?? .upper
    }

    /// Section labels, cased the way the theme wants them.
    func labelText(_ text: String) -> String {
        switch labelCase {
        case .lower:    return text.lowercased()
        case .upper:    return text.uppercased()
        case .sentence: return text
        }
    }
}

// MARK: - Environment

private struct ThemeTokensKey: EnvironmentKey {
    static let defaultValue = ThemeTokens(theme: ThemeCatalog.classic, scheme: .dark)
}

extension EnvironmentValues {
    var tokens: ThemeTokens {
        get { self[ThemeTokensKey.self] }
        set { self[ThemeTokensKey.self] = newValue }
    }
}

extension View {
    /// Applies a theme's label casing and tracking to a section label.
    func themeLabel(_ tokens: ThemeTokens) -> some View {
        self.font(tokens.label())
            .tracking(tokens.labelTracking)
            .foregroundStyle(tokens.muted)
    }
}
