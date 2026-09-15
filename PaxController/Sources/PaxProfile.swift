import Foundation

/// A saved way of running the PAX: a temperature, a heating mode and a colour,
/// under a name that means something to the person who made it.
///
/// The three settle together in practice — a temperature for a material, a mode
/// for how hard to push it, a colour so the device says which is which from
/// across the room — and setting them one at a time from three different parts
/// of the app is three taps for one decision.
struct PaxProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var temperatureC: Double
    /// `PaxDynamicMode.rawValue`, or nil to leave the mode alone.
    var modeRaw: UInt8?
    /// `#RRGGBB`, or nil to leave the LEDs alone.
    var ledHex: String?

    init(id: UUID = UUID(), name: String, temperatureC: Double,
         modeRaw: UInt8? = nil, ledHex: String? = nil) {
        self.id = id
        self.name = name
        self.temperatureC = temperatureC
        self.modeRaw = modeRaw
        self.ledHex = ledHex
    }

    /// Somewhere to start rather than an empty list. These are ordinary
    /// temperatures for ordinary purposes, not claims about what anyone should
    /// be doing.
    static let starters: [PaxProfile] = [
        PaxProfile(name: "Flavour", temperatureC: 185, modeRaw: 4, ledHex: "#2EB82E"),
        PaxProfile(name: "Everyday", temperatureC: 199, modeRaw: 0, ledHex: "#FF6A00"),
        PaxProfile(name: "Full send", temperatureC: 215, modeRaw: 1, ledHex: "#E03C00"),
    ]

    var summary: String {
        var parts = [String(format: "%.0f°C", temperatureC)]
        if let raw = modeRaw, let label = Self.modeLabel(raw) { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    /// Named here rather than reaching for `PaxDynamicMode`, so this type stays
    /// usable from anywhere — including targets that do not compile the
    /// protocol layer.
    static func modeLabel(_ raw: UInt8) -> String? {
        switch raw {
        case 0: return "Standard"
        case 1: return "Boost"
        case 2: return "Efficiency"
        case 3: return "Stealth"
        case 4: return "Flavor"
        default: return nil
        }
    }
}

/// A temperature that changes through a session, on the app's terms.
///
/// The device has one of these built in — Efficiency ramps 205 to 235 on a
/// fixed curve — but it is the firmware's curve, it is tied to giving up the
/// set point, and it is measured in time rather than in draws. This one counts
/// draws, which is what a session actually consists of, and writes the set
/// point the ordinary way, so it works in any mode.
struct PaxSchedule: Codable, Equatable {
    struct Step: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        /// Applied once the session has seen at least this many draws.
        var afterDraws: Int
        var temperatureC: Double

        init(id: UUID = UUID(), afterDraws: Int, temperatureC: Double) {
            self.id = id
            self.afterDraws = afterDraws
            self.temperatureC = temperatureC
        }
    }

    var steps: [Step]

    static let suggested = PaxSchedule(steps: [
        Step(afterDraws: 0, temperatureC: 185),
        Step(afterDraws: 3, temperatureC: 199),
        Step(afterDraws: 6, temperatureC: 210),
    ])

    /// The step in force after `draws` draws: the last one whose threshold has
    /// been passed. Steps are sorted here rather than trusted to be, because
    /// the editor lets them be typed in any order.
    func temperature(atDraws draws: Int) -> Double? {
        steps.filter { $0.afterDraws <= draws }
            .max { $0.afterDraws < $1.afterDraws }?
            .temperatureC
    }

    var isUsable: Bool { !steps.isEmpty }

    var summary: String {
        steps.sorted { $0.afterDraws < $1.afterDraws }
            .map { step in
                step.afterDraws == 0
                    ? String(format: "%.0f°", step.temperatureC)
                    : String(format: "%.0f° after %d", step.temperatureC, step.afterDraws)
            }
            .joined(separator: " → ")
    }
}
