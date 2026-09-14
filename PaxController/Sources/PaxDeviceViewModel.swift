import Foundation
import CoreBluetooth
import CryptoKit
import Combine

// MARK: - Connection State

enum ConnectionState: Equatable {
    case idle
    case scanning
    /// A pending, timeout-free connect is armed for a known device. iOS holds
    /// it until the PAX shows up, which may be seconds or hours — deliberately
    /// distinct from `.connecting`, which is an exchange already underway.
    case waitingForDevice
    case connecting
    case discoveringServices
    case awaitingSerial
    case ready
    case disconnecting
    case error(String)

    var displayString: String {
        switch self {
        case .idle:                 return "Idle"
        case .scanning:             return "Scanning…"
        case .waitingForDevice:     return "Waiting for PAX…"
        case .connecting:           return "Connecting…"
        case .discoveringServices:  return "Discovering services…"
        case .awaitingSerial:       return "Reading serial number…"
        case .ready:                return "Connected"
        case .disconnecting:        return "Disconnecting…"
        case .error(let msg):       return "Error: \(msg)"
        }
    }

    var isConnected: Bool { self == .ready }
}

// MARK: - Debug Log

struct DebugEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String {
        case info  = "ℹ️"
        case ble   = "📡"
        case tx    = "⬆️"
        case rx    = "⬇️"
        case warn  = "⚠️"
        case error = "❌"
    }

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }
}

// MARK: - PaxDeviceViewModel

@MainActor
final class PaxDeviceViewModel: ObservableObject {

    // MARK: Connection / scan
    @Published var connectionState: ConnectionState = .idle
    @Published var scannedDevices: [ScannedDevice] = []

    // MARK: Device telemetry
    @Published var batteryLevel: Int?
    @Published var actualTempC: Double?
    @Published var targetTempC: Double?
    @Published var currentTargetTempC: Double?
    @Published var heatingState: PaxHeatingState?
    @Published var isCharging: Bool?
    @Published var dynamicMode: PaxDynamicMode?
    @Published var isLocked: Bool?
    @Published var displayName: String?
    @Published var serialNumber: String?
    @Published var firmwareRevision: String?
    @Published var modelNumber: String?

    // MARK: UI state
    @Published var selectedPreset: PaxPresetTemp? = nil
    @Published var customTargetTempC: Double = 185

    // MARK: PAX service verification
    // All three PAX characteristics must be confirmed before commands are allowed.
    @Published var paxServiceConfirmed = false
    @Published var paxCharReadFound    = false
    @Published var paxCharWriteFound   = false
    @Published var paxCharNotifyFound  = false
    @Published var paxCharNotifying    = false

    // MARK: Debug log
    @Published var debugLog: [DebugEntry] = []

    // MARK: Remembered device (auto-connect)
    @Published private(set) var rememberedDeviceName: String?

    // MARK: LED capability, discovered from the device
    /// Attribute IDs the device reported via SupportedAttributes (0x18).
    @Published private(set) var supportedAttributes: Set<UInt8> = []
    /// Payload the device reported for each LED attribute, so a write can echo
    /// the same shape rather than invent one.
    private var ledAttributeShapes: [UInt8: Data] = [:]
    /// The write we are waiting to confirm by reading the attribute back.
    private var pendingLedWrite: (attribute: UInt8, payload: Data)?
    /// Send the saved colour as soon as we learn the device can accept one.
    private var pushColorOnceDiscovered = false
    /// True once the device has answered the capability query, which is what
    /// separates "we do not know yet" from "this firmware cannot do it".
    private var capabilitiesKnown = false
    /// Coalesces colour-wheel drags into a single write.
    private var ledWriteDebounce: Task<Void, Never>?

    /// Which attribute to use for LED color, preferring the one the device
    /// actually answered with. nil means it never reported either, so there is
    /// nothing sensible to write.
    /// Whether the connected device reported an LED attribute we can write.
    var deviceLedColorSupported: Bool { ledAttribute != nil }

    private var ledAttribute: PaxMessageType? {
        for candidate in [PaxMessageType.colorTheme, .shellColor]
        where ledAttributeShapes[candidate.rawValue] != nil || supportedAttributes.contains(candidate.rawValue) {
            return candidate
        }
        return nil
    }

