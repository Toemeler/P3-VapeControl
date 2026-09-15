import Foundation
import CryptoKit
import CoreBluetooth

// MARK: - BLE UUIDs
// Source: https://blraaz.me/reverse-engineering/2021/08/29/bluetooth-reverse-engineering.html
// and https://github.com/tristanseifert/pax-controller-test

enum PaxUUIDs {
    static let serviceUUID        = CBUUID(string: "8E320200-64D2-11E6-BDF4-0800200C9A66")
    static let readCharUUID       = CBUUID(string: "8E320201-64D2-11E6-BDF4-0800200C9A66")
    static let writeCharUUID      = CBUUID(string: "8E320202-64D2-11E6-BDF4-0800200C9A66")
    static let notifyCharUUID     = CBUUID(string: "8E320203-64D2-11E6-BDF4-0800200C9A66")

    static let deviceInfoService  = CBUUID(string: "180A")
    /// Generic Access, and the Device Name characteristic inside it. This is
    /// the name iOS shows and the scan reports — and, on firmware that allows
    /// writing it, the one a rename has to change to stick.
    static let genericAccessService = CBUUID(string: "1800")
    static let deviceNameChar       = CBUUID(string: "2A00")

    /// The session log lives on a service of its own, which this app never
    /// knew about: the official PAX web app subscribes to LogNotify, asks for
    /// events by writing LogSyncRequest (0x12) on the ordinary write
    /// characteristic, and then reads them out of LogRead until it comes back
    /// empty. UUIDs taken from that app's own bundle.
    static let logService           = CBUUID(string: "64F50300-EFDC-11E6-BC64-92361F002671")
    static let logReadChar          = CBUUID(string: "64F50301-EFDC-11E6-BC64-92361F002671")
    static let logNotifyChar        = CBUUID(string: "64F50302-EFDC-11E6-BC64-92361F002671")
    static let serialNumberChar   = CBUUID(string: "2A25")
    static let modelNumberChar    = CBUUID(string: "2A24")
    static let firmwareRevChar    = CBUUID(string: "2A26")
    static let manufacturerChar   = CBUUID(string: "2A29")
}

// MARK: - Message Types
// All message types discovered from reverse engineering the Android app.
// Reference: https://blraaz.me/reverse-engineering/2021/08/29/bluetooth-reverse-engineering.html

enum PaxMessageType: UInt8 {
    case actualTemp         = 0x01  // Current oven temp; 16-bit LE, °C × 10
    case heaterSetPoint     = 0x02  // Target temp; 16-bit LE, °C × 10
    case battery            = 0x03  // State of charge; 1 byte, 0–100
    case usage              = 0x04
    case usageLimit         = 0x05
    case lockStatus         = 0x06  // 1 byte; 0 = unlocked, 1 = locked
    case chargeStatus       = 0x07
    case podInserted        = 0x08  // Era only
    case time               = 0x09
    case displayName        = 0x0A  // 1 byte length + UTF-8 bytes
    case replay             = 0x0D
    case gameMode           = 0x0F
    case heaterRanges       = 0x11
    case logSyncRequest     = 0x12
    case dynamicMode        = 0x13  // 1 byte dynamic heating mode (Pax 3)
    case colorTheme         = 0x14  // Mode count + 4 × 8-byte LED modes
    case brightness         = 0x15  // 1 byte, 0…128
    case hapticMode         = 0x17  // Byte 0 is amplitude, 0…128
    case supportedAttribs   = 0x18  // 64-bit bitfield of supported message types
    case heatingParams      = 0x19
    case uiMode             = 0x1B
    case shellColor         = 0x1C  // 1 byte: the casing's colour, read only
    case lowSoCMode         = 0x1E
    case currentTargetTemp  = 0x1F  // Current PID target; 16-bit LE, °C × 10 (Pax 3)
    case heatingState       = 0x20  // Current oven state byte (Pax 3)
    case sessionControl     = 0x24
    case haptics            = 0x28
    case logRequest         = 0x29
    case podData            = 0x2A
    case encryptionExchange = 0x31
    case encryptionPacket   = 0x32
    case bleDisData         = 0x34
    case findMyPax          = 0x36
    case statusUpdate       = 0xFE  // Request status; 64-bit LE bitfield of desired attrs

