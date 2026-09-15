import XCTest

/// The wire format, under test.
///
/// Everything here is a pure function of bytes, which is the part of this app
/// worth pinning down: a mistake in the UI is visible, while a mistake in a
/// payload is a device that stops heating and no way to read back why. Two of
/// these tests exist because exactly that happened — the ColorTheme mode count
/// that walked off the end of a buffer, and the HeatingParams block whose
/// option bits stopped the oven.
final class PaxProtocolTests: XCTestCase {

    // MARK: - Framing

    /// A packet is `[ciphertext: n × 16][IV: 16]`, and the plaintext is padded
    /// up to whole blocks rather than truncated to one. Truncating is what
    /// would hand the device a mode count with no modes behind it.
    func testEncryptPadsToWholeBlocksAndAppendsIV() throws {
        let key = try PaxCrypto.deriveKey(serialNumber: "PXVQH51N")
        for plaintextCount in [1, 15, 16, 17, 23, 34] {
            let plaintext = Data(repeating: 0xA5, count: plaintextCount)
            let packet = try PaxCrypto.encrypt(plaintext: plaintext, key: key)
            let blocks = (plaintextCount + 15) / 16
            XCTAssertEqual(packet.count, blocks * 16 + 16,
                           "\(plaintextCount) bytes should occupy \(blocks) block(s) plus the IV")
            XCTAssertEqual(packet.count % 16, 0)
        }
    }

    func testPacketSurvivesARoundTrip() throws {
        let key = try PaxCrypto.deriveKey(serialNumber: "PXVQH51N")
        let sent = PaxPacket(type: .heaterSetPoint, payload: Data([0x66, 0x08]))
        let wire = try sent.encode(key: key)
        let (received, _) = try PaxPacket.decode(data: wire, key: key)
        XCTAssertEqual(received.type, .heaterSetPoint)
        XCTAssertEqual(received.payload.prefix(2), Data([0x66, 0x08]))
    }

    /// A 34-byte ColorTheme comes back as a single 64-byte packet, not as two
    /// 32-byte packets concatenated. Splitting it decrypts the second half
    /// against the wrong IV and yields garbage that still parses.
    func testLongPacketDecodesAsOnePacket() throws {
        let key = try PaxCrypto.deriveKey(serialNumber: "PXVQH51N")
        let theme = PaxColorTheme.solid(.orange, basedOn: nil)
        let sent = PaxPacket(type: .colorTheme, payload: theme.payload)
        let wire = try sent.encode(key: key)
        XCTAssertEqual(wire.count, 64, "33 payload bytes + type = 34, which is three blocks plus the IV")
        let (received, _) = try PaxPacket.decode(data: wire, key: key)
        XCTAssertEqual(received.type, .colorTheme)
        XCTAssertEqual(PaxColorTheme(payload: received.payload), theme)
    }

    func testDecodeRejectsATruncatedPacket() throws {
        let key = try PaxCrypto.deriveKey(serialNumber: "PXVQH51N")
        XCTAssertThrowsError(try PaxPacket.decode(data: Data(repeating: 0, count: 16), key: key))
    }