    // MARK: Private
    private let bluetooth = BluetoothManager()
    private let settings = AppSettings.shared
    private var sessionKey: SymmetricKey?
    private var serialReady = false
    private var pendingCommands: [() throws -> Void] = []
    private var pollTimer: AnyCancellable?
    /// Distinguishes "the user tapped Disconnect" from "the device went away",
    /// because only the latter should re-arm the auto-reconnect.
    private var userInitiatedDisconnect = false

    /// Screenshot fixture switch. Launch arguments land in UserDefaults'
    /// argument domain, so this is unreachable in normal use - nothing in the
    /// UI sets the key.
    private let demoMode = UserDefaults.standard.bool(forKey: "uiDemo")

    init() {
        bluetooth.delegate = self
        rememberedDeviceName = Self.storedDeviceName
        // The simulator has no Bluetooth radio, so the screenshot workflow
        // launches with `-uiDemo YES` to fill in a plausible connected device.
        if demoMode {
            loadDemoFixture()
        }
    }

    /// Populates the published state as if a PAX 3 were connected.
    private func loadDemoFixture() {
        connectionState = .ready
        scannedDevices = [
            ScannedDevice(id: UUID(), peripheral: nil, name: "PAX 3", rssi: -52)
        ]

        displayName       = "PAX 3"
        modelNumber       = "PAX 3"
        serialNumber      = "P3D1J4K7QM"
        firmwareRevision  = "1.34.1"

        batteryLevel      = 78
        isCharging        = false
        isLocked          = false
        heatingState      = .ready
        dynamicMode       = .standard

        actualTempC        = 193.4
        targetTempC        = 193.0
        currentTargetTempC = 193.0
        selectedPreset     = .t193
        customTargetTempC  = 193

        paxServiceConfirmed = true
        paxCharReadFound    = true
        paxCharWriteFound   = true
        paxCharNotifyFound  = true
        paxCharNotifying    = true

        log("Demo fixture loaded", level: .info)
    }

    // MARK: - Public commands

    func startScan() {
        guard bluetooth.isPoweredOn else {
            log("Bluetooth not ready", level: .warn)
            return
        }
        scannedDevices.removeAll()
        connectionState = .scanning
        bluetooth.scan()
        log("Scanning for PAX devices…", level: .info)
    }

    func stopScan() {
        bluetooth.stopScan()
        if case .scanning = connectionState { connectionState = .idle }
        log("Scan stopped", level: .info)
    }

    func connect(to device: ScannedDevice) {
        stopScan()
        connectionState = .connecting
        bluetooth.connect(to: device)
        log("Connecting to \(device.name) [\(device.id)]", level: .info)
    }

    func disconnect() {
        userInitiatedDisconnect = true
        connectionState = .disconnecting
        bluetooth.disconnect()
        LiveActivityController.shared.end()
        log("Disconnecting…", level: .info)
    }

    // MARK: - Auto-connect

    private static let deviceIDKey   = "lastDeviceIdentifier"
    private static let deviceNameKey = "lastDeviceName"

    private static var storedDeviceID: UUID? {
        UserDefaults.standard.string(forKey: deviceIDKey).flatMap(UUID.init(uuidString:))
    }

    private static var storedDeviceName: String? {
        UserDefaults.standard.string(forKey: deviceNameKey)
    }

    /// Re-issues a connect for the last device we successfully paired with.
    /// CoreBluetooth connects have **no timeout**: iOS keeps the request
    /// pending at the controller level and completes it whenever the PAX comes
    /// into range — including while the app is backgrounded, or after iOS has
    /// terminated and relaunched it via state restoration. This, not scanning,
    /// is what makes background reconnection work.
    func attemptAutoConnect() {
        guard settings.autoConnectEnabled else { return }
        guard !connectionState.isConnected, !demoMode else { return }
        guard let id = Self.storedDeviceID else { return }

        guard let device = bluetooth.autoConnect(toKnownIdentifier: id) else {
            log("Auto-connect: iOS no longer knows device \(id) — scan once to re-pair", level: .warn)
            return
        }
        connectionState = .waitingForDevice
        log("Auto-connect armed for \(device.name) — will connect whenever it is in range", level: .info)
        refreshLiveActivity()
    }

    func forgetRememberedDevice() {
        UserDefaults.standard.removeObject(forKey: Self.deviceIDKey)
        UserDefaults.standard.removeObject(forKey: Self.deviceNameKey)
        rememberedDeviceName = nil
        bluetooth.cancelPendingConnect()
        if !connectionState.isConnected { connectionState = .idle }
        LiveActivityController.shared.end()
        log("Forgot the remembered device — auto-connect disarmed", level: .info)
    }

