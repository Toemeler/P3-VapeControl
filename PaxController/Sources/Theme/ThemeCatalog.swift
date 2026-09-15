import SwiftUI

/// The themes that ship with the app.
///
/// Each one is the same data an imported theme file carries, so nothing here is
/// privileged: a downloaded theme can do everything these do, and any of these
/// can be exported, edited and imported back.
enum ThemeCatalog {

    /// In catalog order, which is the order the picker shows them in.
    static var all: [AppTheme] {
        [classic, werkstatt, editorial, native, thermal, instrument,
         chart, surface, sentence, object, clock]
    }

    static let defaultThemeID = "classic"

    static func builtIn(_ id: String) -> AppTheme? {
        all.first { $0.id == id }
    }

    /// Shorthand so the tables below read as a palette rather than as syntax.
    private static func p(_ pairs: (ColorRole, String)...) -> [String: ThemeColor] {
        var out: [String: ThemeColor] = [:]
        for (role, hex) in pairs { out[role.rawValue] = ThemeColor(hex) }
        return out
    }

    private static func m(_ pairs: (MetricRole, Double)...) -> [String: Double] {
        var out: [String: Double] = [:]
        for (role, value) in pairs { out[role.rawValue] = value }
        return out
    }

    // MARK: - Classic

    /// The screen as the app has always drawn it. Its accent follows the LED
    /// colour, because that is how that setting has always behaved.
    static let classic = AppTheme(
        id: "classic",
        name: "Classic",
        author: "P3 VapeControl",
        summary: "The original dial: a glowing arc, a nested battery ring, and the LED colour you picked.",
        shell: ThemeShell.stacked.rawValue,
        hero: ThemeHero.arc.rawValue,
        target: ThemeTargetStyle.stepperRound.rawValue,
        presets: ThemePresetStyle.capsules.rawValue,
        modes: ThemeModeStyle.tiles.rawValue,
        typography: ThemeTypography(
            labelCase: ThemeLabelCase.upper.rawValue,
            labelTracking: 1.2, labelSize: 12, labelWeight: "bold",
            heroWeight: "semibold", heroTracking: -2.3, tabular: true),
        light: p((.canvas, "#F4F3F1"), (.plate, "#E6E4E1"), (.track, "#DCDAD6"),
                 (.ink, "#111111"), (.muted, "#3C3C4399"), (.hairline, "#00000024"),
                 (.accent, "#FF6A00"), (.onAccent, "#FFFFFF"),
                 (.ready, "#248A3D"), (.heating, "#FF6A00"), (.cooling, "#007AFF"),
                 (.charging, "#248A3D"), (.offline, "#3C3C4399"), (.low, "#FF3B30")),
        dark: p((.canvas, "#17171A"), (.plate, "#2A2A2F"), (.track, "#2F2F35"),
                (.ink, "#FFFFFF"), (.muted, "#EBEBF599"), (.hairline, "#FFFFFF24"),
                (.accent, "#FF6A00"), (.onAccent, "#FFFFFF"),
                (.ready, "#30D158"), (.heating, "#FF6A00"), (.cooling, "#0A84FF"),
                (.charging, "#30D158"), (.offline, "#EBEBF566"), (.low, "#FF453A")),
        metrics: m((.gutter, 16), (.radius, 18), (.plateRadius, 19), (.heroSize, 66),
                   (.presetHeight, 44), (.modeHeight, 72), (.stepSize, 52),
                   (.capsuleHeight, 38), (.headerHeight, 52), (.scaleStroke, 26),
                   (.sectionGap, 22)),
        accentFollowsLed: true,
        formatVersion: 1)

    // MARK: - Werkstatt

