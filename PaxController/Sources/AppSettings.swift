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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledColorHex         = defaults.string(forKey: Key.ledColor) ?? LedColor.orange.hex
        pushColorToDevice   = defaults.object(forKey: Key.pushColor) as? Bool ?? true
        autoConnectEnabled  = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Key.liveActivity) as? Bool ?? true
        temperatureUnit     = defaults.string(forKey: Key.temperatureUnit)
            .flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
    }

    var ledColor: LedColor {
        LedColor.fromHex(ledColorHex) ?? .orange
    }

    /// The Live Activity payload carries a plain Bool: the widget extension
    /// does not compile DesignSystem.swift, so `TemperatureUnit` is not in scope there.
    var useFahrenheit: Bool { temperatureUnit == .fahrenheit }
}
