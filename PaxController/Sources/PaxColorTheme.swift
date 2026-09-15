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

    /// Every mode set to one colour, keeping each mode's animation and
    /// frequency from `template` when the device has reported them.
    static func solid(_ color: LedColor, basedOn template: PaxColorTheme?) -> PaxColorTheme {
        let modes = (0..<modeCount).map { i -> ModeColors in
            let existing = template?.modes.indices.contains(i) == true ? template?.modes[i] : nil
            return ModeColors(color1: (color.red, color.green, color.blue),
                              color2: (color.red, color.green, color.blue),
                              animation: existing?.animation ?? 0,
                              frequency: existing?.frequency ?? 0)
        }
        return PaxColorTheme(modes: modes)
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