    private func rememberCurrentDevice() {
        guard let id = bluetooth.connectedPeripheral?.identifier else { return }
        let name = displayName ?? modelNumber ?? "PAX"
        UserDefaults.standard.set(id.uuidString, forKey: Self.deviceIDKey)
        UserDefaults.standard.set(name, forKey: Self.deviceNameKey)
        rememberedDeviceName = name
        log("Remembered \(name) for auto-connect", level: .info)
    }

    // MARK: - LED color

    /// Applies the chosen color to the app's accent and, when enabled, tries to
    /// push it to the PAX itself. The device-side payload format is unconfirmed
    /// (protocol-notes.md lists ShellColor as "Unknown"), so the outcome is
    /// logged to the Debug Console rather than surfaced as a guaranteed result.
    /// Applies the colour the instant it is picked: the app re-themes
    /// synchronously, and the device write follows immediately.
    func applyLedColor(_ color: LedColor) {
        settings.ledColorHex = color.hex
        refreshLiveActivity()
        guard settings.pushColorToDevice else { return }

        guard connectionState.isConnected else {
            pushColorOnceDiscovered = true
            log("LED color saved — it will be sent as soon as the PAX connects", level: .info)
            return
        }

        // Dragging the colour wheel fires on every frame. Coalesce into one
        // write per gesture so the link is not flooded — short enough that a
        // tap on a preset still lands immediately.
        ledWriteDebounce?.cancel()
        ledWriteDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.sendLedColorToDevice(color)
        }
    }

    private func sendLedColorToDevice(_ color: LedColor) {
        guard let attribute = ledAttribute else {
            // Tapping a colour in the moment between connecting and the
            // capability reply landing must not be lost — queue it instead.
            if !capabilitiesKnown {
                pushColorOnceDiscovered = true
                log("Holding \(color.hex) until the device reports which LED attribute it supports", level: .info)
            } else {
                log("Not sending \(color.hex): this firmware reports neither ColorTheme nor ShellColor, so its LEDs cannot be set over BLE. The in-app accent color still changed.",
                    level: .warn)
            }
            return
        }
        let payload = ledPayload(for: color, attribute: attribute)
        pendingLedWrite = (attribute.rawValue, payload)
        enqueue {
            try self.sendPacket(PaxPacket.setLedColor(attribute: attribute, payload: payload))
            self.log("Wrote \(attribute) = \(payload.hexString) for \(color.hex)", level: .tx)
            // The write characteristic is writeWithoutResponse, so no ACK can
            // ever come back. Reading the attribute again is the only way to
            // find out whether the device took it.
            try self.sendPacket(PaxPacket.statusRequest(attributes: [attribute]))
        }
    }

    /// Builds a payload matching the shape the device reported for this
    /// attribute. A 1-byte value is a theme index, not a color, so the chosen
    /// preset's position is sent instead of RGB.
    private func ledPayload(for color: LedColor, attribute: PaxMessageType) -> Data {
        let rgb = Data([color.red, color.green, color.blue])
        guard let known = ledAttributeShapes[attribute.rawValue], !known.isEmpty else {
            return rgb
        }
        switch known.count {
        case 1:
            let index = LedColor.presets.firstIndex { $0.hex == color.hex } ?? 0
            return Data([UInt8(index)])
        case 3:
            return rgb
        default:
            var padded = rgb
            if padded.count > known.count {
                padded = Data(padded.prefix(known.count))
            } else {
                padded.append(contentsOf: known.dropFirst(padded.count))
            }
            return padded
        }
    }

    // MARK: - Live Activity

    /// Headline shown on the Lock Screen card and in the in-app banner.
    var statusHeadline: String {
        guard connectionState.isConnected else {
            switch connectionState {
            case .connecting, .discoveringServices, .awaitingSerial:
                return "Connecting…"
            case .scanning:
                return "Scanning…"
            case .waitingForDevice:
                return "Waiting for PAX…"
            case .error(let msg):
                return msg
            default:
                return Self.storedDeviceID != nil ? "Waiting for PAX…" : "Not connected"
            }
        }
        if isCharging == true {
            return (batteryLevel ?? 0) >= 100 ? "Charged" : "Charging"
        }
        if let state = heatingState { return state.description }
        return "Connected"
    }

    func refreshLiveActivity() {
        guard settings.liveActivityEnabled, !demoMode else { return }
        let state = PaxActivityAttributes.ContentState(
            isConnected: connectionState.isConnected,
            headline: statusHeadline,
            batteryLevel: batteryLevel,
            isCharging: isCharging ?? false,
            // Rounded because the card renders whole degrees: without this the
            // 0.1° poll jitter would push a Live Activity update every 3 s and
            // burn through the system's update budget for nothing.
            actualTempC: actualTempC?.rounded(),
            targetTempC: targetTempC?.rounded(),
            ledColorHex: settings.ledColorHex,
            useFahrenheit: settings.useFahrenheit)
        LiveActivityController.shared.sync(
            deviceName: displayName ?? rememberedDeviceName ?? "PAX",
            state: state)
    }

    func endLiveActivity() {
        LiveActivityController.shared.end()
    }

    /// One-shot on connect. SupportedAttributes (0x18) is the device telling us
    /// exactly which attribute IDs its firmware implements, and asking for the
    /// two LED attributes makes it report their *current* values — which is how
    /// we learn the payload shape instead of guessing at it. Deliberately not
    /// part of the 3 s poll.
    func requestCapabilities() {
        enqueue {
            let attrs: [PaxMessageType] = [.supportedAttribs, .colorTheme, .shellColor, .brightness, .uiMode]
            try self.sendPacket(PaxPacket.statusRequest(attributes: attrs))
            self.log("Asked the device which attributes it supports, and for its current LED values", level: .tx)
        }
    }

    func requestFullStatus() {
        enqueue {
            let attrs: [PaxMessageType] = [
                .actualTemp, .heaterSetPoint, .battery,
                .heatingState, .lockStatus, .dynamicMode,
                .currentTargetTemp, .displayName
            ]
            let packet = PaxPacket.statusRequest(attributes: attrs)
            try self.sendPacket(packet)
            self.log("Sent STATUS_REQUEST for core attributes", level: .tx)
        }
    }

    func setTemperature(_ preset: PaxPresetTemp) {
        selectedPreset = preset
        customTargetTempC = Double(preset.rawValue)
        enqueue {
            let packet = PaxPacket.setTemperature(preset.rawValue)
            try self.sendPacket(packet)
            self.log("Set temperature → \(preset.label)", level: .tx)
        }
    }

    func setCustomTemperature(_ celsius: Double) {
        let clamped = Int(celsius.rounded())
        selectedPreset = PaxPresetTemp(rawValue: clamped)
        enqueue {
            let packet = PaxPacket.setTemperature(clamped)
            try self.sendPacket(packet)
            self.log("Set temperature → \(clamped)°C", level: .tx)
        }
    }

    func setDynamicMode(_ mode: PaxDynamicMode) {
        enqueue {
            let packet = PaxPacket.setDynamicMode(mode)
            try self.sendPacket(packet)
            self.log("Set dynamic mode → \(mode.label)", level: .tx)
            self.dynamicMode = mode
        }
    }

    func clearLog() { debugLog.removeAll() }

    // MARK: - Internal helpers

    private func sendPacket(_ packet: PaxPacket) throws {
        guard let key = sessionKey else { throw PaxError.notConnected }
        let data = try packet.encode(key: key)
        log("TX [\(packet.type)] \(data.hexString)", level: .tx)
        try bluetooth.writeCommand(data)
    }

    private func enqueue(_ command: @escaping () throws -> Void) {
        if case .ready = connectionState {
            do { try command() }
            catch { log("Command failed: \(error.localizedDescription)", level: .error) }
        } else {
            pendingCommands.append(command)
        }
    }

    private func flushPendingCommands() {
        let cmds = pendingCommands
        pendingCommands.removeAll()
        for cmd in cmds {
            do { try cmd() }
            catch { log("Deferred command failed: \(error.localizedDescription)", level: .error) }
        }
    }

    private func handlePacket(_ data: Data) {
        guard let key = sessionKey else {
            log("RX [no key yet] \(data.hexString)", level: .warn)
            return
        }
        // A single BLE read may contain multiple concatenated 32-byte packets.
        // Split into 32-byte chunks and decrypt each separately.
        guard data.count >= 32, data.count % 32 == 0 else {
            log("RX ignoring \(data.count)B (not a multiple of 32) raw=\(data.hexString)", level: .warn)
            return
        }
        var offset = 0
        while offset + 32 <= data.count {
            let chunk = data.subdata(in: offset..<(offset + 32))
            decodeChunk(chunk, key: key)
            offset += 32
        }
    }

    private func decodeChunk(_ chunk: Data, key: SymmetricKey) {
        do {
            let (packet, plaintext) = try PaxPacket.decode(data: chunk, key: key)
            let typeHex = String(packet.type.rawValue, radix: 16, uppercase: true)
            log("RX 0x\(typeHex) [\(packet.type)] plain=\(plaintext.hexString)", level: .rx)
            applyPacket(packet)
        } catch PaxError.decryptionFailed(let msg) {
            log("RX decrypt failed: \(msg) raw=\(chunk.hexString)", level: .error)
        } catch PaxError.unknownMessageType(let t) {
            let tHex = String(t, radix: 16, uppercase: true)
            log("RX 0x\(tHex) unknown type (ignored)", level: .rx)
        } catch {
            log("RX error: \(error.localizedDescription)", level: .error)
        }
    }

    private func applyPacket(_ packet: PaxPacket) {
        switch packet.type {
        case .actualTemp:
            actualTempC = packet.temperatureCelsius
        case .heaterSetPoint:
            targetTempC = packet.temperatureCelsius
            if let t = packet.temperatureCelsius {
                customTargetTempC = min(215, max(180, t))
            }
        case .battery:
            batteryLevel = packet.batteryLevel
            log("Battery: \(packet.batteryLevel.map { "\($0)%" } ?? "nil")", level: .info)
        case .chargeStatus:
            isCharging = (packet.payload.count >= 1 && packet.payload[0] != 0)
        case .heatingState:
            heatingState = packet.heatingState
        case .lockStatus:
            isLocked = packet.lockState
        case .dynamicMode:
            dynamicMode = packet.dynamicMode
        case .currentTargetTemp:
            currentTargetTempC = packet.temperatureCelsius
        case .displayName:
            if packet.payload.count > 1 {
                let len = Int(packet.payload[0])
                if packet.payload.count >= 1 + len {
                    displayName = String(bytes: packet.payload[1..<(1 + len)], encoding: .utf8)
                }
            }
        case .supportedAttribs:
            applySupportedAttributes(packet)
        case .colorTheme, .shellColor:
            applyLedAttributeReport(packet)
        default:
            break
        }
        refreshLiveActivity()
    }

    private func applySupportedAttributes(_ packet: PaxPacket) {
        let supported = packet.supportedAttributes
        guard !supported.isEmpty else {
            log("SupportedAttributes came back empty — cannot tell what this firmware implements", level: .warn)
            return
        }
        capabilitiesKnown = true
        supportedAttributes = supported
        let described = supported.sorted().map { id -> String in
            let hex = String(format: "0x%02X", id)
            if let known = PaxMessageType(rawValue: id) { return "\(hex) \(known)" }
            return hex
        }
        log("Device supports \(supported.count) attributes: \(described.joined(separator: ", "))", level: .info)

        let colorSupported = [PaxMessageType.colorTheme, .shellColor].filter { supported.contains($0.rawValue) }
        if colorSupported.isEmpty {
            log("Neither ColorTheme (0x14) nor ShellColor (0x1C) is supported — this device cannot have its LEDs set over BLE. The in-app accent color still works.",
                level: .warn)
        } else {
            log("LED attribute(s) available: \(colorSupported.map { "\($0)" }.joined(separator: ", "))", level: .info)
        }
        pushSavedColorIfReady()
    }

    private func pushSavedColorIfReady() {
        guard pushColorOnceDiscovered, ledAttribute != nil else { return }
        pushColorOnceDiscovered = false
        sendLedColorToDevice(settings.ledColor)
    }

    /// The device reporting its current LED value is the only reliable source
    /// for the payload's length and encoding, so record it verbatim.
    private func applyLedAttributeReport(_ packet: PaxPacket) {
        let trimmed = Data(packet.payload.prefix(8))
        let previous = ledAttributeShapes[packet.type.rawValue]
        ledAttributeShapes[packet.type.rawValue] = trimmed

        // A value arriving for an attribute the bitfield did not list still
        // proves the device implements it.
        capabilitiesKnown = true
        pushSavedColorIfReady()

        if let pending = pendingLedWrite, pending.attribute == packet.type.rawValue {
            pendingLedWrite = nil
            if trimmed.prefix(pending.payload.count) == pending.payload {
                log("✔ Device accepted \(packet.type) = \(trimmed.hexString)", level: .info)
            } else {
                log("✘ Device ignored the \(packet.type) write — asked for \(pending.payload.hexString), still reports \(trimmed.hexString)",
                    level: .warn)
            }
            return
        }

        guard previous != trimmed else { return }
        log("Current \(packet.type) value: \(trimmed.hexString) (\(trimmed.count) B) — a write must match this shape",
            level: .info)
    }

    private func checkReady() {
        guard paxServiceConfirmed, serialReady else { return }
        log("PAX service confirmed + serial ready — entering ready state", level: .info)
        connectionState = .ready
        userInitiatedDisconnect = false
        rememberCurrentDevice()
        flushPendingCommands()
        requestFullStatus()
        // The colour push waits for the capability reply: writing before the
        // device has told us which attribute it implements is exactly the blind
        // guess that did nothing on real hardware.
        pushColorOnceDiscovered = settings.pushColorToDevice
        requestCapabilities()
        startPolling()
        refreshLiveActivity()
    }

    private func startPolling() {
        // Poll every 3 s — PAX 3 firmware only sends temp/battery in response to requests.
        pollTimer?.cancel()
        pollTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.requestFullStatus()
            }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func resetDeviceState() {
        batteryLevel = nil
        actualTempC = nil
        targetTempC = nil
        currentTargetTempC = nil
        heatingState = nil
        isCharging = nil
        dynamicMode = nil
        isLocked = nil
        displayName = nil
        serialNumber = nil
        firmwareRevision = nil
        modelNumber = nil
        selectedPreset = nil
        sessionKey = nil
        serialReady = false
        paxServiceConfirmed = false
        paxCharReadFound    = false
        paxCharWriteFound   = false
        paxCharNotifyFound  = false
        paxCharNotifying    = false
        pendingCommands.removeAll()
        supportedAttributes.removeAll()
        ledAttributeShapes.removeAll()
        pendingLedWrite = nil
        pushColorOnceDiscovered = false
        capabilitiesKnown = false
        ledWriteDebounce?.cancel()
        ledWriteDebounce = nil
    }

    func log(_ message: String, level: DebugEntry.Level = .info) {
        let entry = DebugEntry(timestamp: Date(), level: level, message: message)
        debugLog.append(entry)
        if debugLog.count > 500 { debugLog.removeFirst(debugLog.count - 500) }
    }
}