    /// 0…128 on the wire for brightness and haptic amplitude.
    static let amplitudeMax: Double = 128

    /// How many payload bytes an attribute actually carries, where that is
    /// known. Everything after this is uninitialised buffer, so a value read
    /// while it was changing — a temperature, the clock — has to be cut here
    /// rather than reported with its noise attached.
    var payloadLength: Int? {
        switch self {
        case .actualTemp, .heaterSetPoint, .currentTargetTemp:  return 2
        case .battery, .lockStatus, .chargeStatus, .gameMode,
             .dynamicMode, .brightness, .uiMode, .shellColor,
             .lowSoCMode, .heatingState, .podInserted:          return 1
        case .time:                                             return 4
        case .heaterRanges:                                     return 12
        case .colorTheme:                                       return PaxColorTheme.payloadSize
        case .hapticMode:                                       return 6
        case .heatingParams:                                    return PaxHeatingParams.payloadSize
        case .supportedAttribs:                                 return 8
        default:                                                return nil
        }
    }
}

// MARK: - Heating State
/// Values taken from the official PAX web app's own `HeatingStates` enum.
/// The table this app shipped with was wrong at every position — it read 0 as
/// "Off", which is why a PAX warming up said Off, and 5 as "Cooling", which is
/// why one sitting on the charger said Cooling.
enum PaxHeatingState: UInt8, CustomStringConvertible {
    case heating      = 0x00
    case ready        = 0x01
    /// Lip detection: the device boosts while you draw.
    case boosting     = 0x02
    /// Lip detection: the draw has ended and it is settling back.
    case cooling      = 0x03
    /// Dropped to standby because the device has not moved.
    case standby      = 0x04
    case ovenOff      = 0x05
    /// Temperature being chosen by holding the button on the device.
    case tempSetMode  = 0x06

    var description: String {
        switch self {
        case .heating:      return "Heating"
        case .ready:        return "Ready"
        case .boosting:     return "Inhaling"
        case .cooling:      return "Cooling"
        case .standby:      return "Standby"
        case .ovenOff:      return "Oven off"
        case .tempSetMode:  return "Setting temperature"
        }
    }

    /// True while the oven is actually working towards the set point.
    var isWarmingUp: Bool { self == .heating }
}

// MARK: - Dynamic Mode (PAX 3 heating profile)
enum PaxDynamicMode: UInt8, CaseIterable, Identifiable {
    case standard   = 0x00
    case boost      = 0x01
    case efficiency = 0x02
    case stealth    = 0x03
    case flavor     = 0x04

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .standard:   return "Standard"
        case .boost:      return "Boost"
        case .efficiency: return "Efficiency"
        case .stealth:    return "Stealth"
        case .flavor:     return "Flavor"
        }
    }

    var icon: String {
        switch self {
        case .standard:   return "dial.medium"
        case .boost:      return "flame.fill"
        case .efficiency: return "leaf.fill"
        case .stealth:    return "moon.fill"
        case .flavor:     return "sparkles"
        }
    }
}

// MARK: - Preset temperatures (°C)
enum PaxPresetTemp: Int, CaseIterable, Identifiable {
    case t180 = 180
    case t193 = 193
    case t204 = 204
    case t215 = 215

    var id: Int { rawValue }
    var label: String { "\(rawValue)°C" }

    var encodedValue: UInt16 { UInt16(rawValue * 10) }
}

