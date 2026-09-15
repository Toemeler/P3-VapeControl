import AppIntents
import Foundation

// MARK: - Bridge

/// How an intent reaches the running app.
///
/// This file is compiled into both the app and the Live Activity extension: the
/// extension needs the intent *types* to put a button on the Lock Screen card,
/// but it must never run one — there is no Bluetooth stack in a widget process.
/// It cannot, either. A `LiveActivityIntent` is performed in the app's process,
/// which iOS launches in the background if it is not already running, so by the
/// time `perform()` runs these closures are set. In the extension they stay nil
/// and the calls below do nothing.
@MainActor
enum PaxIntentBridge {
    static var setTemperature: ((Int) -> Void)?
    static var setDynamicMode: ((UInt8) -> Void)?
    /// Switches the oven off, or back on. Nil in the extension, and nil in the
    /// app until a device has had its heater bit measured — which is why the
    /// intent reports what happened rather than assuming it worked.
    static var setOvenEnabled: ((Bool) -> Bool)?
    /// Applies a saved profile by name, returning what it matched.
    static var applyProfile: ((String) -> String?)?
    /// A one-line description of what the PAX is doing, for Siri to read back.
    static var statusSummary: (() -> String)?

    /// Degrees the PAX itself accepts. Kept here rather than imported from the
    /// protocol layer, which the extension does not compile.
    static let minCelsius = 180
    /// Matches the dial. The device reports a higher ladder through
    /// HeaterRanges; this is where the app stops.
    static let maxCelsius = 225

    static func clamp(_ celsius: Int) -> Int {
        min(maxCelsius, max(minCelsius, celsius))
    }
}

// MARK: - Heating mode

@available(iOS 16.0, *)
enum PaxModeChoice: String, AppEnum {
    case standard, boost, efficiency, stealth, flavor

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "PAX heating mode"

    static var caseDisplayRepresentations: [PaxModeChoice: DisplayRepresentation] = [
        .standard:   "Standard",
        .boost:      "Boost",
        .efficiency: "Efficiency",
        .stealth:    "Stealth",
        .flavor:     "Flavor",
    ]

    /// The byte DynamicMode (0x13) carries.
    var wireValue: UInt8 {
        switch self {
        case .standard:   return 0x00
        case .boost:      return 0x01
        case .efficiency: return 0x02
        case .stealth:    return 0x03
        case .flavor:     return 0x04
        }
    }
}

// MARK: - Intents

@available(iOS 16.0, *)
struct SetPaxTemperatureIntent: AppIntent {
    static var title: LocalizedStringResource = "Set PAX temperature"
    static var description = IntentDescription("Sets the PAX's target temperature.")
    /// The work is a Bluetooth write that finishes in milliseconds; there is
    /// nothing for the user to look at afterwards.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Temperature (°C)", default: 193)
    var celsius: Int

    init() {}
    init(celsius: Int) { self.celsius = celsius }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = PaxIntentBridge.clamp(celsius)
        PaxIntentBridge.setTemperature?(target)
        return .result(dialog: IntentDialog(stringLiteral: "Set the PAX to \(target)°C"))
    }
}

@available(iOS 16.0, *)
struct SetPaxModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set PAX heating mode"
    static var description = IntentDescription("Switches the PAX between its heating profiles.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Mode", default: .standard)
    var mode: PaxModeChoice

    init() {}
    init(mode: PaxModeChoice) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PaxIntentBridge.setDynamicMode?(mode.wireValue)
        let name = PaxModeChoice.caseDisplayRepresentations[mode]?.title ?? "\(mode.rawValue)"
        return .result(dialog: IntentDialog(stringLiteral: "PAX set to \(name)"))
    }
}

@available(iOS 16.0, *)
struct SetPaxOvenIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn the PAX oven on or off"
    static var description = IntentDescription(
        "Switches the PAX's heater. Needs the heater bit to have been measured on the device first, in Settings.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "On", default: false)
    var on: Bool

    init() {}
    init(on: Bool) { self.on = on }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = PaxIntentBridge.setOvenEnabled else {
            return .result(dialog: "The PAX is not connected")
        }
        let worked = handler(on)
        guard worked else {
            return .result(dialog: "Run \u{201C}Find the heater bit\u{201D} in the app's settings first — without it, switching the oven is a guess")
        }
        return .result(dialog: on ? "PAX oven on" : "PAX oven off")
    }
}

@available(iOS 16.0, *)
struct ApplyPaxProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply a PAX profile"
    static var description = IntentDescription("Sets the temperature, mode and colour from one of your saved profiles.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Profile name")
    var name: String

    init() {}
    init(name: String) { self.name = name }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let applied = PaxIntentBridge.applyProfile?(name) else {
            return .result(dialog: IntentDialog(stringLiteral: "No profile called \(name)"))
        }
        return .result(dialog: IntentDialog(stringLiteral: "PAX set to \(applied)"))
    }
}

@available(iOS 16.0, *)
struct PaxStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check the PAX"
    static var description = IntentDescription("Reports temperature, battery and what the PAX is doing.")
    static var openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = PaxIntentBridge.statusSummary?() ?? "The PAX is not connected"
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}