    /// The key is derived from the serial alone, so two sessions with the same
    /// device agree without negotiating anything.
    func testKeyDerivationIsStableForASerial() throws {
        let a = try PaxCrypto.deriveKey(serialNumber: "PXVQH51N")
        let b = try PaxCrypto.deriveKey(serialNumber: "PXVQH51N")
        let other = try PaxCrypto.deriveKey(serialNumber: "PXVQH51M")
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, other.withUnsafeBytes { Data($0) })
    }

    // MARK: - Requests

    func testStatusRequestSetsOneBitPerAttribute() {
        let packet = PaxPacket.statusRequest(attributes: [.actualTemp, .heatingState])
        XCTAssertEqual(packet.payload.count, 8)
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(packet.payload[i]) << (8 * i) }
        XCTAssertEqual(bits, (1 << 0x01) | (1 << 0x20))
    }

    /// StatusUpdate is a 64-bit field, so an attribute above 63 cannot be asked
    /// for at all. Dropping it silently beats shifting by 64 and trapping.
    func testStatusRequestIgnoresAttributesItCannotAddress() {
        let packet = PaxPacket.statusRequest(rawAttributes: [0x01, 0x88])
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(packet.payload[i]) << (8 * i) }
        XCTAssertEqual(bits, 1 << 0x01)
    }

    func testTemperatureIsTenthsOfADegreeLittleEndian() {
        let packet = PaxPacket.setTemperature(215)
        XCTAssertEqual(packet.payload, Data([0x66, 0x08]))  // 2150
    }

    // MARK: - DisplayName

    func testDisplayNameCarriesItsOwnLength() throws {
        let packet = try XCTUnwrap(PaxPacket.setDisplayName("Paxie"))
        XCTAssertEqual(packet.payload.first, 5)
        XCTAssertEqual(packet.payload.count, 6)
    }

    /// The length byte must always match what follows it — the same class of
    /// mistake as ColorTheme's mode count — and a multi-byte character must
    /// never be cut in half to make it fit.
    func testDisplayNameTruncatesOnACharacterBoundary() throws {
        let packet = try XCTUnwrap(PaxPacket.setDisplayName(String(repeating: "é", count: 20)))
        let declared = Int(try XCTUnwrap(packet.payload.first))
        XCTAssertEqual(declared, packet.payload.count - 1)
        XCTAssertLessThanOrEqual(declared, PaxPacket.maxDisplayNameBytes)
        XCTAssertEqual(declared % 2, 0, "é is two bytes, so a boundary-safe cut leaves an even count")
        let name = String(data: packet.payload.dropFirst(), encoding: .utf8)
        XCTAssertNotNil(name, "a cut through a character would not decode")
    }

    func testEmptyDisplayNameIsRefused() {
        XCTAssertNil(PaxPacket.setDisplayName(""))
    }

    // MARK: - HeatingParams

    /// The order the official app writes, which is not the order its own source
    /// declares the fields in. Getting this wrong writes plausible numbers into
    /// the wrong fields of the thing that makes heat.
    func testHeatingParamsFieldOrderMatchesTheOfficialApp() {
        let standard = PaxHeatingParams.stock(for: .standard)
        let payload = standard.payload
        XCTAssertEqual(payload.count, PaxHeatingParams.payloadSize)
        XCTAssertEqual(payload.count, 22)

        func word(_ index: Int) -> UInt16 {
            UInt16(payload[index * 2]) | (UInt16(payload[index * 2 + 1]) << 8)
        }
        XCTAssertEqual(word(0), 1600, "standbyTemperature")
        XCTAssertEqual(word(1), 30,   "noMotionToStandbyTime")
        XCTAssertEqual(word(2), 150,  "noLipCooldownTemperatureChange")
        XCTAssertEqual(word(3), 20,   "noLipCooldownStart")
        XCTAssertEqual(word(4), 30,   "noLipCooldownRate")
        XCTAssertEqual(word(5), 180,  "noLipPowerOffTime")
        XCTAssertEqual(word(6), 39,   "boostTemperatureChange")
        XCTAssertEqual(word(7), 2300, "rampTargetTemperature")
        XCTAssertEqual(word(8), 1990, "rampStartingTemperature")
        XCTAssertEqual(word(9), 20,   "rampRate")
        XCTAssertEqual(word(10), 0x9F, "options")
    }

    func testEveryStockPresetRoundTrips() {
        for mode in PaxDynamicMode.allCases {
            let original = PaxHeatingParams.stock(for: mode)
            let parsed = PaxHeatingParams(payload: original.payload)
            XCTAssertEqual(parsed, original, "\(mode.label) did not survive a round trip")
        }
    }

    /// The bit positions come from the official app's own encoder, which builds
    /// the word by prepending — so the first field it lists ends up in bit 0.
    func testOptionBitPositions() {
        XCTAssertEqual(PaxHeatingParams.Options.boost.rawValue,             1 << 0)
        XCTAssertEqual(PaxHeatingParams.Options.customTemperature.rawValue, 1 << 1)
        XCTAssertEqual(PaxHeatingParams.Options.heater.rawValue,            1 << 2)
        XCTAssertEqual(PaxHeatingParams.Options.noLipCooling.rawValue,      1 << 3)
        XCTAssertEqual(PaxHeatingParams.Options.noLipShutdown.rawValue,     1 << 4)
        XCTAssertEqual(PaxHeatingParams.Options.rampContinue.rawValue,      1 << 5)
        XCTAssertEqual(PaxHeatingParams.Options.ramp.rawValue,              1 << 6)
        XCTAssertEqual(PaxHeatingParams.Options.standby.rawValue,           1 << 7)
    }

    func testStockPresetOptionWords() {
        XCTAssertEqual(PaxHeatingParams.stock(for: .standard).options.rawValue,   0x9F)
        XCTAssertEqual(PaxHeatingParams.stock(for: .boost).options.rawValue,      0x9F)
        XCTAssertEqual(PaxHeatingParams.stock(for: .stealth).options.rawValue,    0x9F)
        XCTAssertEqual(PaxHeatingParams.stock(for: .flavor).options.rawValue,     0x9F)
        // Efficiency is the one that gives up the set point and ramps instead.
        XCTAssertEqual(PaxHeatingParams.stock(for: .efficiency).options.rawValue, 0xDD)
    }

    func testEveryStockPresetIsPlausible() {
        for mode in PaxDynamicMode.allCases {
            XCTAssertTrue(PaxHeatingParams.stock(for: mode).isPlausible, "\(mode.label)")
        }
    }

    /// The guard exists so a block assembled from a misread never reaches the
    /// heater. A zeroed block is the shape a misread takes.
    func testImplausibleBlocksAreRejected() {
        XCTAssertNil(PaxHeatingParams(payload: Data(repeating: 0, count: 4)),
                     "a short payload is not a block at all")
        let zeroed = PaxHeatingParams(payload: Data(repeating: 0, count: 22))
        XCTAssertNotNil(zeroed)
        XCTAssertFalse(zeroed?.isPlausible ?? true, "ramp temperatures of zero are not a heating profile")

        var scorching = PaxHeatingParams.stock(for: .standard)
        scorching.rampTargetTemperature = 3000
        XCTAssertFalse(scorching.isPlausible)

        var backwards = PaxHeatingParams.stock(for: .standard)
        backwards.rampStartingTemperature = backwards.rampTargetTemperature + 10
        XCTAssertFalse(backwards.isPlausible, "a ramp cannot start above where it is going")
    }

    /// The option bits the app clears for lip detection. Bit 0 is in this set
    /// under the official app's naming, and is the heater on a PAX 3 — which is
    /// why the view model removes the measured heater bit before writing, and
    /// why this set on its own is not safe to subtract.
    func testLipDetectionCoversTheThreeBitsTheOfficialAppGroups() {
        let lip = PaxHeatingParams.Options.lipDetection
        XCTAssertTrue(lip.contains(.boost))
        XCTAssertTrue(lip.contains(.noLipCooling))
        XCTAssertTrue(lip.contains(.noLipShutdown))
        XCTAssertFalse(lip.contains(.heater))
        XCTAssertFalse(lip.contains(.standby))
        XCTAssertEqual(lip.rawValue, 0b0001_1001)
    }

    func testHeatingParamsPayloadLengthIsDeclared() {
        XCTAssertEqual(PaxMessageType.heatingParams.payloadLength, 22)
    }

    // MARK: - Reported values

    func testHeatingStateValues() {
        XCTAssertEqual(PaxHeatingState(rawValue: 0x00), .heating)
        XCTAssertEqual(PaxHeatingState(rawValue: 0x01), .ready)
        XCTAssertEqual(PaxHeatingState(rawValue: 0x02), .boosting)
        XCTAssertEqual(PaxHeatingState(rawValue: 0x03), .cooling)
        XCTAssertEqual(PaxHeatingState(rawValue: 0x04), .standby)
        XCTAssertEqual(PaxHeatingState(rawValue: 0x05), .ovenOff)
        XCTAssertEqual(PaxHeatingState(rawValue: 0x06), .tempSetMode)
        XCTAssertTrue(PaxHeatingState.heating.isWarmingUp)
        XCTAssertFalse(PaxHeatingState.ready.isWarmingUp)
    }

    func testSupportedAttributesReadsTheBitfield() {
        var payload = Data(repeating: 0, count: 8)
        payload[0] = 0b0000_0010          // attribute 1
        payload[4] = 0b0000_0001          // attribute 32
        let packet = PaxPacket(type: .supportedAttribs, payload: payload)
        XCTAssertEqual(packet.supportedAttributes, [0x01, 0x20])
    }

    // MARK: - ColorTheme

    /// The mode count byte must match the modes behind it. A 3-byte RGB payload
    /// made a real device read byte 1 as a count of 255 and walk 2 kB off the
    /// end of a 15-byte buffer; it powered off two seconds later.
    func testColorThemeCountMatchesItsModes() {
        let theme = PaxColorTheme.solid(.orange, basedOn: nil)
        let payload = theme.payload
        XCTAssertEqual(Int(payload[0]), PaxColorTheme.modeCount)
        XCTAssertEqual(payload.count, PaxColorTheme.payloadSize)
        XCTAssertEqual(payload.count, 1 + Int(payload[0]) * PaxColorTheme.modeSize)
    }

    func testColorThemeRejectsACountItCannotFit() {
        XCTAssertNil(PaxColorTheme(payload: Data([0xFF, 0x11, 0x22, 0x33])),
                     "a count of 255 with three bytes behind it is not a theme")
        XCTAssertNil(PaxColorTheme(payload: Data()))
        XCTAssertNil(PaxColorTheme(payload: Data([0x00])))
    }

    func testColorThemeSetColorsTouchesOnlyOneMode() {
        var theme = PaxColorTheme.solid(.orange, basedOn: nil)
        let before = theme.modes
        theme.setColors(.heating, color1: .pairedWith, color2: .pairedWith)
        XCTAssertNotEqual(theme.modes[PaxColorTheme.Mode.heating.rawValue], before[PaxColorTheme.Mode.heating.rawValue])
        XCTAssertEqual(theme.modes[PaxColorTheme.Mode.startup.rawValue], before[PaxColorTheme.Mode.startup.rawValue])
        XCTAssertEqual(theme.modes[PaxColorTheme.Mode.standby.rawValue], before[PaxColorTheme.Mode.standby.rawValue])
    }
}