// MARK: - Packet Layer
// Packets are AES-128 OFB encrypted.
// Plaintext packet: [messageType: 1 byte][payload: variable][padding to 16 bytes]
// Wire format: [ciphertext: 16 bytes][IV: 16 bytes] — IV is last 16 bytes of 32-byte packet.
// Key derivation: AES-128-ECB(serialNumber + serialNumber encoded as UTF-8, sharedKey)
// Shared key: F7C866C38F78753086293BD57DD32540 (from public reverse engineering research)

struct PaxCrypto {
    // Shared key sourced from public reverse engineering documentation.
    // This is not a secret — it is hardcoded in every PAX mobile app and
    // documented in multiple public security research posts.
    private static let sharedKeyBytes: [UInt8] = [
        0xF7, 0xC8, 0x66, 0xC3, 0x8F, 0x78, 0x75, 0x30,
        0x86, 0x29, 0x3B, 0xD5, 0x7D, 0xD3, 0x25, 0x40
    ]

    static func deriveKey(serialNumber: String) throws -> SymmetricKey {
        let serial = serialNumber.uppercased()
        let doubled = serial + serial
        guard let raw = doubled.data(using: .utf8) else {
            throw PaxError.keyDerivationFailed("Serial '\(serialNumber)' is not valid UTF-8")
        }
        var serialData = Data(repeating: 0, count: 16)
        serialData.replaceSubrange(0..<min(raw.count, 16), with: raw.prefix(16))
        let sharedKey = SymmetricKey(data: Data(sharedKeyBytes))

        // AES-128-ECB: encrypt serialData with sharedKey
        let derived = try aesECBEncrypt(data: serialData, key: sharedKey)
        let sessionKey = SymmetricKey(data: Data(derived.prefix(16)))
        let keyHex = derived.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("[PAX] Session key: [%@]", keyHex)
        return sessionKey
    }

    static func encrypt(plaintext: Data, key: SymmetricKey) throws -> Data {
        // Pad up to a whole number of 16-byte blocks. Not a fixed single block:
        // ColorTheme carries 34 bytes (type + mode count + 4 modes × 8), and
        // truncating that to 16 would hand the device a mode count with no
        // modes behind it.
        let blockCount = max(1, (plaintext.count + 15) / 16)
        var block = Data(count: blockCount * 16)
        block.replaceSubrange(0..<plaintext.count, with: plaintext)

        // Generate random 16-byte IV
        var ivBytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, 16, &ivBytes)
        guard result == errSecSuccess else { throw PaxError.encryptionFailed("SecRandomCopyBytes failed") }
        let iv = Data(ivBytes)

