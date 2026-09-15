import Foundation

/// The PAX LED colour theme (attribute 0x14).
///
/// Layout, matching the official app: `[mode count][mode × count]`, where each
/// mode is 8 bytes — `color1 RGB`, `color2 RGB`, `animation`, `frequency`. The
/// four modes are indexed by `Mode` below. With the type byte in front, a full
/// theme packet is 34 bytes of plaintext.
///
/// The count byte matters: a device told it has 255 modes will read far past
/// the end of the packet, which is what a malformed 3-byte write did here.
struct PaxColorTheme: Equatable {
    enum Mode: Int, CaseIterable {
        case startup = 0, heating = 1, regulating = 2, standby = 3

        /// What the PAX is doing while this mode's colours are showing.
        var label: String {
            switch self {
            case .startup:    return "Startup"
            case .heating:    return "Heating"
            case .regulating: return "At temperature"
            case .standby:    return "Standby"
            }
        }

        /// How the PAX moves between the state's two colours. Values seen in
        /// the official app's own themes: 0, 1 and 2, with frequencies from
        /// about 5 to 27. A steady state wants a slow fade; the warm-up wants
        /// none, since the app drives that colour from the temperature.
        var defaultAnimation: UInt8 {
            switch self {
            case .startup:    return 1
            case .heating:    return 0
            case .regulating: return 2
            case .standby:    return 1
            }
        }

        var defaultFrequency: UInt8 {
            switch self {
            case .startup:    return 12
            case .heating:    return 15
            case .regulating: return 9
            case .standby:    return 6
            }
        }

        var detail: String {
            switch self {
            case .startup:    return "The moment it wakes up"
            case .heating:    return "Warming up to the set point"
            case .regulating: return "Holding the set point, ready to draw"
            case .standby:    return "Idle, cooling down"
            }
        }
    }

    struct ModeColors: Equatable {
        var color1: (r: UInt8, g: UInt8, b: UInt8)
        var color2: (r: UInt8, g: UInt8, b: UInt8)
        /// Semantics undocumented; preserved from the device rather than invented.
        var animation: UInt8
        var frequency: UInt8

        static func == (lhs: ModeColors, rhs: ModeColors) -> Bool {
            lhs.color1 == rhs.color1 && lhs.color2 == rhs.color2
                && lhs.animation == rhs.animation && lhs.frequency == rhs.frequency
        }

        var bytes: Data {
            Data([color1.r, color1.g, color1.b, color2.r, color2.g, color2.b, animation, frequency])
        }
    }

    var modes: [ModeColors]

    static let modeCount = Mode.allCases.count
    static let modeSize = 8
    /// Mode count byte + the modes themselves.
    static let payloadSize = 1 + modeCount * modeSize

    /// Parses a reported theme. `payload` excludes the message type byte.
    init?(payload: Data) {
        let bytes = Data(payload)
        guard let declared = bytes.first else { return nil }
        let count = Int(declared)
        // A count that does not fit the packet means this is not a theme we
        // understand — refuse rather than read past the end.
        guard count > 0, bytes.count >= 1 + count * Self.modeSize else { return nil }

        modes = (0..<count).map { i in
            let start = 1 + i * Self.modeSize
            let m = Array(bytes[start..<(start + Self.modeSize)])
            return ModeColors(color1: (m[0], m[1], m[2]),
                              color2: (m[3], m[4], m[5]),
                              animation: m[6],
                              frequency: m[7])
        }
    }

    private init(modes: [ModeColors]) { self.modes = modes }

    /// One colour across every mode, paired with white so the PAX has
    /// something to move to — the standard look is the chosen colour and
    /// white. Animation and frequency come from this app's own table rather
    /// than the device's, which is usually all zeroes and shows nothing.
    static func solid(_ color: LedColor, basedOn template: PaxColorTheme?) -> PaxColorTheme {
        let second = LedColor.pairedWith
        let modes = (0..<modeCount).map { i -> ModeColors in
            let mode = Mode(rawValue: i)
            return ModeColors(color1: (color.red, color.green, color.blue),
                              color2: (second.red, second.green, second.blue),
                              animation: mode?.defaultAnimation ?? 0,
                              frequency: mode?.defaultFrequency ?? 0)
        }
        return PaxColorTheme(modes: modes)
    }

    /// Each mode given its own pair of colours, again keeping the animation
    /// and frequency bytes the device reported. `pairs` is indexed by `Mode`;
    /// a short array falls back to `fallback` for the modes it does not cover.
    ///
    /// Unlike `solid`, this takes the app's own animation and frequency for
    /// each state rather than the device's: someone setting four states by
    /// hand is styling the thing, and the values it shipped with are usually
    /// all zeroes anyway.
    static func perMode(_ pairs: [(LedColor, LedColor)],
                        fallback: LedColor,
                        basedOn template: PaxColorTheme?) -> PaxColorTheme {
        let modes = (0..<modeCount).map { i -> ModeColors in
            let mode = Mode(rawValue: i)
            let pair = pairs.indices.contains(i) ? pairs[i] : (fallback, fallback)
            return ModeColors(color1: (pair.0.red, pair.0.green, pair.0.blue),
                              color2: (pair.1.red, pair.1.green, pair.1.blue),
                              animation: mode?.defaultAnimation ?? 0,
                              frequency: mode?.defaultFrequency ?? 0)
        }
        return PaxColorTheme(modes: modes)
    }

    /// Replaces one state's colours, leaving its animation and frequency and
    /// every other state alone. The warm-up ramp writes through this.
    mutating func setColors(_ mode: Mode, color1: LedColor, color2: LedColor) {
        guard modes.indices.contains(mode.rawValue) else { return }
        modes[mode.rawValue].color1 = (color1.red, color1.green, color1.blue)
        modes[mode.rawValue].color2 = (color2.red, color2.green, color2.blue)
    }

    /// Payload for a write, excluding the message type byte.
    var payload: Data {
        var out = Data([UInt8(modes.count)])
        for mode in modes { out.append(mode.bytes) }
        return out
    }

    var summary: String {
        modes.enumerated().map { i, m in
            let name = Mode(rawValue: i).map { "\($0)" } ?? "mode\(i)"
            return String(format: "%@ %02X%02X%02X/%02X%02X%02X a=%02X f=%02X",
                          name, m.color1.r, m.color1.g, m.color1.b,
                          m.color2.r, m.color2.g, m.color2.b, m.animation, m.frequency)
        }.joined(separator: ", ")
    }
}