    static let werkstatt = AppTheme(
        id: "werkstatt",
        name: "Werkstatt",
        author: "P3 VapeControl",
        summary: "Braun functionalism. Matte plates, 4 pt corners, lowercase labels, and one accent kept for the temperature you set.",
        shell: ThemeShell.stacked.rawValue,
        hero: ThemeHero.linearScale.rawValue,
        target: ThemeTargetStyle.stepperPlate.rawValue,
        presets: ThemePresetStyle.plates.rawValue,
        modes: ThemeModeStyle.switchBar.rawValue,
        typography: ThemeTypography(
            family: "Archivo",
            labelCase: ThemeLabelCase.lower.rawValue,
            labelTracking: 0.8, labelSize: 11, labelWeight: "medium",
            heroWeight: "medium", heroTracking: -2.8, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#D9D5CC"), (.plate, "#EFECE5"), (.track, "#1C1B181A"),
                 (.ink, "#1C1B18"), (.muted, "#6B6960"), (.hairline, "#1C1B1824"),
                 (.accent, "#C0421C"), (.onAccent, "#F6F3EC"),
                 (.ready, "#1C1B18"), (.heating, "#C0421C"), (.cooling, "#6B6960"),
                 (.charging, "#1C1B18"), (.offline, "#6B6960"), (.low, "#A33217")),
        dark: p((.canvas, "#1E1D1A"), (.plate, "#2A2925"), (.track, "#FFFFFF1F"),
                (.ink, "#EDEAE3"), (.muted, "#9A968C"), (.hairline, "#FFFFFF1F"),
                (.accent, "#E0562A"), (.onAccent, "#1E1D1A"),
                (.ready, "#EDEAE3"), (.heating, "#E0562A"), (.cooling, "#9A968C"),
                (.charging, "#EDEAE3"), (.offline, "#9A968C"), (.low, "#E0562A")),
        metrics: m((.gutter, 24), (.radius, 4), (.plateRadius, 4), (.hairlineWidth, 1),
                   (.heroSize, 82), (.presetHeight, 46), (.modeHeight, 50),
                   (.stepSize, 46), (.capsuleHeight, 34), (.headerHeight, 34),
                   (.scaleStroke, 8), (.sectionGap, 24)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Editorial

    static let editorial = AppTheme(
        id: "editorial",
        name: "Editorial",
        author: "P3 VapeControl",
        summary: "A Swiss page. No cards, no fills, no corners: hairline rules and a display serif do all the work.",
        shell: ThemeShell.stacked.rawValue,
        hero: ThemeHero.rule.rawValue,
        target: ThemeTargetStyle.stepperHairline.rawValue,
        presets: ThemePresetStyle.table.rawValue,
        modes: ThemeModeStyle.list.rawValue,
        typography: ThemeTypography(
            design: "default", displayDesign: "serif",
            family: "IBM Plex Mono", displayFamily: "Instrument Serif",
            labelCase: ThemeLabelCase.upper.rawValue,
            labelTracking: 1.6, labelSize: 9.5, labelWeight: "medium",
            heroWeight: "regular", heroTracking: -3.6, bodyWeight: "regular", tabular: false),
        light: p((.canvas, "#F6F4EF"), (.plate, "#F6F4EF"), (.track, "#17160F29"),
                 (.ink, "#17160F"), (.muted, "#17160F80"), (.hairline, "#17160F29"),
                 (.accent, "#A8341B"), (.onAccent, "#F6F4EF"),
                 (.ready, "#17160F"), (.heating, "#A8341B"), (.cooling, "#17160F80"),
                 (.charging, "#17160F"), (.offline, "#17160F66"), (.low, "#A8341B")),
        dark: p((.canvas, "#14130E"), (.plate, "#14130E"), (.track, "#F2EFE629"),
                (.ink, "#F2EFE6"), (.muted, "#F2EFE680"), (.hairline, "#F2EFE629"),
                (.accent, "#D4623F"), (.onAccent, "#14130E"),
                (.ready, "#F2EFE6"), (.heating, "#D4623F"), (.cooling, "#F2EFE680"),
                (.charging, "#F2EFE6"), (.offline, "#F2EFE666"), (.low, "#D4623F")),
        metrics: m((.gutter, 24), (.radius, 0), (.plateRadius, 0), (.hairlineWidth, 1),
                   (.heroSize, 122), (.presetHeight, 62), (.modeHeight, 44),
                   (.stepSize, 46), (.capsuleHeight, 30), (.headerHeight, 30),
                   (.scaleStroke, 3), (.sectionGap, 30)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Native

    static let native = AppTheme(
        id: "native",
        name: "Native",
        author: "P3 VapeControl",
        summary: "Look like the phone, not like an app. System type, grouped cards, a stock slider and a checkmark list.",
        shell: ThemeShell.stacked.rawValue,
        hero: ThemeHero.card.rawValue,
        target: ThemeTargetStyle.slider.rawValue,
        presets: ThemePresetStyle.segmented.rawValue,
        modes: ThemeModeStyle.list.rawValue,
        typography: ThemeTypography(
            labelCase: ThemeLabelCase.upper.rawValue,
            labelTracking: 0.3, labelSize: 13, labelWeight: "regular",
            heroWeight: "semibold", heroTracking: -1.2, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#F2F2F7"), (.plate, "#FFFFFF"), (.track, "#78788029"),
                 (.ink, "#000000"), (.muted, "#3C3C4399"), (.hairline, "#3C3C434A"),
                 (.accent, "#FF9500"), (.onAccent, "#FFFFFF"),
                 (.ready, "#248A3D"), (.heating, "#FF9500"), (.cooling, "#007AFF"),
                 (.charging, "#248A3D"), (.offline, "#3C3C4399"), (.low, "#FF3B30")),
        dark: p((.canvas, "#000000"), (.plate, "#1C1C1E"), (.track, "#7878805C"),
                (.ink, "#FFFFFF"), (.muted, "#EBEBF599"), (.hairline, "#54545899"),
                (.accent, "#FF9F0A"), (.onAccent, "#FFFFFF"),
                (.ready, "#30D158"), (.heating, "#FF9F0A"), (.cooling, "#0A84FF"),
                (.charging, "#30D158"), (.offline, "#EBEBF566"), (.low, "#FF453A")),
        metrics: m((.gutter, 16), (.radius, 10), (.plateRadius, 10), (.hairlineWidth, 0.5),
                   (.heroSize, 52), (.presetHeight, 44), (.modeHeight, 44),
                   (.stepSize, 44), (.capsuleHeight, 34), (.headerHeight, 44),
                   (.scaleStroke, 4), (.sectionGap, 18)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Thermal

    static let thermal = AppTheme(
        id: "thermal",
        name: "Thermal",
        author: "P3 VapeControl",
        summary: "Warm graphite, no ring. The oven is a column filling from cold, so the warm-up has somewhere to show.",
        shell: ThemeShell.stacked.rawValue,
        hero: ThemeHero.column.rawValue,
        target: ThemeTargetStyle.stepperPlate.rawValue,
        presets: ThemePresetStyle.plates.rawValue,
        modes: ThemeModeStyle.keys.rawValue,
        typography: ThemeTypography(
            width: "condensed", family: "Barlow", displayFamily: "Barlow Condensed",
            labelCase: ThemeLabelCase.lower.rawValue,
            labelTracking: 1.9, labelSize: 9.5, labelWeight: "semibold",
            heroWeight: "medium", heroTracking: -1, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#EFEBE4"), (.plate, "#E2DDD3"), (.track, "#D8D2C6"),
                 (.ink, "#221F1A"), (.muted, "#221F1A8C"), (.hairline, "#221F1A1F"),
                 (.accent, "#C2450F"), (.onAccent, "#FFF8F0"),
                 (.ready, "#221F1A"), (.heating, "#C2450F"), (.cooling, "#4A6B7C"),
                 (.charging, "#3F6B4A"), (.offline, "#221F1A8C"), (.low, "#C2450F"),
                 (.heroFill, "#C2450F"), (.heroFillEnd, "#FF8A3D")),
        dark: p((.canvas, "#1B1A18"), (.plate, "#262522"), (.track, "#201F1C"),
                (.ink, "#EDEAE3"), (.muted, "#EDEAE373"), (.hairline, "#FFFFFF14"),
                (.accent, "#E2571B"), (.onAccent, "#1B1A18"),
                (.ready, "#EDEAE3"), (.heating, "#E2571B"), (.cooling, "#7FA3B5"),
                (.charging, "#8FBF7A"), (.offline, "#EDEAE373"), (.low, "#E2571B"),
                (.heroFill, "#4A1704"), (.heroFillEnd, "#FF8A3D")),
        metrics: m((.gutter, 20), (.radius, 3), (.plateRadius, 3), (.hairlineWidth, 1),
                   (.heroSize, 108), (.presetHeight, 46), (.modeHeight, 62),
                   (.stepSize, 46), (.capsuleHeight, 34), (.headerHeight, 40),
                   (.scaleStroke, 50), (.sectionGap, 24)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Instrument

    static let instrument = AppTheme(
        id: "instrument",
        name: "Instrument",
        author: "P3 VapeControl",
        summary: "A printed gauge rather than a glowing one: ivory face, every degree marked, a needle for the oven and a bezel index for your target.",
        shell: ThemeShell.stacked.rawValue,
        hero: ThemeHero.gauge.rawValue,
        target: ThemeTargetStyle.stepperPlate.rawValue,
        presets: ThemePresetStyle.plates.rawValue,
        modes: ThemeModeStyle.selector.rawValue,
        typography: ThemeTypography(
            family: "DM Sans",
            labelCase: ThemeLabelCase.lower.rawValue,
            labelTracking: 1.5, labelSize: 9.5, labelWeight: "medium",
            heroWeight: "medium", heroTracking: -1, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#DED8CA"), (.plate, "#F4EFE2"), (.track, "#CBC4B3"),
                 (.ink, "#22211C"), (.muted, "#22211C80"), (.hairline, "#22211C38"),
                 (.accent, "#A8322A"), (.onAccent, "#F4EFE2"),
                 (.ready, "#22211C"), (.heating, "#A8322A"), (.cooling, "#4A6B7C"),
                 (.charging, "#3F6B4A"), (.offline, "#22211C80"), (.low, "#A8322A")),
        dark: p((.canvas, "#22211C"), (.plate, "#2D2C25"), (.track, "#3A382F"),
                (.ink, "#F0EBDD"), (.muted, "#F0EBDD80"), (.hairline, "#F0EBDD2E"),
                (.accent, "#C9483D"), (.onAccent, "#22211C"),
                (.ready, "#F0EBDD"), (.heating, "#C9483D"), (.cooling, "#7FA3B5"),
                (.charging, "#8FBF7A"), (.offline, "#F0EBDD80"), (.low, "#C9483D")),
        metrics: m((.gutter, 22), (.radius, 3), (.plateRadius, 3), (.hairlineWidth, 1),
                   (.heroSize, 46), (.presetHeight, 46), (.modeHeight, 52),
                   (.stepSize, 46), (.capsuleHeight, 34), (.headerHeight, 34),
                   (.scaleStroke, 11), (.sectionGap, 22)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Chart

    static let chart = AppTheme(
        id: "chart",
        name: "Chart",
        author: "P3 VapeControl",
        summary: "The session is the screen: the warm-up curve, the target it settled on, and every draw as a notch. Presets are detents on the target scale.",
        shell: ThemeShell.chart.rawValue,
        hero: ThemeHero.none.rawValue,
        target: ThemeTargetStyle.detents.rawValue,
        presets: ThemePresetStyle.detents.rawValue,
        modes: ThemeModeStyle.words.rawValue,
        typography: ThemeTypography(
            family: "Space Grotesk",
            labelCase: ThemeLabelCase.upper.rawValue,
            labelTracking: 1.1, labelSize: 9.5, labelWeight: "medium",
            heroWeight: "medium", heroTracking: -2.2, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#FBFAF6"), (.plate, "#FBFAF6"), (.track, "#1A19141F"),
                 (.ink, "#1A1914"), (.muted, "#7A776C"), (.hairline, "#1A19142B"),
                 (.accent, "#B4471F"), (.onAccent, "#FBFAF6"),
                 (.ready, "#1A1914"), (.heating, "#B4471F"), (.cooling, "#4A6B8A"),
                 (.charging, "#3F6B4A"), (.offline, "#7A776C"), (.low, "#B4471F")),
        dark: p((.canvas, "#121210"), (.plate, "#1A1917"), (.track, "#F2EFE61F"),
                (.ink, "#F2EFE6"), (.muted, "#9B978B"), (.hairline, "#F2EFE62B"),
                (.accent, "#E06A34"), (.onAccent, "#121210"),
                (.ready, "#F2EFE6"), (.heating, "#E06A34"), (.cooling, "#7FA3C4"),
                (.charging, "#8FBF7A"), (.offline, "#9B978B"), (.low, "#E06A34")),
        metrics: m((.gutter, 20), (.radius, 2), (.plateRadius, 2), (.hairlineWidth, 1),
                   (.heroSize, 62), (.presetHeight, 44), (.modeHeight, 44),
                   (.stepSize, 44), (.capsuleHeight, 32), (.headerHeight, 34),
                   (.scaleStroke, 2), (.sectionGap, 16)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Surface

    static let surface = AppTheme(
        id: "surface",
        name: "Surface",
        author: "P3 VapeControl",
        summary: "The display is the control. Drag anywhere to move the boundary; the number is its handle and the presets are detents on the edge.",
        shell: ThemeShell.field.rawValue,
        hero: ThemeHero.none.rawValue,
        target: ThemeTargetStyle.none.rawValue,
        presets: ThemePresetStyle.none.rawValue,
        modes: ThemeModeStyle.none.rawValue,
        typography: ThemeTypography(
            family: "Instrument Sans",
            labelCase: ThemeLabelCase.lower.rawValue,
            labelTracking: 1.6, labelSize: 10, labelWeight: "semibold",
            heroWeight: "medium", heroTracking: -7.4, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#F2EDE4"), (.plate, "#E6DFD2"), (.track, "#211C161C"),
                 (.ink, "#211C16"), (.muted, "#211C168C"), (.hairline, "#211C1638"),
                 (.accent, "#8A3614"), (.onAccent, "#F6EDE2"),
                 (.ready, "#211C16"), (.heating, "#A8471F"), (.cooling, "#4A6B7C"),
                 (.charging, "#3F6B4A"), (.offline, "#211C168C"), (.low, "#A8471F"),
                 (.heroFill, "#8A3614"), (.heroFillEnd, "#A8471F")),
        dark: p((.canvas, "#15120F"), (.plate, "#211C16"), (.track, "#F2EDE41C"),
                (.ink, "#F2EDE4"), (.muted, "#F2EDE47A"), (.hairline, "#F2EDE438"),
                (.accent, "#C4571F"), (.onAccent, "#1A1512"),
                (.ready, "#F2EDE4"), (.heating, "#C4571F"), (.cooling, "#7FA3B5"),
                (.charging, "#8FBF7A"), (.offline, "#F2EDE47A"), (.low, "#C4571F"),
                (.heroFill, "#6B2A0E"), (.heroFillEnd, "#C4571F")),
        metrics: m((.gutter, 28), (.radius, 0), (.plateRadius, 0), (.hairlineWidth, 1.5),
                   (.heroSize, 124), (.presetHeight, 44), (.modeHeight, 48),
                   (.stepSize, 44), (.capsuleHeight, 34), (.headerHeight, 34),
                   (.scaleStroke, 2), (.sectionGap, 20)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Sentence

    static let sentence = AppTheme(
        id: "sentence",
        name: "Sentence",
        author: "P3 VapeControl",
        summary: "No components. The state is a sentence, the words you can change are the controls, and the accent colour is the state.",
        shell: ThemeShell.prose.rawValue,
        hero: ThemeHero.none.rawValue,
        target: ThemeTargetStyle.none.rawValue,
        presets: ThemePresetStyle.words.rawValue,
        modes: ThemeModeStyle.words.rawValue,
        typography: ThemeTypography(
            family: "Bricolage Grotesque",
            labelCase: ThemeLabelCase.lower.rawValue,
            labelTracking: 1.7, labelSize: 10, labelWeight: "semibold",
            heroWeight: "heavy", heroTracking: -3.7, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#FFFDF8"), (.plate, "#FFFDF8"), (.track, "#14130F24"),
                 (.ink, "#14130F"), (.muted, "#14130F8C"), (.hairline, "#14130F2E"),
                 (.accent, "#15604A"), (.onAccent, "#FFFDF8"),
                 (.ready, "#15604A"), (.heating, "#A85A18"), (.cooling, "#1F5478"),
                 (.charging, "#15604A"), (.offline, "#6A665C"), (.low, "#A8341B")),
        dark: p((.canvas, "#131311"), (.plate, "#131311"), (.track, "#F4F1EA24"),
                (.ink, "#F4F1EA"), (.muted, "#F4F1EA73"), (.hairline, "#F4F1EA2E"),
                (.accent, "#4FB08C"), (.onAccent, "#131311"),
                (.ready, "#4FB08C"), (.heating, "#D08A3A"), (.cooling, "#5A93C4"),
                (.charging, "#4FB08C"), (.offline, "#8A867C"), (.low, "#D4623F")),
        metrics: m((.gutter, 26), (.radius, 0), (.plateRadius, 0), (.hairlineWidth, 1),
                   (.heroSize, 74), (.presetHeight, 56), (.modeHeight, 52),
                   (.stepSize, 46), (.capsuleHeight, 34), (.headerHeight, 40),
                   (.scaleStroke, 4), (.sectionGap, 26)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Object

    static let object = AppTheme(
        id: "object",
        name: "Object",
        author: "P3 VapeControl",
        summary: "The app shows you the thing. A generic vessel fills with heat, your target is an index on its edge, and the data is furniture underneath.",
        shell: ThemeShell.object.rawValue,
        hero: ThemeHero.none.rawValue,
        target: ThemeTargetStyle.stepperRound.rawValue,
        presets: ThemePresetStyle.words.rawValue,
        modes: ThemeModeStyle.dots.rawValue,
        typography: ThemeTypography(
            family: "Manrope",
            labelCase: ThemeLabelCase.upper.rawValue,
            labelTracking: 1.7, labelSize: 10, labelWeight: "bold",
            heroWeight: "semibold", heroTracking: -2.2, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#E4E0D7"), (.plate, "#EFEBE2"), (.track, "#2822191A"),
                 (.ink, "#282219"), (.muted, "#28221973"), (.hairline, "#28221929"),
                 (.accent, "#C2522A"), (.onAccent, "#FBF8F2"),
                 (.ready, "#282219"), (.heating, "#C2522A"), (.cooling, "#4A6B7C"),
                 (.charging, "#3F6B4A"), (.offline, "#28221973"), (.low, "#C2522A"),
                 (.heroFill, "#A8421F"), (.heroFillEnd, "#E4915A")),
        dark: p((.canvas, "#1C1B18"), (.plate, "#2A2825"), (.track, "#F2EEE51A"),
                (.ink, "#F2EEE5"), (.muted, "#F2EEE573"), (.hairline, "#F2EEE529"),
                (.accent, "#D9663A"), (.onAccent, "#1C1B18"),
                (.ready, "#F2EEE5"), (.heating, "#D9663A"), (.cooling, "#7FA3B5"),
                (.charging, "#8FBF7A"), (.offline, "#F2EEE573"), (.low, "#D9663A"),
                (.heroFill, "#8E3416"), (.heroFillEnd, "#E4915A")),
        metrics: m((.gutter, 24), (.radius, 22), (.plateRadius, 24), (.hairlineWidth, 1),
                   (.heroSize, 54), (.presetHeight, 44), (.modeHeight, 30),
                   (.stepSize, 48), (.capsuleHeight, 30), (.headerHeight, 30),
                   (.scaleStroke, 9), (.sectionGap, 18)),
        accentFollowsLed: false,
        formatVersion: 1)

    // MARK: - Clock

    static let clock = AppTheme(
        id: "clock",
        name: "Clock",
        author: "P3 VapeControl",
        summary: "Time takes the top third, because that is what you open the app to ask. Temperature drops to a table until it matters again.",
        shell: ThemeShell.countdown.rawValue,
        hero: ThemeHero.none.rawValue,
        target: ThemeTargetStyle.stepperHairline.rawValue,
        presets: ThemePresetStyle.plates.rawValue,
        modes: ThemeModeStyle.words.rawValue,
        typography: ThemeTypography(
            family: "Chivo",
            labelCase: ThemeLabelCase.upper.rawValue,
            labelTracking: 1.8, labelSize: 10, labelWeight: "bold",
            heroWeight: "black", heroTracking: -7.9, bodyWeight: "regular", tabular: true),
        light: p((.canvas, "#F8F6F1"), (.plate, "#F8F6F1"), (.track, "#1C1A161A"),
                 (.ink, "#1C1A16"), (.muted, "#1C1A1673"), (.hairline, "#1C1A162E"),
                 (.accent, "#A85A18"), (.onAccent, "#F8F6F1"),
                 (.ready, "#1C1A16"), (.heating, "#A85A18"), (.cooling, "#1F5478"),
                 (.charging, "#3F6B4A"), (.offline, "#1C1A1673"), (.low, "#A8341B")),
        dark: p((.canvas, "#16150F"), (.plate, "#1E1D17"), (.track, "#F2EFE61A"),
                (.ink, "#F2EFE6"), (.muted, "#F2EFE673"), (.hairline, "#F2EFE62E"),
                (.accent, "#D08A3A"), (.onAccent, "#16150F"),
                (.ready, "#F2EFE6"), (.heating, "#D08A3A"), (.cooling, "#5A93C4"),
                (.charging, "#8FBF7A"), (.offline, "#F2EFE673"), (.low, "#D4623F")),
        metrics: m((.gutter, 24), (.radius, 0), (.plateRadius, 0), (.hairlineWidth, 1),
                   (.heroSize, 132), (.presetHeight, 46), (.modeHeight, 44),
                   (.stepSize, 46), (.capsuleHeight, 32), (.headerHeight, 34),
                   (.scaleStroke, 12), (.sectionGap, 30)),
        accentFollowsLed: false,
        formatVersion: 1)
}