        let ciphertext = try aesOFBCrypt(data: block, key: key, iv: iv)
        return ciphertext + iv
    }

    static func decrypt(packet: Data, key: SymmetricKey) throws -> (plaintext: Data, iv: Data, ciphertext: Data) {
        guard packet.count >= 32, packet.count % 16 == 0 else {
            throw PaxError.decryptionFailed("Expected a 16-byte multiple of at least 32, got \(packet.count)")
        }
        // PAX packet layout: [ciphertext: n × 16 bytes][IV: 16 bytes]. A longer
        // read is one packet with a longer plaintext, NOT several 32-byte
        // packets concatenated — splitting it that way decrypts the second half
        // against the wrong IV and yields garbage. Confirmed by decoding real
        // 64-byte reads, which carry ColorTheme and only decode cleanly this way.
        let ciphertext = Data(packet.dropLast(16))
        let iv         = Data(packet.suffix(16))
        // Compute keystream = AES_ECB(key, iv) for logging
        let keystream  = (try? aesECBEncrypt(data: iv, key: key).prefix(16)) ?? Data()
        let plaintext  = try aesOFBCrypt(data: ciphertext, key: key, iv: iv)
        let ivHex  = iv.map        { String(format:"%02X",$0) }.joined(separator:" ")
        let ksHex  = keystream.map { String(format:"%02X",$0) }.joined(separator:" ")
        let ctHex  = ciphertext.map{ String(format:"%02X",$0) }.joined(separator:" ")
        let ptHex  = plaintext.map { String(format:"%02X",$0) }.joined(separator:" ")
        NSLog("[PAX] DEC iv=[%@] ks=[%@] ct=[%@] pt=[%@]", ivHex, ksHex, ctHex, ptHex)
        return (plaintext, iv, ciphertext)
    }

    // MARK: - CommonCrypto wrappers

    private static func aesECBEncrypt(data: Data, key: SymmetricKey) throws -> Data {
        // AES-ECB(key, block) == AES-CBC(key, iv=zeros, block) for a single 16-byte block.
        // Use CBC mode which is reliably implemented in CommonCrypto unlike ECB.
        guard data.count == kCCBlockSizeAES128 else {
            throw PaxError.keyDerivationFailed("ECB input must be exactly 16 bytes, got \(data.count)")
        }
        let keyBytes  = key.withUnsafeBytes { bytes in Array(bytes.bindMemory(to: UInt8.self)) }
        let zeroIV    = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let inBytes   = Array(data)   // copy to avoid overlapping-access error
        // CBC with zero IV + PKCS7: output is 32 bytes (data block + padding block); take first 16.
        var out       = Data(count: kCCBlockSizeAES128 * 2)
        let outCount  = out.count
        var outLen    = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),   // CBC + PKCS7, no ECB flag
                keyBytes, keyBytes.count,
                zeroIV,                              // zero IV → CBC first block == ECB
                inBytes, inBytes.count,
                outPtr.baseAddress!, outCount,
                &outLen
            )
        }
        guard status == kCCSuccess else { throw PaxError.keyDerivationFailed("CCCrypt CBC(ECB) status \(status)") }
        return Data(out.prefix(kCCBlockSizeAES128))     // discard PKCS7 padding block
    }

    private static func aesOFBCrypt(data: Data, key: SymmetricKey, iv: Data) throws -> Data {
        // Manual OFB: keystream = AES-ECB(IV), AES-ECB(AES-ECB(IV)), ...
        // XOR each keystream block with the corresponding data block.
        // This avoids CommonCrypto's kCCModeOFB which is unreliable on iOS.
        var keystream = Data(iv)
        var result    = Data(capacity: data.count)
        var offset    = 0
        while offset < data.count {
            keystream = Data(try aesECBEncrypt(data: keystream, key: key).prefix(kCCBlockSizeAES128))
            let blockEnd = min(offset + kCCBlockSizeAES128, data.count)
            for i in offset..<blockEnd {
                result.append(data[i] ^ keystream[i - offset])
            }
            offset += kCCBlockSizeAES128
        }
        return result
    }
}

// MARK: - Packet Builder / Parser

struct PaxPacket {
    let type: PaxMessageType
    let payload: Data

    init(type: PaxMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    func encode(key: SymmetricKey) throws -> Data {
        // PaxCrypto.encrypt pads to whole blocks, so a longer payload such as
        // ColorTheme's survives intact.
        try PaxCrypto.encrypt(plaintext: Data([type.rawValue]) + payload, key: key)
    }

    static func decode(data: Data, key: SymmetricKey) throws -> (packet: PaxPacket, plaintext: Data) {
        let result = try PaxCrypto.decrypt(packet: data, key: key)
        let plaintext = Data(result.plaintext)
        guard !plaintext.isEmpty else {
            throw PaxError.decryptionFailed("Decrypted to empty plaintext")
        }
        guard let type = PaxMessageType(rawValue: plaintext[0]) else {
            throw PaxError.unknownMessageType(plaintext[0], plaintext: plaintext)
        }
        let packet = PaxPacket(type: type, payload: Data(plaintext.dropFirst()))
        return (packet, plaintext)
    }
}

// MARK: - Status Request Builder

extension PaxPacket {
    static func statusRequest(attributes: [PaxMessageType]) -> PaxPacket {
        statusRequest(rawAttributes: attributes.map(\.rawValue))
    }