// MARK: - BluetoothManagerDelegate

extension PaxDeviceViewModel: BluetoothManagerDelegate {

    func bluetoothDidUpdatePower(available: Bool) {
        log("Bluetooth power: \(available ? "ON" : "OFF")", level: .ble)
        // The simulator reports the radio as unavailable immediately, which
        // would wipe the fixture straight after init.
        guard !demoMode else { return }
        if !available {
            connectionState = .idle
            resetDeviceState()
        }
    }

    func bluetoothDidDiscover(device: ScannedDevice) {
        log("Found: \(device.name) [\(device.id)] RSSI=\(device.rssi)", level: .ble)
        if let idx = scannedDevices.firstIndex(where: { $0.id == device.id }) {
            scannedDevices[idx] = device
        } else {
            scannedDevices.append(device)
        }
    }

    func bluetoothDidConnect() {
        log("Connected — discovering services…", level: .ble)
        connectionState = .discoveringServices
    }

    func bluetoothDidFailToConnect(error: String) {
        log("Failed to connect: \(error)", level: .error)
        connectionState = .error(error)
    }

    func bluetoothDidDisconnect(error: String?) {
        stopPolling()
        if let e = error {
            log("Disconnected with error: \(e)", level: .warn)
        } else {
            log("Disconnected cleanly", level: .ble)
        }
        connectionState = .idle
        resetDeviceState()

        if userInitiatedDisconnect {
            userInitiatedDisconnect = false
            LiveActivityController.shared.end()
            return
        }
        // The device went away on its own (powered off, walked out of range).
        // Re-arm the pending connect so iOS brings it back automatically, and
        // leave the Lock Screen card up showing "Waiting for PAX…" — ending it
        // here would be unrecoverable, since a background reconnect is allowed
        // to update an activity but never to start one.
        attemptAutoConnect()
        refreshLiveActivity()
    }

