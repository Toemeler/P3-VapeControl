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
    /// A one-line description of what the PAX is doing, for Siri to read back.
    static var statusSummary: (() -> String)?

    /// Degrees the PAX itself accepts. Kept here rather than imported from the
    /// protocol layer, which the extension does not compile.
    static let minCelsius = 180
    static let maxCelsius = 215

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

// MARK: - Lock Screen buttons

/// The Lock Screen card's temperature buttons. A `LiveActivityIntent` is the
/// one kind that runs in the app's process rather than the widget's, which is
/// what makes a Bluetooth write from the Lock Screen possible at all.
@available(iOS 17.0, *)
struct PaxQuickTemperatureIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Set PAX temperature"
    /// Reachable from the Lock Screen card, not something to offer in the
    /// Shortcuts gallery — `SetPaxTemperatureIntent` is the one to use there.
    static var isDiscoverable: Bool = false

    @Parameter(title: "Temperature (°C)", default: 193)
    var celsius: Int

    init() {}
    init(celsius: Int) { self.celsius = celsius }

    @MainActor
    func perform() async throws -> some IntentResult {
        PaxIntentBridge.setTemperature?(PaxIntentBridge.clamp(celsius))
        return .result()
    }
}

/// The presets the Lock Screen card offers, in °C.
enum PaxQuickTemperatures {
    static let all = [180, 193, 204, 215]
}