    /// The same request by attribute number, so an attribute this app has no
    /// name for — 0x1A, which is not named even in the official app — can
    /// still be asked for.
    static func statusRequest(rawAttributes: [UInt8]) -> PaxPacket {
        var bitfield: UInt64 = 0
        for attr in rawAttributes {
            let bit = UInt64(attr)
            guard bit < 64 else { continue }
            bitfield |= (1 << bit)
        }
        var le = bitfield.littleEndian
        let payload = withUnsafeBytes(of: &le) { Data($0) }
        return PaxPacket(type: .statusUpdate, payload: payload)
    }

    static func setTemperature(_ celsius: Int) -> PaxPacket {
        var encoded = UInt16(celsius * 10).littleEndian
        let payload = withUnsafeBytes(of: &encoded) { Data($0) }
        return PaxPacket(type: .heaterSetPoint, payload: payload)
    }

    static func setDynamicMode(_ mode: PaxDynamicMode) -> PaxPacket {
        PaxPacket(type: .dynamicMode, payload: Data([mode.rawValue]))
    }

    /// Writes the heating parameters wholesale (0x19). There is no way to
    /// change one field: the attribute is written as a block, so the caller
    /// has to start from a complete set — what the device reported, or the
    /// vendor preset for the mode it is in — and change what it means to.
    static func setHeatingParams(_ params: PaxHeatingParams) -> PaxPacket {
        PaxPacket(type: .heatingParams, payload: params.payload)
    }

    /// Writes an LED color attribute. Neither ColorTheme (0x14) nor ShellColor
    /// (0x1C) has a publicly documented payload, so the caller decides both
    /// which attribute to target and what shape the payload takes, based on
    /// what the device reported it supports and what its current value looks
    /// like — see PaxDeviceViewModel's capability discovery.
    static func setLedColor(attribute: PaxMessageType, payload: Data) -> PaxPacket {
        PaxPacket(type: attribute, payload: payload)
    }

    /// Renames the device. Same shape the PAX reports it in: one length byte,
    /// then UTF-8. The name is truncated on a character boundary so a
    /// multi-byte character can never be cut in half, and the length byte
    /// always matches what follows it — a mismatch there is the same class of
    /// bug as ColorTheme's mode count.
    /// Asks the device for log events from `timestamp` onwards, skipping the
    /// first `offset` events that share it. Layout from the official app:
    /// a little-endian 32-bit timestamp then a single byte.
    static func logSyncRequest(timestamp: UInt32, offset: UInt8) -> PaxPacket {
        var value = timestamp.littleEndian
        let payload = withUnsafeBytes(of: &value) { Data($0) } + Data([offset])
        return PaxPacket(type: .logSyncRequest, payload: payload)
    }

    static func setDisplayName(_ name: String) -> PaxPacket? {
        var bytes = Data(name.utf8)
        if bytes.count > maxDisplayNameBytes {
            var truncated = name
            while Data(truncated.utf8).count > maxDisplayNameBytes, !truncated.isEmpty {
                truncated.removeLast()
            }
            bytes = Data(truncated.utf8)
        }
        guard !bytes.isEmpty else { return nil }
        return PaxPacket(type: .displayName, payload: Data([UInt8(bytes.count)]) + bytes)
    }

    /// The device reports its name inside a 15-byte payload, so a name plus its
    /// length byte has to fit that.
    static let maxDisplayNameBytes = 14
}

/// One entry in the PAX's own session log: eight bytes, as the official app
/// parses them — a 24-bit value, a type code, then a 32-bit timestamp.
struct PaxLogEvent {
    let value: UInt32
    let typeCode: UInt8
    let time: UInt32

    static let size = 8

    init?(_ bytes: Data) {
        guard bytes.count >= Self.size else { return nil }
        let b = Array(bytes.prefix(Self.size))
        value = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16)
        typeCode = b[3]
        time = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
    }

    var description: String {
        String(format: "t=%u type=0x%02X value=%u", time, typeCode, value)
    }
}

// MARK: - Parser helpers