    func bluetoothReadyForAutoConnect() {
        attemptAutoConnect()
    }

    func bluetoothDiscoveredService(_ uuid: CBUUID) {
        log("Service: \(uuid.uuidString)", level: .ble)
    }

    func bluetoothDiscoveredCharacteristic(_ uuid: CBUUID, properties: CBCharacteristicProperties) {
        log("  Char: \(uuid.uuidString) props=[\(formatProperties(properties))]", level: .ble)

        switch uuid {
        case PaxUUIDs.readCharUUID:
            paxCharReadFound = true
            log("  ✔ PAX read char confirmed (props: \(formatProperties(properties)))", level: .ble)
        case PaxUUIDs.writeCharUUID:
            paxCharWriteFound = true
            log("  ✔ PAX write char confirmed (props: \(formatProperties(properties)))", level: .ble)
        case PaxUUIDs.notifyCharUUID:
            paxCharNotifyFound = true
            log("  ✔ PAX notify char confirmed (props: \(formatProperties(properties)))", level: .ble)
        case PaxUUIDs.serialNumberChar:
            connectionState = .awaitingSerial
        default:
            break
        }

        if paxCharReadFound && paxCharWriteFound && paxCharNotifyFound {
            log("PAX service structure verified: read + write + notify all present", level: .info)
        }
    }

