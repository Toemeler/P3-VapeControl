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
        static let readyAlert      = "notifyWhenReady"
        static let warmUpGradient  = "warmUpGradient"
        static let nickname        = "deviceNickname"
        static let paletteVersion  = "ledPaletteVersion"
        static let lipDetection    = "lipDetectionEnabled"
        static let lipCooling      = "lipCoolingEnabled"
        static let lipShutdown     = "lipShutdownEnabled"
        static let autoOff         = "autoOffEnabled"
        static let autoOffMinutes  = "autoOffMinutes"
        static let doseLimit       = "doseLimitEnabled"
        static let doseDraws       = "doseLimitDraws"
        static let profiles        = "savedProfiles"
        static let schedule        = "temperatureSchedule"
        static let scheduleOn      = "temperatureScheduleEnabled"
        static let historyOn       = "sessionHistoryEnabled"
        static let heaterBit       = "heaterOptionBit"
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

    /// A name the user chose that the device would not take. Kept so a rename
    /// still means something on firmware that ignores it — the app, the Lock
    /// Screen card and Siri all use it, and it is cleared the moment a rename
    /// does reach the device.
    @Published var deviceNickname: String? {
        didSet { defaults.set(deviceNickname, forKey: Key.nickname) }
    }

    /// Whether to raise a notification the moment the oven reaches the set
    /// point. On by default: it is the one thing worth interrupting for.
    @Published var notifyWhenReady: Bool {
        didSet { defaults.set(notifyWhenReady, forKey: Key.readyAlert) }
    }

    /// Whether the heating state's colour follows the thermometer on the way
    /// up — green, through yellow, to orange as it reaches the set point.
    @Published var warmUpGradient: Bool {
        didSet { defaults.set(warmUpGradient, forKey: Key.warmUpGradient) }
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

    /// The two halves of what the lip sensor does, kept apart because they are
    /// worth wanting separately: the cooldown is the annoyance a water-pipe
    /// adapter runs into, while the shutdown is the thing that stops a
    /// forgotten oven running. Neither is a preference the app acts on — both
    /// are a record of what was last written, since HeatingParams (0x19) is
    /// write-only on this firmware and nothing can read back whether it took.
    ///
    /// The third bit the official app groups with these is bit 0, which on a
    /// PAX 3 turns out to be the heater itself, so there is no boost bit here
    /// to offer.
    @Published var lipCoolingEnabled: Bool {
        didSet { defaults.set(lipCoolingEnabled, forKey: Key.lipCooling) }
    }

    @Published var lipShutdownEnabled: Bool {
        didSet { defaults.set(lipShutdownEnabled, forKey: Key.lipShutdown) }
    }

    /// Lip detection as one idea, for the places that only care whether the
    /// sensor drives the oven at all.
    var lipDetectionEnabled: Bool { lipCoolingEnabled && lipShutdownEnabled }

    /// Which bit of HeatingParams' options word this device uses for the
    /// heater, found by the probe. The official app's naming says bit 2; this
    /// PAX 3 stops its oven when one of the three "lip" bits is cleared, so the
    /// naming does not hold here and the measurement wins. Nil until measured.
    @Published var heaterOptionBit: Int? {
        didSet {
            if let bit = heaterOptionBit { defaults.set(bit, forKey: Key.heaterBit) }
            else { defaults.removeObject(forKey: Key.heaterBit) }
        }
    }

    // MARK: - The oven, on the app's terms

    /// Switch the oven off once a session has been idle this long. The device
    /// has its own version of this, tied to the lip sensor and fixed at three
    /// minutes; this one counts from the last draw, works with the lip sensor
    /// off, and can be set to something a person actually wants.
    @Published var autoOffEnabled: Bool {
        didSet { defaults.set(autoOffEnabled, forKey: Key.autoOff) }
    }

    @Published var autoOffMinutes: Int {
        didSet { defaults.set(autoOffMinutes, forKey: Key.autoOffMinutes) }
    }

    /// Switch the oven off after a set number of draws. Nothing on the device
    /// counts draws; the app does, because it watches the heating state.
    @Published var doseLimitEnabled: Bool {
        didSet { defaults.set(doseLimitEnabled, forKey: Key.doseLimit) }
    }

    @Published var doseLimitDraws: Int {
        didSet { defaults.set(doseLimitDraws, forKey: Key.doseDraws) }
    }

    /// Whether sessions are written down at all. Off means nothing is stored,
    /// and turning it off offers to clear what is already there.
    @Published var sessionHistoryEnabled: Bool {
        didSet { defaults.set(sessionHistoryEnabled, forKey: Key.historyOn) }
    }

    @Published var scheduleEnabled: Bool {
        didSet { defaults.set(scheduleEnabled, forKey: Key.scheduleOn) }
    }

    @Published var schedule: PaxSchedule {
        didSet { Self.store(schedule, in: defaults, forKey: Key.schedule) }
    }

    @Published var profiles: [PaxProfile] {
        didSet { Self.store(profiles, in: defaults, forKey: Key.profiles) }
    }

    private static func store<T: Encodable>(_ value: T, in defaults: UserDefaults, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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
        deviceNickname      = defaults.string(forKey: Key.nickname)
        notifyWhenReady     = defaults.object(forKey: Key.readyAlert) as? Bool ?? true
        warmUpGradient      = defaults.object(forKey: Key.warmUpGradient) as? Bool ?? true
        // On is the device's own default, and the one every vendor preset
        // ships with, so an install that has never touched this matches what
        // the PAX does out of the box. An install that set the single switch
        // before it was split inherits its value for both halves.
        let lipLegacy = defaults.object(forKey: Key.lipDetection) as? Bool ?? true
        lipCoolingEnabled  = defaults.object(forKey: Key.lipCooling) as? Bool ?? lipLegacy
        lipShutdownEnabled = defaults.object(forKey: Key.lipShutdown) as? Bool ?? lipLegacy
        // Off by default, all of it. These change what the oven does on its
        // own, and nobody should discover them by having the device behave
        // differently than it did yesterday.
        autoOffEnabled      = defaults.object(forKey: Key.autoOff) as? Bool ?? false
        autoOffMinutes      = defaults.object(forKey: Key.autoOffMinutes) as? Int ?? 10
        doseLimitEnabled    = defaults.object(forKey: Key.doseLimit) as? Bool ?? false
        doseLimitDraws      = defaults.object(forKey: Key.doseDraws) as? Int ?? 6
        scheduleEnabled     = defaults.object(forKey: Key.scheduleOn) as? Bool ?? false
        schedule            = Self.read(PaxSchedule.self, from: defaults, forKey: Key.schedule) ?? .suggested
        // History is the exception: it costs nothing, it is local, and a
        // history that only starts once someone thinks to switch it on is a
        // history with a hole where the interesting part was.
        sessionHistoryEnabled = defaults.object(forKey: Key.historyOn) as? Bool ?? true
        profiles            = Self.read([PaxProfile].self, from: defaults, forKey: Key.profiles) ?? PaxProfile.starters
        heaterOptionBit     = defaults.object(forKey: Key.heaterBit) as? Int
        // On by default: the four states carry the palette below, which is
        // what makes the PAX show what it is doing rather than one flat colour.
        perModeLedColors    = defaults.object(forKey: Key.perModeColors) as? Bool ?? true
        // Anything but eight parseable colours is treated as absent rather than
        // patched up: a half-read list would write colours nobody chose.
        let stored = defaults.stringArray(forKey: Key.modeColors) ?? []
        let valid = stored.count == Self.modeSlotCount
            && stored.allSatisfy { LedColor.fromHex($0) != nil }
        // A palette nobody has touched — eight identical colours, which is what
        // builds before this palette existed seeded from the accent colour, or
        // one this app shipped earlier — takes up the current one. A palette
        // that was chosen by hand is left alone.
        let autoSeeded = valid && Set(stored.map { $0.uppercased() }).count == 1
        let upper = stored.map { $0.uppercased() }
        let untouched = autoSeeded || LedColor.supersededStateHexes.contains {
            $0.map { $0.uppercased() } == upper
        }
        let superseded = untouched && defaults.integer(forKey: Key.paletteVersion) < Self.paletteVersion
        modeLedHexes = (valid && !superseded) ? stored : LedColor.cleanStateHexes
        defaults.set(Self.paletteVersion, forKey: Key.paletteVersion)
    }

    /// Four modes, two colours each.
    static let modeSlotCount = PaxColorTheme.modeCount * 2

    /// Bumped when the shipped palette changes, so an install carrying an
    /// auto-seeded one picks the new colours up.
    static let paletteVersion = 3

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

    /// Back to the shipped palette.
    func resetModeColorsToCleanDefaults() {
        modeLedHexes = LedColor.cleanStateHexes
    }

    /// Fills the per-mode colours in from what the device is actually showing,
    /// so switching the toggle on starts from the PAX's own theme rather than
    /// from the shipped palette.
    func seedModeColors(from theme: PaxColorTheme?) {
        guard let theme else {
            modeLedHexes = LedColor.cleanStateHexes
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