extension PaxPacket {
    var temperatureCelsius: Double? {
        guard payload.count >= 2 else { return nil }
        let raw = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        let celsius = Double(raw) / 10.0
        guard celsius >= 0, celsius <= 300 else { return nil }
        return celsius
    }

    var batteryLevel: Int? {
        guard payload.count >= 1 else { return nil }
        return Int(payload[0])
    }

    var heatingState: PaxHeatingState? {
        guard payload.count >= 1 else { return nil }
        return PaxHeatingState(rawValue: payload[0])
    }

    var lockState: Bool? {
        guard payload.count >= 1 else { return nil }
        return payload[0] != 0
    }

    var dynamicMode: PaxDynamicMode? {
        guard payload.count >= 1 else { return nil }
        return PaxDynamicMode(rawValue: payload[0])
    }

    var heatingParams: PaxHeatingParams? {
        PaxHeatingParams(payload: payload)
    }

    /// SupportedAttributes (0x18): 64-bit LE bitfield, bit N set = the device
    /// supports attribute N. Asking the device what it can do beats guessing.
    var supportedAttributes: Set<UInt8> {
        guard payload.count >= 8 else { return [] }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(payload[i]) << (8 * i) }
        return Set((0..<64).compactMap { bits & (1 << UInt64($0)) != 0 ? UInt8($0) : nil })
    }
}

// MARK: - Errors

enum PaxError: Error, LocalizedError {
    case keyDerivationFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    /// Carries the plaintext as well as the type byte: an attribute this app
    /// has no name for is exactly the one worth looking at.
    case unknownMessageType(UInt8, plaintext: Data)
    case notConnected
    case missingCharacteristic(String)

    var errorDescription: String? {
        switch self {
        case .keyDerivationFailed(let s):   return "Key derivation failed: \(s)"
        case .encryptionFailed(let s):      return "Encryption failed: \(s)"
        case .decryptionFailed(let s):      return "Decryption failed: \(s)"
        case .unknownMessageType(let t, _): return "Unknown message type: 0x\(String(t, radix: 16))"
        case .notConnected:                 return "Not connected to device"
        case .missingCharacteristic(let s): return "Missing characteristic: \(s)"
        }
    }
}

// MARK: - HeatingParams (0x19)

/// What a PAX 3's Dynamic Modes actually are.
///
/// Layout and values taken from the official PAX web app's own serialiser: a
/// 22-byte payload of eleven little-endian 16-bit fields, the last of which is
/// a bitfield of feature switches. Picking a mode in that app writes one of the
/// five presets below — the mode byte (0x13) is a label, this is the substance.
///
/// This firmware advertises the attribute and never answers it, so a write here
/// cannot be read back. The values are the vendor's rather than invented, which
/// is the best position available short of the device confirming.
struct PaxHeatingParams: Equatable {
    struct Options: OptionSet {
        let rawValue: UInt16

        /// Raise the temperature while a draw is detected.
        static let boost             = Options(rawValue: 1 << 0)
        /// Honour the set point. Efficiency turns this off and ramps instead.
        static let customTemperature = Options(rawValue: 1 << 1)
        /// Whether the oven heats at all.
        static let heater            = Options(rawValue: 1 << 2)
        /// Cool down when no lip is detected.
        static let noLipCooling      = Options(rawValue: 1 << 3)
        /// Switch off when no lip is detected.
        static let noLipShutdown     = Options(rawValue: 1 << 4)
        static let rampContinue      = Options(rawValue: 1 << 5)
        static let ramp              = Options(rawValue: 1 << 6)
        /// Drop to standby when the device stops moving. Motion, not lip.
        static let standby           = Options(rawValue: 1 << 7)

        /// Everything the lip sensor drives: the boost on a draw, and the
        /// cooling and shutdown that follow when it stops detecting one.
        static let lipDetection: Options = [.boost, .noLipCooling, .noLipShutdown]