    func bluetoothDidRead(characteristic: CBUUID, data: Data) {
        switch characteristic {
        case PaxUUIDs.serialNumberChar:
            let serial = String(data: data, encoding: .utf8) ?? data.hexString
            log("Serial number: \(serial)", level: .ble)
            serialNumber = serial
            do {
                let key = try PaxCrypto.deriveKey(serialNumber: serial)
                sessionKey = key
                let keyHex = key.withUnsafeBytes { Data($0).hexString }
                log("Session key (16 B): \(keyHex)", level: .info)
                serialReady = true
                if !paxServiceConfirmed {
                    log("Serial ready but PAX service not yet confirmed — waiting for notify subscription", level: .warn)
                }
                checkReady()
            } catch {
                log("Key derivation failed: \(error.localizedDescription)", level: .error)
                connectionState = .error(error.localizedDescription)
            }

        case PaxUUIDs.modelNumberChar:
            modelNumber = String(data: data, encoding: .utf8) ?? data.hexString
            log("Model: \(modelNumber ?? "?")", level: .ble)

        case PaxUUIDs.firmwareRevChar:
            firmwareRevision = String(data: data, encoding: .utf8) ?? data.hexString
            log("Firmware: \(firmwareRevision ?? "?")", level: .ble)

        case PaxUUIDs.manufacturerChar:
            let val = String(data: data, encoding: .utf8) ?? data.hexString
            log("Manufacturer: \(val)", level: .ble)

        case PaxUUIDs.readCharUUID:
            log("Read char: \(data.hexString)", level: .rx)
            handlePacket(data)

        default:
            log("Read \(characteristic.uuidString): \(data.hexString)", level: .rx)
        }
    }

    func bluetoothDidWrite(characteristic: CBUUID) {
        log("Write ACK \(characteristic.uuidString)", level: .ble)
    }

    func bluetoothDidError(_ message: String, characteristic: CBUUID?) {
        let ctx = characteristic.map { " (\($0.uuidString))" } ?? ""
        log("BLE error\(ctx): \(message)", level: .error)
        if case .connecting = connectionState { connectionState = .error(message) }
        if case .discoveringServices = connectionState { connectionState = .error(message) }
    }

    func bluetoothNotifyStateChanged(characteristic: CBUUID, isNotifying: Bool) {
        log("Notify \(characteristic.uuidString): \(isNotifying ? "ON" : "OFF")", level: .ble)
        guard characteristic == PaxUUIDs.notifyCharUUID else { return }
        paxCharNotifying = isNotifying
        if isNotifying {
            log("Notify subscription confirmed — PAX service fully operational", level: .info)
            paxServiceConfirmed = paxCharReadFound && paxCharWriteFound && paxCharNotifyFound
            if !paxServiceConfirmed {
                log("Notify active but not all PAX chars found — unexpected device?", level: .warn)
            }
            checkReady()
        }
    }
}
