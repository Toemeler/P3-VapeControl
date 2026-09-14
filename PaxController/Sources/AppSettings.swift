import Combine
import Foundation

/// User preferences, persisted to UserDefaults. Shared as an EnvironmentObject
/// so the accent color and temperature unit apply across every tab.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let ledColor        = "ledColorHex"
        static let pushColor       = "pushLedColorToDevice"
        static let autoConnect     = "autoConnectEnabled"
        static let liveActivity    = "liveActivityEnabled"
        static let temperatureUnit = "temperatureUnit"
    }

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

    @Published var useFahrenheit: Bool {
        didSet { defaults.set(useFahrenheit ? "fahrenheit" : "celsius", forKey: Key.temperatureUnit) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledColorHex       = defaults.string(forKey: Key.ledColor) ?? LedColor.orange.hex
        pushColorToDevice = defaults.object(forKey: Key.pushColor) as? Bool ?? true
        autoConnectEnabled = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Key.liveActivity) as? Bool ?? true
        useFahrenheit = defaults.string(forKey: Key.temperatureUnit) == "fahrenheit"
    }

    var ledColor: LedColor {
        LedColor.fromHex(ledColorHex) ?? .orange
    }
}