        /// What the official app calls each bit. The names are its own; this
        /// PAX 3 plainly does not agree about all of them, so the probe reports
        /// by bit number with the name only as a label.
        static func name(ofBit bit: Int) -> String {
            switch bit {
            case 0: return "boost"
            case 1: return "customTemperature"
            case 2: return "heater"
            case 3: return "noLipCooling"
            case 4: return "noLipShutdown"
            case 5: return "rampContinue"
            case 6: return "ramp"
            case 7: return "standby"
            default: return "bit \(bit)"
            }
        }
    }

    var standbyTemperature: UInt16
    var noMotionToStandbyTime: UInt16
    var noLipCooldownTemperatureChange: UInt16
    var noLipCooldownStart: UInt16
    var noLipCooldownRate: UInt16
    var noLipPowerOffTime: UInt16
    var boostTemperatureChange: UInt16
    var rampTargetTemperature: UInt16
    var rampStartingTemperature: UInt16
    var rampRate: UInt16
    var options: Options

    static let payloadSize = 22

    /// The field order the official app writes, which is not the alphabetical
    /// order its own source declares them in.
    var payload: Data {
        var out = Data()
        for value in [standbyTemperature, noMotionToStandbyTime,
                      noLipCooldownTemperatureChange, noLipCooldownStart,
                      noLipCooldownRate, noLipPowerOffTime,
                      boostTemperatureChange, rampTargetTemperature,
                      rampStartingTemperature, rampRate, options.rawValue] {
            var le = value.littleEndian
            out.append(withUnsafeBytes(of: &le) { Data($0) })
        }
        return out
    }

    init?(payload: Data) {
        guard payload.count >= Self.payloadSize else { return nil }
        let bytes = Array(payload.prefix(Self.payloadSize))
        func word(_ index: Int) -> UInt16 {
            UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
        }
        standbyTemperature = word(0)
        noMotionToStandbyTime = word(1)
        noLipCooldownTemperatureChange = word(2)
        noLipCooldownStart = word(3)
        noLipCooldownRate = word(4)
        noLipPowerOffTime = word(5)
        boostTemperatureChange = word(6)
        rampTargetTemperature = word(7)
        rampStartingTemperature = word(8)
        rampRate = word(9)
        options = Options(rawValue: word(10))
    }

    private init(standbyTemperature: UInt16, noMotionToStandbyTime: UInt16,
                 noLipCooldownTemperatureChange: UInt16, noLipCooldownStart: UInt16,
                 noLipCooldownRate: UInt16, noLipPowerOffTime: UInt16,
                 boostTemperatureChange: UInt16, rampTargetTemperature: UInt16,
                 rampStartingTemperature: UInt16, rampRate: UInt16, options: Options) {
        self.standbyTemperature = standbyTemperature
        self.noMotionToStandbyTime = noMotionToStandbyTime
        self.noLipCooldownTemperatureChange = noLipCooldownTemperatureChange
        self.noLipCooldownStart = noLipCooldownStart
        self.noLipCooldownRate = noLipCooldownRate
        self.noLipPowerOffTime = noLipPowerOffTime
        self.boostTemperatureChange = boostTemperatureChange
        self.rampTargetTemperature = rampTargetTemperature
        self.rampStartingTemperature = rampStartingTemperature
        self.rampRate = rampRate
        self.options = options
    }

