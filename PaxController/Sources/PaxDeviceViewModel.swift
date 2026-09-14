import Foundation
import CoreBluetooth
import CryptoKit
import Combine

// MARK: - Connection State

enum ConnectionState: Equatable {
    case idle
    case scanning
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

    // MARK: Private
    private let bluetooth = BluetoothManager()
    private var sessionKey: SymmetricKey?
    private var serialReady = false
    private var pendingCommands: [() throws -> Void] = []
    private var pollTimer: AnyCancellable?

    init() {
        bluetooth.delegate = self
        // The simulator has no Bluetooth radio, so the screenshot workflow
        // launches with `-uiDemo YES` to fill in a plausible connected device.
        // Launch arguments land in UserDefaults' argument domain, so this is
        // unreachable in normal use - nothing in the UI sets the key.
        if UserDefaults.standard.bool(forKey: "uiDemo") {
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
        connectionState = .disconnecting
        bluetooth.disconnect()
        log("Disconnecting…", level: .info)
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
        default:
            break
        }
    }

    private func checkReady() {
        guard paxServiceConfirmed, serialReady else { return }
        log("PAX service confirmed + serial ready — entering ready state", level: .info)
        connectionState = .ready
        flushPendingCommands()
        requestFullStatus()
        startPolling()
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
