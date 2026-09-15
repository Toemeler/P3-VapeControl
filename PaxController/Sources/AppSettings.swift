import Combine
import Foundation

/// User preferences, persisted to UserDefaults. Shared as an EnvironmentObject
/// so the accent color and temperature unit apply across the whole app.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        /// Shared with `LedColor.current`, which reads it without actor isolation.
        static let ledColor        = LedColor.defaultsKey
        static let pushColor       = "pushLedColorToDevice"
        static let autoConnect     = "autoConnectEnabled"
        static let liveActivity    = "liveActivityEnabled"
        static let temperatureUnit = "temperatureUnit"
        static let perModeColors   = "perModeLedColors"
        static let modeColors      = "ledModeColorHexes"
    }

    /// Drives `DS.Palette.accent`, so it re-themes the dial, chips and buttons.
    @Published var ledColorHex: String {
        didSet { defaults.set(ledColorHex, forKey: Key.ledColor) }
    }

    /// Whether to also push the chosen color to the PAX itself. The ShellColor
    /// payload format is undocumented (see protocol-notes.md), so this is a
    /// best-effort experiment — the app works fine with it off.
    @Published var pushColorToDevice: Bool {
        didSet { defaults.set(pushColorToDevice, forKey: Key.pushColor) }
    }

    @Published var autoConnectEnabled: Bool {
        didSet { defaults.set(autoConnectEnabled, forKey: Key.autoConnect) }
    }

    @Published var liveActivityEnabled: Bool {
        didSet { defaults.set(liveActivityEnabled, forKey: Key.liveActivity) }
    }

    /// Same key and raw values the views used via `@AppStorage`, so an existing
    /// install keeps whatever unit it was already set to.
    @Published var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
    }

    /// Whether each of the PAX's four states gets its own pair of colours, or
    /// the single colour above paints all of them.
    @Published var perModeLedColors: Bool {
        didSet { defaults.set(perModeLedColors, forKey: Key.perModeColors) }
    }

    /// Eight hex strings: colour 1 and colour 2 for each of the four modes, in
    /// `PaxColorTheme.Mode` order.
    @Published var modeLedHexes: [String] {
        didSet { defaults.set(modeLedHexes, forKey: Key.modeColors) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Held locally as well: Swift forbids reading a property back through
        // `self` until every stored property has a value, and the per-mode
        // colours below fall back to this one.
        let hex = defaults.string(forKey: Key.ledColor) ?? LedColor.orange.hex
        ledColorHex         = hex
        pushColorToDevice   = defaults.object(forKey: Key.pushColor) as? Bool ?? true
        autoConnectEnabled  = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Key.liveActivity) as? Bool ?? true
        temperatureUnit     = defaults.string(forKey: Key.temperatureUnit)
            .flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        perModeLedColors    = defaults.object(forKey: Key.perModeColors) as? Bool ?? false
        // Anything but eight parseable colours is treated as absent rather than
        // patched up: a half-read list would write colours nobody chose.
        let stored = defaults.stringArray(forKey: Key.modeColors) ?? []
        let valid = stored.count == Self.modeSlotCount
            && stored.allSatisfy { LedColor.fromHex($0) != nil }
        modeLedHexes = valid ? stored
            : Array(repeating: hex, count: Self.modeSlotCount)
    }

    /// Four modes, two colours each.
    static let modeSlotCount = PaxColorTheme.modeCount * 2

    /// The colour pair for one mode, as `PaxColorTheme.perMode` wants them.
    func modeColors(_ mode: Int) -> (LedColor, LedColor) {
        let fallback = ledColor
        let first = modeLedHexes.indices.contains(mode * 2)
            ? LedColor.fromHex(modeLedHexes[mode * 2]) ?? fallback : fallback
        let second = modeLedHexes.indices.contains(mode * 2 + 1)
            ? LedColor.fromHex(modeLedHexes[mode * 2 + 1]) ?? fallback : fallback
        return (first, second)
    }

    var modeColorPairs: [(LedColor, LedColor)] {
        (0..<PaxColorTheme.modeCount).map(modeColors)
    }

    func setModeColor(_ color: LedColor, mode: Int, slot: Int) {
        let index = mode * 2 + slot
        guard modeLedHexes.indices.contains(index) else { return }
        modeLedHexes[index] = color.hex
    }

    /// Fills the per-mode colours in from what the device is actually showing,
    /// so switching the toggle on starts from the PAX's own theme rather than
    /// from eight copies of the accent colour.
    func seedModeColors(from theme: PaxColorTheme?) {
        guard let theme else {
            modeLedHexes = Array(repeating: ledColorHex, count: Self.modeSlotCount)
            return
        }
        var hexes: [String] = []
        for i in 0..<PaxColorTheme.modeCount {
            guard theme.modes.indices.contains(i) else {
                hexes.append(ledColorHex)
                hexes.append(ledColorHex)
                continue
            }
            let mode = theme.modes[i]
            hexes.append(String(format: "#%02X%02X%02X", mode.color1.r, mode.color1.g, mode.color1.b))
            hexes.append(String(format: "#%02X%02X%02X", mode.color2.r, mode.color2.g, mode.color2.b))
        }
        modeLedHexes = hexes
    }

    var ledColor: LedColor {
        LedColor.fromHex(ledColorHex) ?? .orange
    }

    /// The Live Activity payload carries a plain Bool: the widget extension
    /// does not compile DesignSystem.swift, so `TemperatureUnit` is not in scope there.
    var useFahrenheit: Bool { temperatureUnit == .fahrenheit }
}
