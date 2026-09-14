import Foundation
import CoreBluetooth
import CryptoKit

// MARK: - Shared value types (used by both BT layer and ViewModel)

struct ScannedDevice: Identifiable, Equatable {
    let id: UUID
    // Optional so the demo fixture can stand in without a real radio; every
    // real scan result still carries its peripheral.
    let peripheral: CBPeripheral?
    let name: String
    let rssi: Int

    static func == (lhs: ScannedDevice, rhs: ScannedDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - BluetoothManagerDelegate
// Pure transport events — no UI state, no interpretation beyond raw data.

@MainActor
protocol BluetoothManagerDelegate: AnyObject {
    func bluetoothDidUpdatePower(available: Bool)
    func bluetoothDidDiscover(device: ScannedDevice)
    func bluetoothDidConnect()
    func bluetoothDidFailToConnect(error: String)
    func bluetoothDidDisconnect(error: String?)
    func bluetoothDiscoveredService(_ uuid: CBUUID)
    func bluetoothDiscoveredCharacteristic(_ uuid: CBUUID, properties: CBCharacteristicProperties)
    func bluetoothDidRead(characteristic: CBUUID, data: Data)
    func bluetoothDidWrite(characteristic: CBUUID)
    func bluetoothDidError(_ message: String, characteristic: CBUUID?)
    func bluetoothNotifyStateChanged(characteristic: CBUUID, isNotifying: Bool)
}

// MARK: - BluetoothManager (pure BLE transport)

@MainActor
final class BluetoothManager: NSObject {
    weak var delegate: BluetoothManagerDelegate?

    private var centralManager: CBCentralManager!
    private(set) var connectedPeripheral: CBPeripheral?

    private var readChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var writeCharProps: CBCharacteristicProperties = []

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - scan()

    func scan() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: [PaxUUIDs.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        centralManager.stopScan()
    }

    // MARK: - connect() / disconnect()

    func connect(to device: ScannedDevice) {
        guard let peripheral = device.peripheral else { return }
        connectedPeripheral = peripheral
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(p)
    }

    // MARK: - discoverServices()

    func discoverServices() {
        guard let p = connectedPeripheral else { return }
        p.delegate = self
        p.discoverServices([PaxUUIDs.serviceUUID, CBUUID(string: "180A")])
    }

    // MARK: - discoverCharacteristics()

    func discoverCharacteristics(for service: CBService) {
        guard let p = connectedPeripheral else { return }
        if service.uuid == PaxUUIDs.serviceUUID {
            p.discoverCharacteristics(
                [PaxUUIDs.readCharUUID, PaxUUIDs.writeCharUUID, PaxUUIDs.notifyCharUUID],
                for: service)
        } else if service.uuid == CBUUID(string: "180A") {
            p.discoverCharacteristics(
                [PaxUUIDs.serialNumberChar, PaxUUIDs.modelNumberChar,
                 PaxUUIDs.firmwareRevChar, PaxUUIDs.manufacturerChar],
                for: service)
        }
    }

    // MARK: - writeCommand()

    func writeCommand(_ data: Data) throws {
        guard let p = connectedPeripheral else { throw PaxError.notConnected }
        guard let wc = writeChar else { throw PaxError.missingCharacteristic("write") }
        let type: CBCharacteristicWriteType =
            writeCharProps.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: wc, type: type)
    }

    // MARK: - handleNotification()
    // Called when the notify characteristic fires; triggers a read of the data characteristic.

    func handleNotification() {
        guard let p = connectedPeripheral, let rc = readChar else { return }
        p.readValue(for: rc)
    }

    // MARK: - Subscriptions / reads

    func subscribeToNotify() {
        guard let p = connectedPeripheral, let nc = notifyChar else { return }
        p.setNotifyValue(true, for: nc)
    }

    func readCharacteristic(_ char: CBCharacteristic) {
        connectedPeripheral?.readValue(for: char)
    }

    var isPoweredOn: Bool { centralManager.state == .poweredOn }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            delegate?.bluetoothDidUpdatePower(available: central.state == .poweredOn)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown"
        let device = ScannedDevice(id: peripheral.identifier, peripheral: peripheral,
                                   name: name, rssi: RSSI.intValue)
        Task { @MainActor in
            delegate?.bluetoothDidDiscover(device: device)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            delegate?.bluetoothDidConnect()
            discoverServices()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let msg = error?.localizedDescription ?? "unknown error"
        Task { @MainActor in
            delegate?.bluetoothDidFailToConnect(error: msg)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let msg = error?.localizedDescription
        Task { @MainActor in
            connectedPeripheral = nil
            readChar = nil
            writeChar = nil
            notifyChar = nil
            writeCharProps = []
            delegate?.bluetoothDidDisconnect(error: msg)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let errMsg = error?.localizedDescription
        Task { @MainActor in
            if let e = errMsg {
                delegate?.bluetoothDidError(e, characteristic: nil)
                return
            }
            guard let p = connectedPeripheral else { return }
            for service in p.services ?? [] {
                delegate?.bluetoothDiscoveredService(service.uuid)
                discoverCharacteristics(for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let errMsg   = error?.localizedDescription
        let svcUUID  = service.uuid
        let charInfo = (service.characteristics ?? []).map { (uuid: $0.uuid, props: $0.properties) }
        Task { @MainActor in
            if let e = errMsg {
                delegate?.bluetoothDidError(e, characteristic: nil)
                return
            }
            guard let p = connectedPeripheral else { return }
            // Re-look up the live CBCharacteristic refs from the peripheral on the MainActor
            let liveService = p.services?.first { $0.uuid == svcUUID }
            let liveChars   = liveService?.characteristics ?? []
            for info in charInfo {
                delegate?.bluetoothDiscoveredCharacteristic(info.uuid, properties: info.props)
                guard let char = liveChars.first(where: { $0.uuid == info.uuid }) else { continue }
                switch info.uuid {
                case PaxUUIDs.readCharUUID:
                    readChar = char
                    p.readValue(for: char)
                case PaxUUIDs.writeCharUUID:
                    writeChar = char
                    writeCharProps = char.properties
                case PaxUUIDs.notifyCharUUID:
                    notifyChar = char
                    p.setNotifyValue(true, for: char)
                case PaxUUIDs.serialNumberChar, PaxUUIDs.modelNumberChar,
                     PaxUUIDs.firmwareRevChar, PaxUUIDs.manufacturerChar:
                    p.readValue(for: char)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let errMsg = error?.localizedDescription
        let uuid   = characteristic.uuid
        let value  = characteristic.value
        Task { @MainActor in
            if let e = errMsg {
                delegate?.bluetoothDidError(e, characteristic: uuid)
                return
            }
            guard let data = value else { return }
            if uuid == PaxUUIDs.notifyCharUUID {
                // The notify value is just a "data ready" indicator (commonly 1 byte
                // that mirrors the first byte of the queued read). Never parse it —
                // only use it to trigger a read of the data characteristic.
                handleNotification()
            } else {
                delegate?.bluetoothDidRead(characteristic: uuid, data: data)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let errMsg     = error?.localizedDescription
        let uuid       = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        Task { @MainActor in
            if let e = errMsg {
                delegate?.bluetoothDidError(e, characteristic: uuid)
                return
            }
            delegate?.bluetoothNotifyStateChanged(characteristic: uuid, isNotifying: isNotifying)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let errMsg = error?.localizedDescription
        let uuid   = characteristic.uuid
        Task { @MainActor in
            if let e = errMsg {
                delegate?.bluetoothDidError(e, characteristic: uuid)
                return
            }
            delegate?.bluetoothDidWrite(characteristic: uuid)
        }
    }

    nonisolated func peripheralDidUpdateName(_ peripheral: CBPeripheral) {}
}

// MARK: - Helpers

func formatProperties(_ props: CBCharacteristicProperties) -> String {
    var parts: [String] = []
    if props.contains(.read)                 { parts.append("read") }
    if props.contains(.write)                { parts.append("write") }
    if props.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
    if props.contains(.notify)               { parts.append("notify") }
    if props.contains(.indicate)             { parts.append("indicate") }
    if props.contains(.broadcast)            { parts.append("broadcast") }
    return parts.joined(separator: ",")
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
