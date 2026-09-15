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
    /// Fired once the radio is powered on, before any auto-connect attempt is
    /// made, so the view model can decide whether to try reconnecting to the
    /// last-known device.
    func bluetoothReadyForAutoConnect()
    /// iOS relaunched the app with a peripheral that is not connected. The
    /// connect has been re-issued; nothing will happen until the PAX shows up.
    func bluetoothRestoredPendingConnect(name: String)
    #if PAX_LAB
    /// Everything the device exposes, not only the handful this app uses.
    func bluetoothLabFoundCharacteristic(service: CBUUID, characteristic: CBUUID,
                                         properties: CBCharacteristicProperties)
    /// A characteristic's value, whether or not this app knows what it means.
    func bluetoothLabReadValue(service: CBUUID, characteristic: CBUUID, data: Data)
    /// A descriptor — 0x2901 is a human-readable name the vendor left behind.
    func bluetoothLabReadDescriptor(characteristic: CBUUID, descriptor: CBUUID, value: String)
    /// The whole advertisement, which carries state the device broadcasts
    /// without anyone having to connect to it.
    func bluetoothLabSawAdvertisement(_ description: String)
    /// The log service is present and its notify characteristic is subscribed.
    func bluetoothLabLogServiceReady()
    /// A batch of log events, or empty when there are none left.
    func bluetoothLabLogEvents(_ data: Data)
    #endif
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
    /// Generic Access' Device Name, when the device exposes it.
    private var deviceNameChar: CBCharacteristic?
    #if PAX_LAB
    private var logReadChar: CBCharacteristic?
    var hasLogService: Bool { logReadChar != nil }
    #endif

    /// Whether this device lets the name be written over Generic Access. Most
    /// do not; the ones that do are the only place a rename can actually stick
    /// without the vendor's own attribute answering.
    var deviceNameWritable: Bool {
        guard let props = deviceNameChar?.properties else { return false }
        return props.contains(.write) || props.contains(.writeWithoutResponse)
    }

    /// The name the device advertises, which is what the scan list shows.
    var advertisedName: String? { connectedPeripheral?.name }

    override init() {
        super.init()
        // A restore identifier lets iOS relaunch the app into the background
        // (via state restoration) when a BLE event happens while the app is
        // suspended or not running in the foreground — the basis for staying
        // connected while backgrounded / the phone is locked. It cannot
        // survive the user force-quitting the app; that stops all background
        // BLE activity for every app, with no API to opt back in.
        centralManager = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "PaxControllerCentral"])
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

    /// Withdraws a pending (timeout-free) connect request so iOS stops waiting
    /// for a device we no longer care about.
    func cancelPendingConnect() {
        guard let p = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(p)
        connectedPeripheral = nil
    }

    /// Auto-connect to a device the app has connected to before, identified
    /// by its CoreBluetooth peripheral UUID. Works whether the device is
    /// already connected to the system (`retrieveConnectedPeripherals`, e.g.
    /// after state restoration) or just previously known to iOS
    /// (`retrievePeripherals(withIdentifiers:)`, which still requires the
    /// device to be in range/advertising to actually connect).
    func autoConnect(toKnownIdentifier id: UUID) -> ScannedDevice? {
        guard centralManager.state == .poweredOn else { return nil }
        // A peripheral left over from an earlier session is not necessarily the
        // one we are after; while it is held, the connect below never happens.
        if let held = connectedPeripheral, held.identifier != id {
            centralManager.cancelPeripheralConnection(held)
            connectedPeripheral = nil
        }
        guard connectedPeripheral == nil else { return nil }

        if let already = centralManager.retrieveConnectedPeripherals(
            withServices: [PaxUUIDs.serviceUUID]).first(where: { $0.identifier == id }) {
            connectedPeripheral = already
            already.delegate = self
            if already.state == .connected {
                discoverServices()
            } else {
                centralManager.connect(already, options: nil)
            }
            return ScannedDevice(id: already.identifier, peripheral: already,
                                 name: already.name ?? "PAX", rssi: 0)
        }

        guard let known = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            return nil
        }
        connectedPeripheral = known
        centralManager.connect(known, options: nil)
        return ScannedDevice(id: known.identifier, peripheral: known,
                             name: known.name ?? "PAX", rssi: 0)
    }

    // MARK: - discoverServices()

    func discoverServices() {
        guard let p = connectedPeripheral else { return }
        p.delegate = self
        #if PAX_LAB
        // nil: everything the device has, including whatever it uses for
        // firmware updates, which this app has never once asked about.
        p.discoverServices(nil)
        #else
        p.discoverServices([PaxUUIDs.serviceUUID,
                            PaxUUIDs.deviceInfoService,
                            PaxUUIDs.genericAccessService])
        #endif
    }

    // MARK: - discoverCharacteristics()

    func discoverCharacteristics(for service: CBService) {
        guard let p = connectedPeripheral else { return }
        #if PAX_LAB
        // Every characteristic of every service. The switch in the discovery
        // callback still picks out the ones the app uses.
        p.discoverCharacteristics(nil, for: service)
        #else
        if service.uuid == PaxUUIDs.serviceUUID {
            p.discoverCharacteristics(
                [PaxUUIDs.readCharUUID, PaxUUIDs.writeCharUUID, PaxUUIDs.notifyCharUUID],
                for: service)
        } else if service.uuid == PaxUUIDs.deviceInfoService {
            p.discoverCharacteristics(
                [PaxUUIDs.serialNumberChar, PaxUUIDs.modelNumberChar,
                 PaxUUIDs.firmwareRevChar, PaxUUIDs.manufacturerChar],
                for: service)
        } else if service.uuid == PaxUUIDs.genericAccessService {
            p.discoverCharacteristics([PaxUUIDs.deviceNameChar], for: service)
        }
        #endif
    }

    /// Writes Generic Access' Device Name, if this device allows it. Returns
    /// false when there is nothing to write to, so the caller can fall back to
    /// the vendor attribute rather than reporting a rename that never left.
    @discardableResult
    func writeDeviceName(_ name: String) -> Bool {
        guard let p = connectedPeripheral, let char = deviceNameChar,
              deviceNameWritable, let data = name.data(using: .utf8) else { return false }
        let type: CBCharacteristicWriteType =
            char.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: char, type: type)
        p.readValue(for: char)
        return true
    }

    #if PAX_LAB
    func readLogEvents() {
        guard let p = connectedPeripheral, let char = logReadChar else { return }
        p.readValue(for: char)
    }
    #endif

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
            let available = central.state == .poweredOn
            // Everything CoreBluetooth vended dies with the radio: the
            // peripheral objects are invalid and every pending connect is
            // dropped. Holding on to one is what makes an auto-connect after a
            // Bluetooth or Airplane-mode toggle look armed when in fact
            // nothing is waiting, and the app then sits at "Waiting for PAX…"
            // for ever.
            if !available { invalidate() }
            delegate?.bluetoothDidUpdatePower(available: available)
            if available {
                delegate?.bluetoothReadyForAutoConnect()
            }
        }
    }

    private func invalidate() {
        connectedPeripheral = nil
        readChar = nil
        writeChar = nil
        notifyChar = nil
        deviceNameChar = nil
        #if PAX_LAB
        logReadChar = nil
        #endif
        writeCharProps = []
    }

    /// Called before `centralManagerDidUpdateState` when iOS relaunches the app
    /// in the background via state restoration (only possible because of the
    /// restore identifier + `bluetooth-central` background mode). Reattaches us
    /// to whatever peripheral was still connected or pending when the app was
    /// suspended, so the session — and the Lock Screen card — carry on without
    /// the user reopening the app.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let peripheral = peripherals.first else { return }
        Task { @MainActor in
            connectedPeripheral = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                delegate?.bluetoothDidConnect()
                discoverServices()
            } else {
                // Restored as disconnected or still pending. Re-issuing is a
                // no-op for a request iOS is already holding, and the only way
                // back for one it dropped — and without it this peripheral
                // would sit in `connectedPeripheral` blocking every later
                // auto-connect attempt.
                centralManager.connect(peripheral, options: nil)
                delegate?.bluetoothRestoredPendingConnect(name: peripheral.name ?? "PAX")
            }
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
        #if PAX_LAB
        let advertisement = advertisementData
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                if let data = value as? Data {
                    return "\(key) = \(data.hexString)"
                }
                if let list = value as? [CBUUID] {
                    return "\(key) = \(list.map(\.uuidString).joined(separator: ", "))"
                }
                if let map = value as? [CBUUID: Data] {
                    return "\(key) = " + map.map { "\($0.key.uuidString): \($0.value.hexString)" }
                        .joined(separator: ", ")
                }
                return "\(key) = \(value)"
            }
            .joined(separator: "\n")
        #endif
        Task { @MainActor in
            delegate?.bluetoothDidDiscover(device: device)
            #if PAX_LAB
            delegate?.bluetoothLabSawAdvertisement(advertisement)
            #endif
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
            deviceNameChar = nil
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
                #if PAX_LAB
                delegate?.bluetoothLabFoundCharacteristic(service: svcUUID,
                                                          characteristic: info.uuid,
                                                          properties: info.props)
                if info.uuid == PaxUUIDs.logReadChar { logReadChar = char }
                if info.uuid == PaxUUIDs.logNotifyChar {
                    p.setNotifyValue(true, for: char)
                    delegate?.bluetoothLabLogServiceReady()
                }
                // 0x2901 is a user description: a name the vendor left in the
                // firmware for whoever came looking.
                p.discoverDescriptors(for: char)
                if info.props.contains(.read) { p.readValue(for: char) }
                // Subscribing is how a stream announces itself; the known
                // notify characteristic is handled by the switch below.
                if info.uuid != PaxUUIDs.notifyCharUUID,
                   info.props.contains(.notify) || info.props.contains(.indicate) {
                    p.setNotifyValue(true, for: char)
                }
                #endif
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
                case PaxUUIDs.deviceNameChar:
                    deviceNameChar = char
                    p.readValue(for: char)
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
        let serviceUUID = characteristic.service?.uuid
        Task { @MainActor in
            if let e = errMsg {
                delegate?.bluetoothDidError(e, characteristic: uuid)
                return
            }
            guard let data = value else { return }
            #if PAX_LAB
            if uuid == PaxUUIDs.logNotifyChar {
                // The notify only says there is something to collect; the
                // events themselves come from LogRead.
                readLogEvents()
                return
            }
            if uuid == PaxUUIDs.logReadChar {
                delegate?.bluetoothLabLogEvents(data)
                return
            }
            delegate?.bluetoothLabReadValue(service: serviceUUID ?? CBUUID(string: "0000"),
                                            characteristic: uuid, data: data)
            #endif
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

    #if PAX_LAB
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil else { return }
        let descriptors = characteristic.descriptors ?? []
        Task { @MainActor in
            guard let p = connectedPeripheral else { return }
            for descriptor in descriptors { p.readValue(for: descriptor) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor descriptor: CBDescriptor,
                                error: Error?) {
        guard error == nil else { return }
        let charUUID = descriptor.characteristic?.uuid
        let uuid = descriptor.uuid
        let text: String
        switch descriptor.value {
        case let string as String:   text = string
        case let number as NSNumber: text = number.stringValue
        case let data as Data:       text = data.hexString
        case let value?:             text = "\(value)"
        case nil:                    text = "—"
        }
        Task { @MainActor in
            guard let charUUID else { return }
            delegate?.bluetoothLabReadDescriptor(characteristic: charUUID,
                                                 descriptor: uuid,
                                                 value: text)
        }
    }
    #endif
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