    /// The five presets the official app ships, verbatim. Temperatures are
    /// °C × 10 and times are seconds, as everywhere else on this bus.
    static func stock(for mode: PaxDynamicMode) -> PaxHeatingParams {
        switch mode {
        case .standard:
            return PaxHeatingParams(standbyTemperature: 1600, noMotionToStandbyTime: 30,
                                    noLipCooldownTemperatureChange: 150, noLipCooldownStart: 20,
                                    noLipCooldownRate: 30, noLipPowerOffTime: 180,
                                    boostTemperatureChange: 39, rampTargetTemperature: 2300,
                                    rampStartingTemperature: 1990, rampRate: 20,
                                    options: [.boost, .customTemperature, .heater,
                                              .noLipCooling, .noLipShutdown, .standby])
        case .boost:
            return PaxHeatingParams(standbyTemperature: 1750, noMotionToStandbyTime: 60,
                                    noLipCooldownTemperatureChange: 70, noLipCooldownStart: 30,
                                    noLipCooldownRate: 20, noLipPowerOffTime: 180,
                                    boostTemperatureChange: 112, rampTargetTemperature: 2300,
                                    rampStartingTemperature: 1990, rampRate: 20,
                                    options: [.boost, .customTemperature, .heater,
                                              .noLipCooling, .noLipShutdown, .standby])
        case .efficiency:
            // The one mode that gives up the set point: it ramps 205 to 235
            // through the session instead, which is why customTemperature is off.
            return PaxHeatingParams(standbyTemperature: 1600, noMotionToStandbyTime: 30,
                                    noLipCooldownTemperatureChange: 150, noLipCooldownStart: 20,
                                    noLipCooldownRate: 30, noLipPowerOffTime: 180,
                                    boostTemperatureChange: 39, rampTargetTemperature: 2350,
                                    rampStartingTemperature: 2050, rampRate: 20,
                                    options: [.boost, .heater, .noLipCooling,
                                              .noLipShutdown, .ramp, .standby])
        case .stealth:
            return PaxHeatingParams(standbyTemperature: 1200, noMotionToStandbyTime: 15,
                                    noLipCooldownTemperatureChange: 300, noLipCooldownStart: 9,
                                    noLipCooldownRate: 100, noLipPowerOffTime: 180,
                                    boostTemperatureChange: 0, rampTargetTemperature: 2300,
                                    rampStartingTemperature: 2040, rampRate: 20,
                                    options: [.boost, .customTemperature, .heater,
                                              .noLipCooling, .noLipShutdown, .standby])
        case .flavor:
            return PaxHeatingParams(standbyTemperature: 1600, noMotionToStandbyTime: 15,
                                    noLipCooldownTemperatureChange: 250, noLipCooldownStart: 10,
                                    noLipCooldownRate: 100, noLipPowerOffTime: 180,
                                    boostTemperatureChange: 84, rampTargetTemperature: 2300,
                                    rampStartingTemperature: 2040, rampRate: 20,
                                    options: [.boost, .customTemperature, .heater,
                                              .noLipCooling, .noLipShutdown, .standby])
        }
    }

    /// A block assembled from a misread — or from a firmware whose field order
    /// differs — would be written wholesale to the thing that makes heat, so it
    /// is checked against the envelope the five vendor presets live in before
    /// it goes out. Every bound here is wider than any preset uses.
    /// The option bits are deliberately not checked here: every combination of
    /// them is a state the device can legitimately be in, including the heater
    /// switched off. This is about the numbers.
    var isPlausible: Bool {
        guard (0...2450).contains(Int(standbyTemperature)) else { return false }
        guard (1500...2450).contains(Int(rampTargetTemperature)) else { return false }
        guard (1500...2450).contains(Int(rampStartingTemperature)) else { return false }
        guard rampStartingTemperature <= rampTargetTemperature else { return false }
        // 20 °C over the set point is already more than Boost asks for.
        guard boostTemperatureChange <= 200 else { return false }
        guard noLipCooldownTemperatureChange <= 500 else { return false }
        guard noMotionToStandbyTime <= 3600, noLipPowerOffTime <= 3600 else { return false }
        guard noLipCooldownStart <= 3600, rampRate <= 600, noLipCooldownRate <= 600 else { return false }
        return true
    }

    var summary: String {
        String(format: "standby %.1f°C after %us, boost +%.1f°C, off after %us, options 0x%02X",
               Double(standbyTemperature) / 10, noMotionToStandbyTime,
               Double(boostTemperatureChange) / 10, noLipPowerOffTime, options.rawValue)
    }
}
