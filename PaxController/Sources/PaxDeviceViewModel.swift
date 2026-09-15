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
    /// True while the radio is actually scanning. There is no Scan button, so
    /// this runs by itself whenever we are disconnected; it is tracked apart
    /// from `connectionState` because a pending auto-connect ("Waiting for
    /// PAX…") and a scan are live at the same time.
    @Published private(set) var isScanning = false
    /// Set only by the Disconnect button. Nothing else stops the app from
    /// finding and connecting to the device on its own.
    @Published private(set) var automationPaused = false

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
    /// True while `probeUndecodedAttributes` is collecting samples.
    @Published private(set) var probeInProgress = false

    // MARK: Remembered device (auto-connect)
    @Published private(set) var rememberedDeviceName: String?

    // MARK: LED capability, discovered from the device
    /// Attribute IDs the device reported via SupportedAttributes (0x18).
    @Published private(set) var supportedAttributes: Set<UInt8> = []
    /// The theme the device last reported, used as the template for a write so
    /// each mode's animation and frequency are preserved rather than invented.
    @Published private(set) var deviceColorTheme: PaxColorTheme?
    /// The device's physical shell colour (attribute 0x1C) — hardware identity,
    /// read only. It is not where the LED colour lives.
    @Published private(set) var shellColorIndex: UInt8?
    /// LED brightness, 0…1. The wire value is 0…128.
    @Published private(set) var ledBrightness: Double?
    /// Haptic amplitude, 0…1, read only for now — see applyHapticReport.
    @Published private(set) var hapticAmplitude: Double?
    /// Everything the device reported for HapticMode, so a future write can
    /// preserve the fields whose meaning is still unknown.
    private var hapticRawPayload: Data?
    /// The write we are waiting to confirm by reading the attribute back.
    private var pendingLedWrite: (attribute: UInt8, payload: Data)?
    /// Send the saved colour as soon as we learn the device can accept one.
    private var pushColorOnceDiscovered = false
    /// True once the device has answered the capability query, which is what
    /// separates "we do not know yet" from "this firmware cannot do it".
    private var capabilitiesKnown = false
    /// Coalesces colour-wheel drags into a single write.
    private var ledWriteDebounce: Task<Void, Never>?
    /// Same, for the brightness slider.
    private var brightnessDebounce: Task<Void, Never>?
    /// Same, for the haptics slider.
    private var hapticDebounce: Task<Void, Never>?
    /// The amplitude byte we are waiting to see reported back.
    private var pendingHapticWrite: UInt8?
    /// The name we are waiting to see reported back.
    private var pendingNameWrite: String?
    /// Deadline for that read-back.
    private var renameVerification: Task<Void, Never>?
    /// The name the device reports through DisplayName (0x0A).
    @Published private(set) var reportedName: String?
    /// The name from Generic Access, which is also what it advertises.
    @Published private(set) var gapName: String?
    /// The name in the advertisement the scan saw.
    @Published private(set) var advertisedName: String?
    /// Raw payloads collected during an attribute probe, keyed by attribute.
    private var probeSamples: [UInt8: [Data]] = [:]
    /// Where the current heat-up started, so the warm-up ramp measures the
    /// climb rather than the whole temperature scale.
    private var warmUpStartTempC: Double?
    #if PAX_LAB
    /// Debounces automatic capture while the device settles into a state.
    private var labAutoCapture: Task<Void, Never>?
    #endif
    /// The last ramp colour written, so an unchanged step writes nothing.
    private var lastWarmUpHex: String?
    private var probeTask: Task<Void, Never>?
    /// Deadline for the capability query, so a silent device still gets a colour.
    private var capabilityTimeout: Task<Void, Never>?
    /// The device never answered the capability query, so any write is a guess.
    private var capabilityQueryUnanswered = false

    /// Whether the device will accept an LED colour. ColorTheme is the only
    /// writable one — ShellColor just states which colour the casing is.
    var deviceLedColorSupported: Bool {
        deviceColorTheme != nil
            || supportedAttributes.contains(PaxMessageType.colorTheme.rawValue)
            || capabilityQueryUnanswered
    }

    // MARK: Private
    private let bluetooth = BluetoothManager()
    private let settings = AppSettings.shared
    private var sessionKey: SymmetricKey?
    private var serialReady = false
    private var pendingCommands: [() throws -> Void] = []
    private var pollTimer: AnyCancellable?
    /// A scan reports each peripheral once and iOS suppresses the repeats. A
    /// PAX that is switched off and on again during one scan can therefore go
    /// unreported for as long as that scan lasts, which is what makes it look
    /// like the app cannot see a device that is plainly advertising. Restarting
    /// the scan on a slow cycle clears the suppression.
    private var rescanTimer: AnyCancellable?
    /// Armed when the scan sees the very device a pending connect is waiting
    /// for: proof that it is advertising, so a request that still has not
    /// landed shortly afterwards is stale rather than merely patient.
    private var pendingConnectWatchdog: Task<Void, Never>?
    /// Polls sent since the device last answered. A PAX switched off at the
    /// button can leave iOS holding the link open for half a minute before the
    /// supervision timeout fires, and the app spends that time showing a
    /// connection that is already gone — and, worse, not looking for the
    /// device coming back. Counted in polls rather than measured in seconds
    /// because the timer does not fire while the app is suspended: elapsed time
    /// would read as silence after any spell in the background.
    private var unansweredPolls = 0
    /// Guards the handshake itself. A connect that lands but never finishes —
    /// stale GATT handles after a power cycle are the usual reason — leaves the
    /// app sitting in `.discoveringServices` for good, since every recovery
    /// path keys off being disconnected.
    private var connectWatchdog: Task<Void, Never>?
    /// Distinguishes "the user tapped Disconnect" from "the device went away",
    /// because only the latter should re-arm the auto-reconnect.
    private var userInitiatedDisconnect = false

    /// Screenshot fixture switch. Launch arguments land in UserDefaults'
    /// argument domain, so this is unreachable in normal use - nothing in the
    /// UI sets the key.
    private let demoMode = UserDefaults.standard.bool(forKey: "uiDemo")

    /// One instance for the whole process. An App Intent fired from the Lock
    /// Screen or from Siri runs in the app — possibly launched into the
    /// background for it, with no window on screen — so it needs a view model
    /// that exists without a view having asked for one.
    static let shared = PaxDeviceViewModel()

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

    private func startScan() {
        guard bluetooth.isPoweredOn else {
            log("Bluetooth not ready", level: .warn)
            return
        }
        guard !isScanning else { return }
        scannedDevices.removeAll()
        isScanning = true
        // A failed connect leaves its message in `connectionState`; since the
        // retry is automatic, the message would otherwise sit on screen for
        // good while the app was already looking again.
        switch connectionState {
        case .idle, .error: connectionState = .scanning
        default:            break
        }
        bluetooth.scan()
        scheduleRescan()
        log("Scanning for PAX devices…", level: .info)
    }

    /// Restarts the scan periodically. Nothing is logged: this is housekeeping,
    /// and at this interval it would drown the log it is meant to explain.
    private func scheduleRescan() {
        rescanTimer?.cancel()
        rescanTimer = Timer.publish(every: 12, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isScanning, !self.connectionState.isConnected else { return }
                self.bluetooth.stopScan()
                self.bluetooth.scan()
            }
    }

    private func stopScan() {
        guard isScanning else { return }
        bluetooth.stopScan()
        rescanTimer?.cancel()
        rescanTimer = nil
        isScanning = false
        if case .scanning = connectionState { connectionState = .idle }
        log("Scan stopped", level: .info)
    }

    func connect(to device: ScannedDevice) {
        stopScan()
        // An auto-connect for this same device may already be pending or even
        // just completed; issuing a second connect gives one session two
        // discovery passes and duplicate traffic.
        if bluetooth.connectedPeripheral?.identifier == device.id,
           connectionState.isConnected || connectionState == .connecting
            || connectionState == .discoveringServices || connectionState == .awaitingSerial
            || connectionState == .waitingForDevice {
            log("Already connecting to \(device.name) — ignoring the duplicate request", level: .info)
            return
        }
        automationPaused = false
        connectionState = .connecting
        advertisedName = device.name
        bluetooth.connect(to: device)
        armConnectWatchdog()
        log("Connecting to \(device.name) [\(device.id)]", level: .info)
    }

    /// Stops and stays stopped. Everything else — launch, power-on, the device
    /// walking out of range — is handled without the user, so a disconnect that
    /// the user asked for has to suppress the automation or it would undo
    /// itself within the second.
    func disconnect() {
        userInitiatedDisconnect = true
        automationPaused = true
        connectionState = .disconnecting
        stopScan()
        bluetooth.disconnect()
        LiveActivityController.shared.end()
        log("Disconnecting… — auto-connect paused until you reconnect", level: .info)
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
        guard settings.autoConnectEnabled, !automationPaused else { return }
        guard !connectionState.isConnected, !demoMode else { return }
        guard let id = Self.storedDeviceID else { return }

        // A pending connect for this device is already armed. iOS holds it
        // until the PAX shows up, so re-issuing it would do nothing except
        // trip the warning below, which only means "iOS has never seen it".
        if bluetooth.connectedPeripheral?.identifier == id {
            if connectionState == .idle { connectionState = .waitingForDevice }
            return
        }

        guard let device = bluetooth.autoConnect(toKnownIdentifier: id) else {
            log("Auto-connect: iOS no longer knows device \(id) — the running scan will re-pair it", level: .warn)
            return
        }
        connectionState = .waitingForDevice
        log("Auto-connect armed for \(device.name) — will connect whenever it is in range", level: .info)
        refreshLiveActivity()
    }

    /// The app carries no Scan button: discovery is continuous while we are
    /// disconnected, and the first PAX it turns up is connected to without a
    /// tap. Call this on launch, on radio power-on and whenever the app comes
    /// back to the foreground.
    func resumeAutomation() {
        guard !demoMode else { return }
        automationPaused = false
        attemptAutoConnect()
        startDiscoveryIfDisconnected()
    }

    /// Foreground pass: picks discovery back up where iOS suspended it, but
    /// leaves a disconnect the user asked for alone.
    func resumeDiscoveryIfIdle() {
        guard !automationPaused else { return }
        attemptAutoConnect()
        startDiscoveryIfDisconnected()
    }

    /// Scans, unless a connection is already underway. A pending auto-connect
    /// runs alongside: it is the only path that survives backgrounding, while
    /// the scan is what finds a PAX this app has never seen.
    private func startDiscoveryIfDisconnected() {
        guard !demoMode, !automationPaused else { return }
        switch connectionState {
        case .idle, .scanning, .waitingForDevice, .error:
            startScan()
        case .connecting, .discoveringServices, .awaitingSerial, .ready, .disconnecting:
            break
        }
    }

    /// With no Scan button there is no Connect button either. A remembered
    /// device wins over a stranger, so a second PAX in the room cannot take
    /// the session — that one stays in the list for a tap.
    private func autoConnectToDiscovered(_ device: ScannedDevice) {
        guard settings.autoConnectEnabled, !automationPaused, !demoMode else { return }
        switch connectionState {
        case .idle, .scanning, .waitingForDevice, .error: break
        default: return
        }
        if let remembered = Self.storedDeviceID, device.id != remembered {
            log("Found \(device.name), but \(rememberedDeviceName ?? "another PAX") is the remembered device — tap to use this one", level: .info)
            return
        }
        if connectionState == .waitingForDevice {
            armPendingConnectWatchdog(for: device)
            return
        }
        log("Auto-connecting to \(device.name)", level: .info)
        connect(to: device)
    }

    /// The pending connect deserves first refusal: iOS holds it below the app
    /// and it survives backgrounding, which a scan does not. But a request the
    /// system quietly dropped looks exactly like one that is still waiting, and
    /// it never recovers on its own — so once the device is seen advertising,
    /// the request has a few seconds to make good on it.
    private func armPendingConnectWatchdog(for device: ScannedDevice) {
        guard pendingConnectWatchdog == nil else { return }
        log("\(device.name) is advertising while a reconnect is pending", level: .ble)
        pendingConnectWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingConnectDidGoStale(device)
        }
    }

    private func armConnectWatchdog() {
        connectWatchdog?.cancel()
        connectWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connectDidStall()
        }
    }

    private func connectDidStall() {
        connectWatchdog = nil
        switch connectionState {
        case .connecting, .discoveringServices, .awaitingSerial: break
        default: return
        }
        log("Stuck at \(connectionState.displayString) for 15 s — starting over", level: .warn)
        bluetooth.cancelPendingConnect()
        resetDeviceState()
        connectionState = .idle
        attemptAutoConnect()
        startDiscoveryIfDisconnected()
    }

    private func pendingConnectDidGoStale(_ device: ScannedDevice) {
        pendingConnectWatchdog = nil
        guard connectionState == .waitingForDevice else { return }
        log("The pending reconnect never landed — connecting to \(device.name) directly", level: .warn)
        bluetooth.cancelPendingConnect()
        connectionState = .idle
        connect(to: device)
    }

    /// Forgetting has to stop the automation too. Clearing the stored device on
    /// its own achieves nothing: the scan is always running, and with nothing
    /// remembered the first PAX it finds is adopted — which is the same one,
    /// a second later. The app stays off the air until the user taps Connect,
    /// and whatever it connects to then becomes the new remembered device.
    func forgetRememberedDevice() {
        UserDefaults.standard.removeObject(forKey: Self.deviceIDKey)
        UserDefaults.standard.removeObject(forKey: Self.deviceNameKey)
        rememberedDeviceName = nil
        automationPaused = true
        userInitiatedDisconnect = true
        stopScan()
        scannedDevices.removeAll()
        pendingConnectWatchdog?.cancel()
        pendingConnectWatchdog = nil
        connectWatchdog?.cancel()
        connectWatchdog = nil
        // Disconnects a live session and withdraws a pending request alike.
        let wasConnected = connectionState.isConnected
        bluetooth.cancelPendingConnect()
        connectionState = wasConnected ? .disconnecting : .idle
        LiveActivityController.shared.end()
        log("Forgot the device — nothing will connect until you tap Connect", level: .info)
    }

    private func rememberCurrentDevice() {
        guard let id = bluetooth.connectedPeripheral?.identifier else { return }
        let name = deviceLabel
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
        scheduleLedWrite()
    }

    /// Re-sends whatever the settings currently describe, without touching the
    /// app's accent: the accent follows the single colour, not the four
    /// per-mode ones. Used by the per-mode pickers and by "Send now".
    func resendLedColors() {
        guard settings.pushColorToDevice else { return }
        guard connectionState.isConnected else {
            pushColorOnceDiscovered = true
            log("LED colours saved — they will be sent as soon as the PAX connects", level: .info)
            return
        }
        scheduleLedWrite()
    }

    private func scheduleLedWrite() {
        // Dragging the colour wheel fires on every frame. Coalesce into one
        // write per gesture so the link is not flooded — short enough that a
        // tap on a preset still lands immediately.
        ledWriteDebounce?.cancel()
        ledWriteDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.sendLedColorToDevice()
        }
    }

    /// The theme the user's settings currently describe: one colour across all
    /// four modes, or a pair per mode. Either way the animation and frequency
    /// bytes come from what the device reported, never from us.
    private var themeFromSettings: PaxColorTheme {
        settings.perModeLedColors
            ? PaxColorTheme.perMode(settings.modeColorPairs,
                                    fallback: settings.ledColor,
                                    basedOn: deviceColorTheme)
            : PaxColorTheme.solid(settings.ledColor, basedOn: deviceColorTheme)
    }

    private func sendLedColorToDevice() {
        let color = settings.ledColor
        guard deviceLedColorSupported else {
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
        let theme = themeFromSettings
        let payload = theme.payload
        pendingLedWrite = (PaxMessageType.colorTheme.rawValue, payload)
        enqueue {
            try self.sendPacket(PaxPacket.setLedColor(attribute: .colorTheme, payload: payload))
            let what = self.settings.perModeLedColors ? "per-mode colours" : color.hex
            self.log("Wrote colorTheme for \(what) — \(theme.summary)", level: .tx)
            // writeWithoutResponse can never ACK, so read it back to find out
            // whether the device took it.
            try self.sendPacket(PaxPacket.statusRequest(attributes: [.colorTheme]))
        }
    }

    // MARK: - Device name

    /// The name to show. The device's own report wins; failing that Generic
    /// Access, then what it advertises, then a name the user set that this
    /// firmware would not take, and finally the model.
    var deviceLabel: String {
        reportedName ?? gapName ?? advertisedName ?? settings.deviceNickname ?? modelNumber ?? "PAX"
    }

    /// Whether a rename can reach the device at all, rather than only being
    /// kept by the app.
    var canRenameDevice: Bool {
        bluetooth.deviceNameWritable || supportedAttributes.contains(PaxMessageType.displayName.rawValue)
    }

    /// DisplayName (0x0A) is documented as a length byte then UTF-8, but a
    /// device is free to answer with a plain NUL-padded string, and this PAX 3
    /// answers the attribute not at all. Accept either shape rather than
    /// discarding a name because its first byte was a letter.
    private func applyDisplayNameReport(_ packet: PaxPacket) {
        let payload = packet.payload
        guard !payload.isEmpty else { return }
        log("DisplayName raw: \(Data(payload.prefix(20)).hexString)", level: .rx)

        var parsed: String?
        let declared = Int(payload[payload.startIndex])
        if declared > 0, payload.count >= 1 + declared,
           let name = String(bytes: payload[(payload.startIndex + 1)..<(payload.startIndex + 1 + declared)],
                             encoding: .utf8),
           name.allSatisfy({ !$0.isNewline }) {
            parsed = name
        } else {
            // No usable length byte: read it as text up to the first NUL.
            let bytes = Array(payload.prefix(while: { $0 != 0 }))
            parsed = String(bytes: bytes, encoding: .utf8)
        }
        guard let name = parsed?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        reportedName = name
        displayName = deviceLabel
        judgeRename(against: name, source: "DisplayName")
    }

    /// Renames the PAX. Generic Access' Device Name is tried first when the
    /// device allows writing it, since that is the name it advertises and the
    /// one iOS and every other app will show. Otherwise the vendor attribute
    /// gets a go. Either way the name is read back rather than assumed, and if
    /// nothing takes it the app says so and keeps the name for itself.
    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("Not renaming: a name cannot be empty", level: .warn)
            return
        }
        guard connectionState.isConnected else {
            settings.deviceNickname = trimmed
            displayName = deviceLabel
            log("Not connected — \"\(trimmed)\" is the name this app will use", level: .info)
            return
        }

        pendingNameWrite = trimmed
        renameVerification?.cancel()

        if bluetooth.writeDeviceName(trimmed) {
            log("Renaming over Generic Access → \"\(trimmed)\"", level: .tx)
        } else if let packet = PaxPacket.setDisplayName(trimmed) {
            enqueue {
                try self.sendPacket(packet)
                self.log("Renaming over DisplayName (0x0A) → \"\(trimmed)\"", level: .tx)
                try self.sendPacket(PaxPacket.statusRequest(attributes: [.displayName]))
            }
        } else {
            pendingNameWrite = nil
            return
        }

        // Nothing here acknowledges a write, and this firmware does not answer
        // DisplayName at all, so silence has to be treated as failure rather
        // than waited on for ever.
        renameVerification = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.renameDidNotStick(trimmed)
        }
    }

    private func judgeRename(against reported: String, source: String) {
        guard let wanted = pendingNameWrite else { return }
        guard reported == wanted else {
            log("✘ \(source) still reports \"\(reported)\" — the rename did not take", level: .warn)
            return
        }
        pendingNameWrite = nil
        renameVerification?.cancel()
        renameVerification = nil
        // It stuck on the device, so the app has no reason to keep its own.
        settings.deviceNickname = nil
        log("✔ Device accepted the new name \"\(wanted)\" (\(source))", level: .info)
    }

    private func renameDidNotStick(_ wanted: String) {
        renameVerification = nil
        guard pendingNameWrite == wanted else { return }
        pendingNameWrite = nil
        settings.deviceNickname = wanted
        displayName = deviceLabel
        log("This firmware never reported the name back, so the rename did not reach the device. \"\(wanted)\" is the name this app will use.",
            level: .warn)
        refreshLiveActivity()
    }

    // MARK: - Heating state

    private func heatingStateDidChange(from previous: PaxHeatingState?) {
        #if PAX_LAB
        labAutoCaptureIfNeeded()
        #endif
        if settings.notifyWhenReady {
            ReadyNotifier.shared.handle(state: heatingState,
                                        targetC: targetTempC ?? currentTargetTempC,
                                        useFahrenheit: settings.useFahrenheit)
        }
        switch heatingState {
        case .heating:
            // Where this heat-up started from, so the ramp is a fraction of the
            // climb rather than of the whole scale — a PAX picked up warm
            // should not sit on green all the way. Often nil at this point,
            // since the state usually arrives before the first temperature
            // does; `updateWarmUpColor` latches it as soon as one turns up.
            warmUpStartTempC = actualTempC
            lastWarmUpHex = nil
            updateWarmUpColor()
        default:
            guard previous == .heating else { break }
            warmUpStartTempC = nil
            // Put the configured heating colours back now the ramp is over,
            // otherwise the next warm-up starts from wherever it left off.
            if lastWarmUpHex != nil, settings.pushColorToDevice {
                lastWarmUpHex = nil
                scheduleLedWrite()
            }
        }
    }

    /// While the oven is warming up, the heating state's colour follows the
    /// thermometer: green at the start, yellow halfway, orange as it arrives.
    /// The PAX cannot do this itself — its own animation runs on a timer, not
    /// on the temperature — so the app writes the colour as the reading
    /// climbs, in steps big enough that a 0.1° wobble cannot start a write.
    private func updateWarmUpColor() {
        guard settings.warmUpGradient, settings.pushColorToDevice else { return }
        guard heatingState == .heating, deviceLedColorSupported else { return }
        guard let actual = actualTempC,
              let target = targetTempC ?? currentTargetTempC, target > 0 else { return }

        // Latch the baseline here rather than only when the state changes. The
        // heating report routinely arrives before the first temperature does,
        // and `warmUpStartTempC ?? actual` then re-based the ramp on every
        // reading — progress came out zero every time, which is why it sat on
        // green for the whole heat-up.
        if warmUpStartTempC == nil { warmUpStartTempC = actual }
        let start = warmUpStartTempC ?? actual
        let span = target - start
        // A heat-up that starts within a degree of the set point has no ramp
        // worth drawing.
        guard span > 1 else { return }
        let raw = (actual - start) / span
        // Twelve steps: about a write every few seconds over a normal heat-up.
        let stepped = (min(1, max(0, raw)) * 12).rounded(.down) / 12
        let color = LedColor.warmUp(progress: stepped)
        guard color.hex != lastWarmUpHex else { return }
        lastWarmUpHex = color.hex

        var theme = themeFromSettings
        theme.setColors(.heating, color1: color, color2: color)
        let payload = theme.payload
        enqueue {
            try self.sendPacket(PaxPacket.setLedColor(attribute: .colorTheme, payload: payload))
        }
        log(String(format: "Warm-up %d%% → %@ (%.1f of %.1f→%.1f)",
                   Int(stepped * 100), color.hex, actual, start, target), level: .tx)
    }

    // MARK: - Attribute probe

    /// Reads the attributes nobody has decoded, several times each, and reports
    /// what the reads agree on.
    ///
    /// The plaintext past an attribute's real payload is uninitialised buffer
    /// that differs on every read, so a single sample cannot say where the
    /// payload ends — which is why those attributes are logged one byte at a
    /// time today. Three reads of the same attribute differ only in that noise,
    /// so the bytes they share are the payload. Nothing is written to the
    /// device: every one of these is a read.
    func probeUndecodedAttributes() {
        guard connectionState.isConnected, !probeInProgress else { return }
        probeInProgress = true
        probeSamples = [:]
        log("Probing \(Self.probeAttributeIDs.count) attributes — reading each three times so the payload separates from the padding",
            level: .info)
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            for _ in 0..<3 {
                guard let self, !Task.isCancelled else { return }
                self.enqueue {
                    try self.sendPacket(PaxPacket.statusRequest(rawAttributes: Self.probeAttributeIDs))
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self?.finishProbe()
        }
    }

    /// Everything this firmware answers but the app cannot read, plus the
    /// log and pod attributes it does not advertise — asking costs nothing and
    /// silence is itself an answer.
    static let probeAttributeIDs: [UInt8] = [
        0x09, 0x0F, 0x11, 0x19, 0x1A, 0x1B, 0x1E,   // advertised, undecoded
        0x04, 0x05, 0x12, 0x24, 0x29, 0x2A,         // usage, logs, session, pod
    ]

    private func recordProbeSample(type: UInt8, payload: Data) {
        guard Self.probeAttributeIDs.contains(type) else { return }
        probeSamples[type, default: []].append(payload)
    }

    private func finishProbe() {
        probeInProgress = false
        probeTask = nil
        let answered = probeSamples.keys.sorted()
        guard !answered.isEmpty else {
            log("Probe: the device answered none of them", level: .warn)
            return
        }
        let silent = Self.probeAttributeIDs.filter { probeSamples[$0] == nil }
        for id in answered {
            let samples = probeSamples[id] ?? []
            let name = PaxMessageType(rawValue: id).map { " \($0)" } ?? " (unnamed)"
            let stable = Self.commonPrefix(of: samples)
            let label = String(format: "0x%02X", id) + name
            if stable.isEmpty {
                log("Probe \(label): \(samples.count) reads agreed on nothing — the payload may be empty",
                    level: .rx)
            } else {
                log("Probe \(label): \(stable.count)-byte payload \(stable.hexString)\(Self.interpretation(of: stable, id: id)) (\(samples.count) reads agreed)",
                    level: .info)
            }
        }
        if !silent.isEmpty {
            let list = silent.map { String(format: "0x%02X", $0) }.joined(separator: " ")
            log("Probe: no answer for \(list) — this firmware does not implement them", level: .info)
        }
    }

    /// The longest prefix every sample shares. With three reads of a stable
    /// value, that is the payload and nothing else.
    private static func commonPrefix(of samples: [Data]) -> Data {
        guard var shortest = samples.first else { return Data() }
        for sample in samples.dropFirst() {
            var length = 0
            while length < min(shortest.count, sample.count),
                  shortest[shortest.startIndex + length] == sample[sample.startIndex + length] {
                length += 1
            }
            shortest = Data(shortest.prefix(length))
        }
        return shortest
    }

    /// Plausible readings of a payload whose meaning is still open, so the log
    /// carries the numbers rather than leaving them to be worked out by hand.
    /// These are suggestions, not decodings.
    static func interpretation(of payload: Data, id: UInt8) -> String {
        var notes: [String] = []
        if payload.count == 1 {
            notes.append("\(payload[payload.startIndex]) as a byte")
        }
        if payload.count >= 2, payload.count % 2 == 0 {
            let words = stride(from: 0, to: payload.count, by: 2).map { i -> String in
                let value = UInt16(payload[payload.startIndex + i])
                    | (UInt16(payload[payload.startIndex + i + 1]) << 8)
                // Temperatures ride the wire as °C × 10 everywhere else.
                return String(format: "%d (%.1f°C?)", value, Double(value) / 10)
            }
            notes.append("LE 16-bit: " + words.joined(separator: ", "))
        }
        if payload.count == 4 {
            let epoch = UInt32(payload[payload.startIndex])
                | (UInt32(payload[payload.startIndex + 1]) << 8)
                | (UInt32(payload[payload.startIndex + 2]) << 16)
                | (UInt32(payload[payload.startIndex + 3]) << 24)
            let date = Date(timeIntervalSince1970: TimeInterval(epoch))
            // Confirmed on hardware: the device's clock advances in step with
            // real seconds, whatever absolute date it happens to be set to.
            notes.append(id == PaxMessageType.time.rawValue
                         ? "device clock \(date), \(epoch) seconds"
                         : "LE 32-bit: \(epoch)")
        }
        return notes.isEmpty ? "" : " — " + notes.joined(separator: "; ")
    }

    #if PAX_LAB
    // MARK: - Lab

    /// Reads every attribute the protocol can address, several times over.
    /// The status request is a 64-bit bitfield, so 1…63 is the whole space;
    /// asking in batches rather than all at once keeps the device from
    /// answering sixty times in one breath.
    func labSweep(rounds: Int = 3, captureAs state: String? = nil) {
        guard connectionState.isConnected, !PaxLab.shared.sweepInProgress else { return }
        PaxLab.shared.setSweeping(true)
        // Start from nothing: samples carried over from the last sweep would be
        // compared against this state's, and any attribute that had changed
        // would agree on nothing and drop out of the snapshot entirely — which
        // is exactly the attribute worth capturing.
        PaxLab.shared.forgetSamples()
        log("Lab: sweeping every attribute, \(rounds) rounds", level: .info)
        Task { [weak self] in
            for round in 1...rounds {
                for batch in stride(from: 1, through: 63, by: 8) {
                    guard let self, !Task.isCancelled else { return }
                    let ids = Array(UInt8(batch)...UInt8(min(63, batch + 7)))
                    self.enqueue {
                        try self.sendPacket(PaxPacket.statusRequest(rawAttributes: ids))
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                self?.log("Lab: sweep round \(round) sent", level: .info)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            self?.finishLabSweep(captureAs: state)
        }
    }

    private func finishLabSweep(captureAs state: String?) {
        PaxLab.shared.setSweeping(false)
        if let state {
            // The PAX may have moved on while the sweep was running — a
            // heat-up can finish inside those twelve seconds — and a snapshot
            // labelled with a state it was no longer in would be worse than no
            // snapshot at all. The new state triggers its own.
            if labStateKey == state {
                PaxLab.shared.captureState(state)
                log("Lab: captured \"\(state)\"", level: .info)
            } else {
                log("Lab: \(state) ended before the sweep did — not captured", level: .info)
            }
        }
        let answered = PaxLab.shared.answeredAttributes
        log("Lab: \(answered.count) attributes answered — \(answered.map { String(format: "0x%02X", $0) }.joined(separator: " "))",
            level: .info)
    }

    /// Attributes the lab will not write, whatever is typed.
    ///
    /// The PAX is a heating element and a lithium cell, and the only attribute
    /// that can aim either of them somewhere unsafe is the set point — so it
    /// is set through the normal control, which stays inside the range the
    /// device documents, and never from here. The encryption attributes are
    /// the other two: garbage written there could leave a session this app
    /// cannot re-establish, which is the one failure a power cycle might not
    /// undo.
    static let labUnwritableAttributes: [UInt8: String] = [
        0x02: "HeaterSetPoint aims the heater. Use the dial, which stays inside the documented range.",
        0x1F: "CurrentTargetTemp is the heater's working set point. Use the dial.",
        0x31: "EncryptionExchange could leave a session that cannot be re-established.",
        0x32: "EncryptionPacket could leave a session that cannot be re-established.",
    ]

    /// Writes an arbitrary attribute. This is the dangerous one, and the
    /// reason this build exists: it is written to the lab's log before it
    /// leaves, so a payload that takes the device offline is still on record
    /// when the app comes back.
    func labWrite(attribute: UInt8, payload: Data) {
        guard connectionState.isConnected else { return }
        if let reason = Self.labUnwritableAttributes[attribute] {
            log(String(format: "Lab: refusing to write 0x%02X — %@", attribute, reason), level: .warn)
            return
        }
        // Recorded before the write so the value can be put back afterwards,
        // including after a power cycle.
        let previous = PaxLab.shared.stable(attribute)
        PaxLab.shared.noteWrite(attribute: attribute, payload: payload, previous: previous)
        enqueue {
            try self.sendRawPlaintext(Data([attribute]) + payload)
            self.log(String(format: "Lab: wrote 0x%02X ← %@", attribute, PaxLab.hex(payload)), level: .tx)
            try self.sendPacket(PaxPacket.statusRequest(rawAttributes: [attribute]))
        }
    }

    /// How the device is described for capture purposes: what the oven is
    /// doing, and whether it is on the charger.
    var labStateKey: String {
        let state = heatingState?.description.lowercased() ?? "unknown"
        return isCharging == true ? "\(state) · charging" : "\(state) · unplugged"
    }

    /// Sweeps and captures the moment the PAX enters a state that has not been
    /// captured yet, so the comparison builds itself out of ordinary use.
    func labAutoCaptureIfNeeded() {
        guard PaxLab.shared.autoCapture, connectionState.isConnected else { return }
        guard heatingState != nil, !PaxLab.shared.sweepInProgress else { return }
        let state = labStateKey
        guard !PaxLab.shared.hasCaptured(state) else { return }
        labAutoCapture?.cancel()
        labAutoCapture = Task { [weak self] in
            // Let it settle: the device passes through states on its way to
            // the one it means, and sweeping each of them would sweep for ever.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.labStateKey == state else { return }
            self.log("Lab: new state \"\(state)\" — sweeping to capture it", level: .info)
            self.labSweep(captureAs: state)
        }
    }

    func labRead(attribute: UInt8) {
        guard connectionState.isConnected else { return }
        enqueue {
            try self.sendPacket(PaxPacket.statusRequest(rawAttributes: [attribute]))
        }
    }

    /// The type byte and payload, encrypted as they are. `sendPacket` cannot
    /// carry an attribute this app has no name for.
    private func sendRawPlaintext(_ plaintext: Data) throws {
        guard let key = sessionKey else { throw PaxError.notConnected }
        let data = try PaxCrypto.encrypt(plaintext: plaintext, key: key)
        try bluetooth.writeCommand(data)
    }

    var labDeviceSummary: String {
        [modelNumber.map { "Model \($0)" },
         firmwareRevision.map { "firmware \($0)" },
         serialNumber.map { "serial \($0)" },
         gapName.map { "GAP name \($0)" },
         "GAP name writable: \(bluetooth.deviceNameWritable)"]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
    #endif

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
                if automationPaused { return "Disconnected" }
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
            deviceName: connectionState.isConnected ? deviceLabel
                : (rememberedDeviceName ?? settings.deviceNickname ?? "PAX"),
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
            let attrs: [PaxMessageType] = [
                .supportedAttribs, .colorTheme, .shellColor,
                .brightness, .hapticMode, .uiMode, .lowSoCMode,
            ]
            try self.sendPacket(PaxPacket.statusRequest(attributes: attrs))
            self.log("Asked the device which attributes it supports, and for its current settings", level: .tx)
        }
        // Not every firmware implements SupportedAttributes. Without a deadline
        // a device that simply never answers would leave the colour queued for
        // ever, which is worse than the blind write it replaced.
        capabilityTimeout?.cancel()
        capabilityTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.capabilityQueryDidTimeOut()
        }
    }

    private func capabilityQueryDidTimeOut() {
        guard !capabilitiesKnown, connectionState.isConnected else { return }
        capabilityQueryUnanswered = true
        capabilitiesKnown = true
        log("No capability reply after 2 s — this firmware may not implement SupportedAttributes (0x18). Falling back to an unverified ColorTheme write.",
            level: .warn)
        pushSavedColorIfReady()
    }

    func requestFullStatus() {
        enqueue {
            // ChargeStatus belongs here: read once at connect it was whatever
            // the PAX happened to be doing then, so putting it on the charger
            // never changed the headline and the heating state showed through
            // instead.
            let attrs: [PaxMessageType] = [
                .actualTemp, .heaterSetPoint, .battery,
                .heatingState, .lockStatus, .dynamicMode,
                .currentTargetTemp, .chargeStatus, .displayName
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

    // MARK: - App Intents

    /// Hands the intents a way in. Called once from the app's initialiser, so
    /// it is set even on a launch that never shows a window.
    func installIntentHandlers() {
        PaxIntentBridge.setTemperature = { [weak self] celsius in
            self?.setCustomTemperature(Double(celsius))
        }
        PaxIntentBridge.setDynamicMode = { [weak self] raw in
            guard let mode = PaxDynamicMode(rawValue: raw) else { return }
            self?.setDynamicMode(mode)
        }
        PaxIntentBridge.statusSummary = { [weak self] in
            self?.spokenStatus ?? "The PAX is not connected"
        }
    }

    /// What Siri reads back. Deliberately a sentence rather than the terse
    /// headline the Lock Screen card uses.
    var spokenStatus: String {
        guard connectionState.isConnected else { return "The PAX is not connected" }
        var parts: [String] = []
        if let actual = actualTempC {
            parts.append("\(Int(actual.rounded())) degrees")
        }
        if let target = targetTempC, target != actualTempC {
            parts.append("set to \(Int(target.rounded()))")
        }
        if let state = heatingState { parts.append(state.description.lowercased()) }
        if let battery = batteryLevel { parts.append("battery \(battery) percent") }
        guard !parts.isEmpty else { return "The PAX is connected" }
        return "The PAX is " + parts.joined(separator: ", ")
    }

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
        unansweredPolls = 0
        guard let key = sessionKey else {
            log("RX [no key yet] \(data.hexString)", level: .warn)
            return
        }
        // One read is one packet, however long: the trailing 16 bytes are the
        // IV for the whole ciphertext. Treating a 64-byte read as two 32-byte
        // packets decrypted the second half against the wrong IV, which is why
        // every long read used to log as an unknown type — they were really
        // ColorTheme reports being thrown away.
        guard data.count >= 32, data.count % 16 == 0 else {
            log("RX ignoring \(data.count)B (not a 16-byte multiple of at least 32) raw=\(data.hexString)", level: .warn)
            return
        }
        decodeChunk(data, key: key)
    }

    private func decodeChunk(_ chunk: Data, key: SymmetricKey) {
        do {
            let (packet, plaintext) = try PaxPacket.decode(data: chunk, key: key)
            let typeHex = String(packet.type.rawValue, radix: 16, uppercase: true)
            log("RX 0x\(typeHex) [\(packet.type)] plain=\(plaintext.hexString)", level: .rx)
            if probeInProgress { recordProbeSample(type: packet.type.rawValue, payload: packet.payload) }
            #if PAX_LAB
            PaxLab.shared.record(type: packet.type.rawValue, payload: packet.payload)
            #endif
            applyPacket(packet)
        } catch PaxError.decryptionFailed(let msg) {
            log("RX decrypt failed: \(msg) raw=\(chunk.hexString)", level: .error)
        } catch PaxError.unknownMessageType(let t, let plaintext) {
            let tHex = String(t, radix: 16, uppercase: true)
            #if PAX_LAB
            PaxLab.shared.record(type: t, payload: Data(plaintext.dropFirst()))
            #endif
            if probeInProgress {
                recordProbeSample(type: t, payload: Data(plaintext.dropFirst()))
                log("RX 0x\(tHex) unnamed — probe sample \(plaintext.hexString)", level: .rx)
            } else {
                log("RX 0x\(tHex) unknown type (ignored)", level: .rx)
            }
        } catch {
            log("RX error: \(error.localizedDescription)", level: .error)
        }
    }

    private func applyPacket(_ packet: PaxPacket) {
        switch packet.type {
        case .actualTemp:
            actualTempC = packet.temperatureCelsius
            updateWarmUpColor()
        case .heaterSetPoint:
            targetTempC = packet.temperatureCelsius
            if let t = packet.temperatureCelsius {
                customTargetTempC = min(215, max(180, t))
            }
        case .battery:
            batteryLevel = packet.batteryLevel
            log("Battery: \(packet.batteryLevel.map { "\($0)%" } ?? "nil")", level: .info)
        case .chargeStatus:
            let charging = (packet.payload.count >= 1 && packet.payload[packet.payload.startIndex] != 0)
            if charging != isCharging {
                isCharging = charging
                #if PAX_LAB
                labAutoCaptureIfNeeded()
                #endif
            }
        case .heatingState:
            let previousHeatingState = heatingState
            heatingState = packet.heatingState
            if heatingState != previousHeatingState {
                heatingStateDidChange(from: previousHeatingState)
            }
        case .lockStatus:
            isLocked = packet.lockState
        case .dynamicMode:
            dynamicMode = packet.dynamicMode
        case .currentTargetTemp:
            currentTargetTempC = packet.temperatureCelsius
        case .displayName:
            applyDisplayNameReport(packet)
        case .supportedAttribs:
            applySupportedAttributes(packet)
        case .colorTheme, .shellColor:
            applyLedAttributeReport(packet)
        case .brightness:
            if let raw = packet.payload.first {
                let value = min(1, Double(raw) / PaxMessageType.amplitudeMax)
                if ledBrightness != value {
                    ledBrightness = value
                    log("LED brightness: \(Int(value * 100))% (\(raw)/128)", level: .info)
                }
            }
        case .hapticMode:
            applyHapticReport(packet)
        case .uiMode, .lowSoCMode, .gameMode, .heaterRanges, .heatingParams, .time:
            // Supported by this firmware but not yet decoded. Plaintext past the
            // payload is uninitialised buffer, not zero padding, so log only the
            // first byte — dumping more just prints noise that looks like data.
            if let first = packet.payload.first {
                log("\(packet.type): 0x\(String(format: "%02X", first))", level: .rx)
            }
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

    /// The official app writes HapticMode as a single amplitude byte, but this
    /// firmware reports six. Rather than write a shorter payload than the
    /// device sends — the mistake that took it offline over ColorTheme — read
    /// it, keep the raw bytes, and leave writing alone until the remaining
    /// fields are understood.
    private func applyHapticReport(_ packet: PaxPacket) {
        guard let amplitude = packet.payload.first else { return }
        // Only the first byte is known to mean anything, and the bytes past the
        // real payload are uninitialised buffer that differs on every read — so
        // the amplitude, not the whole blob, decides whether this is news.
        let raw = Data(packet.payload.prefix(6))
        let isNew = hapticRawPayload?.first != amplitude
        hapticRawPayload = raw
        hapticAmplitude = min(1, Double(amplitude) / PaxMessageType.amplitudeMax)

        if let pending = pendingHapticWrite {
            pendingHapticWrite = nil
            if pending == amplitude {
                log("✔ Device accepted haptics \(Int((hapticAmplitude ?? 0) * 100))% (\(amplitude)/128)", level: .info)
            } else {
                log("✘ Device ignored the haptics write — still reports \(amplitude)/128", level: .warn)
            }
            return
        }
        if isNew {
            log("Haptics: amplitude \(Int((hapticAmplitude ?? 0) * 100))% (\(amplitude)/128), first 6 bytes \(raw.hexString)",
                level: .info)
        }
    }

    /// Sets haptic strength. One byte, 0…128, the same scale as brightness and
    /// the same payload the official app writes — deliberately not an echo of
    /// the longer value this firmware reports back, since the bytes past the
    /// payload are uninitialised buffer and writing them back would be writing
    /// noise into fields nobody has decoded.
    func setHapticAmplitude(_ fraction: Double) {
        let clamped = min(1, max(0, fraction))
        hapticAmplitude = clamped
        guard connectionState.isConnected else { return }
        let raw = UInt8((clamped * PaxMessageType.amplitudeMax).rounded())
        hapticDebounce?.cancel()
        hapticDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.enqueue {
                guard let self else { return }
                self.pendingHapticWrite = raw
                try self.sendPacket(PaxPacket(type: .hapticMode, payload: Data([raw])))
                self.log("Set haptics → \(Int(clamped * 100))% (\(raw)/128)", level: .tx)
                try self.sendPacket(PaxPacket.statusRequest(attributes: [.hapticMode]))
            }
        }
    }

    /// Sets LED brightness. One byte, 0…128, confirmed by the device reporting
    /// 0x80 for full brightness.
    func setLedBrightness(_ fraction: Double) {
        let clamped = min(1, max(0, fraction))
        ledBrightness = clamped
        guard connectionState.isConnected else { return }
        let raw = UInt8(( clamped * PaxMessageType.amplitudeMax).rounded())
        brightnessDebounce?.cancel()
        brightnessDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.enqueue {
                guard let self else { return }
                // Two bytes, as the official app writes it: the level and a
                // command byte, which it leaves at zero.
                try self.sendPacket(PaxPacket(type: .brightness, payload: Data([raw, 0])))
                self.log("Set LED brightness → \(Int(clamped * 100))% (\(raw)/128)", level: .tx)
                try self.sendPacket(PaxPacket.statusRequest(attributes: [.brightness]))
            }
        }
    }

    /// Names from the official app's ShellColors enum.
    static func shellColorLabel(_ index: UInt8) -> String {
        shellColorName(index) ?? String(format: "0x%02X", index)
    }

    private static func shellColorName(_ index: UInt8) -> String? {
        switch index {
        case 0: return "Onyx Black"
        case 1: return "Silver"
        case 2: return "Rose Gold"
        case 3: return "Sage Teal"
        case 4: return "Burgundy"
        default: return nil
        }
    }

    private func pushSavedColorIfReady() {
        guard pushColorOnceDiscovered, deviceLedColorSupported else { return }
        pushColorOnceDiscovered = false
        let what = settings.perModeLedColors
            ? "per-mode LED colours"
            : "saved LED colour \(settings.ledColor.name) (\(settings.ledColor.hex))"
        log("Applying \(what) now that the device is ready", level: .info)
        sendLedColorToDevice()
    }

    /// The device reporting its current LED value is the only reliable source
    /// for the payload's length and encoding, so record it verbatim.
    private func applyLedAttributeReport(_ packet: PaxPacket) {
        // A value arriving for an attribute the bitfield did not list still
        // proves the device implements it.
        capabilitiesKnown = true

        // ShellColor is the casing's own colour, not a setting.
        guard packet.type == .colorTheme else {
            if let index = packet.payload.first, shellColorIndex != index {
                // The documented enum only runs 0…4. This PAX 3 answers 0xE5,
                // so report the byte rather than inventing a colour for it.
                if let name = Self.shellColorName(index) {
                    shellColorIndex = index
                    log("Shell colour: \(name)", level: .info)
                } else {
                    shellColorIndex = nil
                    log("ShellColor reported 0x\(String(format: "%02X", index)), outside the documented 0…4 range — ignoring it",
                        level: .warn)
                }
            }
            pushSavedColorIfReady()
            return
        }

        let reported = Data(packet.payload.prefix(PaxColorTheme.payloadSize))
        guard let theme = PaxColorTheme(payload: reported) else {
            log("ColorTheme payload did not parse: \(reported.hexString)", level: .warn)
            pushSavedColorIfReady()
            return
        }
        let previous = deviceColorTheme
        deviceColorTheme = theme

        // Judge this report against any write already outstanding *before*
        // starting a new one — pushing first would compare the fresh write
        // against the old value that just arrived and always cry foul.
        if let pending = pendingLedWrite, pending.attribute == packet.type.rawValue {
            pendingLedWrite = nil
            if theme.payload == pending.payload {
                log("✔ Device accepted colorTheme — \(theme.summary)", level: .info)
            } else {
                log("✘ Device ignored the colorTheme write — still reports \(theme.summary)", level: .warn)
            }
        } else if previous != theme {
            log("Current colorTheme (\(theme.modes.count) modes): \(theme.summary)", level: .info)
        }

        pushSavedColorIfReady()
    }

    private func checkReady() {
        guard paxServiceConfirmed, serialReady else { return }
        // Service discovery can complete more than once for a single session —
        // a pending auto-connect and a manual tap both landing, say — and
        // running the ready sequence again re-sends every capability request.
        guard connectionState != .ready else { return }
        log("PAX service confirmed + serial ready — entering ready state", level: .info)
        if settings.notifyWhenReady { ReadyNotifier.shared.requestAuthorizationIfNeeded() }
        displayName = deviceLabel
        #if PAX_LAB
        // The state it is in when the app finds it counts too.
        labAutoCaptureIfNeeded()
        #endif
        connectWatchdog?.cancel()
        connectWatchdog = nil
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
        unansweredPolls = 0
        pollTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.unansweredPolls += 1
                self.failOverIfSilent()
                self.requestFullStatus()
            }
    }

    /// A working device answers every poll within a few hundred milliseconds,
    /// so seven in a row unanswered means the link is dead whatever iOS still
    /// says. Tearing it down here starts the reconnect instead of waiting on a
    /// supervision timeout that may be another 20 s away.
    private func failOverIfSilent() {
        guard connectionState.isConnected, unansweredPolls >= 7 else { return }
        log("No reply to the last \(unansweredPolls) status requests — dropping the link and looking for the PAX again", level: .warn)
        unansweredPolls = 0
        bluetooth.disconnect()
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
        reportedName = nil
        gapName = nil
        renameVerification?.cancel()
        renameVerification = nil
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
        deviceColorTheme = nil
        shellColorIndex = nil
        ledBrightness = nil
        hapticAmplitude = nil
        hapticRawPayload = nil
        brightnessDebounce?.cancel()
        brightnessDebounce = nil
        hapticDebounce?.cancel()
        hapticDebounce = nil
        pendingHapticWrite = nil
        pendingNameWrite = nil
        probeTask?.cancel()
        probeTask = nil
        probeInProgress = false
        probeSamples.removeAll()
        warmUpStartTempC = nil
        lastWarmUpHex = nil
        ReadyNotifier.shared.reset()
        pendingLedWrite = nil
        pushColorOnceDiscovered = false
        capabilitiesKnown = false
        capabilityQueryUnanswered = false
        ledWriteDebounce?.cancel()
        ledWriteDebounce = nil
        capabilityTimeout?.cancel()
        capabilityTimeout = nil
        pendingConnectWatchdog?.cancel()
        pendingConnectWatchdog = nil
        connectWatchdog?.cancel()
        connectWatchdog = nil
        unansweredPolls = 0
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
            // iOS drops every pending connect with the radio, so the reconnect
            // that was armed is gone; power-on re-arms it from scratch.
            isScanning = false
            rescanTimer?.cancel()
            rescanTimer = nil
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
        autoConnectToDiscovered(device)
    }

    func bluetoothDidConnect() {
        log("Connected — discovering services…", level: .ble)
        // A pending auto-connect can complete while a scan is still running;
        // the radio has no reason to keep looking now.
        stopScan()
        pendingConnectWatchdog?.cancel()
        pendingConnectWatchdog = nil
        // A pending auto-connect never went through the scan list, so this is
        // the first chance to learn what the device calls itself.
        advertisedName = bluetooth.advertisedName ?? advertisedName
        // Covers the pending-connect path too, which reaches this point without
        // ever going through `connect(to:)`.
        armConnectWatchdog()
        connectionState = .discoveringServices
    }

    func bluetoothDidFailToConnect(error: String) {
        log("Failed to connect: \(error)", level: .error)
        connectionState = .error(error)
        // Nothing in the UI retries, so the automation has to: go straight back
        // to looking for the device rather than leaving the error on screen.
        // The failed peripheral is still held as the pending connect, so drop
        // it first or the re-arm below is a no-op.
        bluetooth.cancelPendingConnect()
        attemptAutoConnect()
        startDiscoveryIfDisconnected()
    }

    func bluetoothDidDisconnect(error: String?) {
        #if PAX_LAB
        PaxLab.shared.noteDisconnect()
        #endif
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
        startDiscoveryIfDisconnected()
        refreshLiveActivity()
    }

    /// iOS relaunched the app in the background for a device that is not
    /// connected. `BluetoothManager` has already re-issued the request.
    #if PAX_LAB
    func bluetoothLabFoundCharacteristic(service: CBUUID, characteristic: CBUUID,
                                         properties: CBCharacteristicProperties) {
        let key = "1 \(service.uuidString) \(characteristic.uuidString) a"
        PaxLab.shared.recordGatt(
            key: key,
            line: "\(service.uuidString) / \(characteristic.uuidString) [\(formatProperties(properties))]")
    }

    func bluetoothLabReadValue(service: CBUUID, characteristic: CBUUID, data: Data) {
        // The PAX data characteristic carries encrypted packets that the
        // attribute sweep already decodes; its raw ciphertext says nothing.
        guard characteristic != PaxUUIDs.readCharUUID else { return }
        let text = String(data: data, encoding: .utf8)
            .flatMap { $0.allSatisfy { !$0.isNewline && $0.asciiValue ?? 0 >= 32 } ? " \"\($0)\"" : nil } ?? ""
        PaxLab.shared.recordGatt(
            key: "1 \(service.uuidString) \(characteristic.uuidString) b",
            line: "    value \(data.hexString)\(text)")
    }

    func bluetoothLabReadDescriptor(characteristic: CBUUID, descriptor: CBUUID, value: String) {
        PaxLab.shared.recordGatt(
            key: "2 \(characteristic.uuidString) \(descriptor.uuidString)",
            line: "    \(characteristic.uuidString) descriptor \(descriptor.uuidString) = \(value)")
    }

    func bluetoothLabSawAdvertisement(_ description: String) {
        PaxLab.shared.recordAdvertisement(description)
    }

    func bluetoothLabLogServiceReady() {
        log("Lab: the device has a log service — asking it for its session history", level: .info)
        labFetchLogs(from: 0, offset: 0)
    }

    /// Asks for the next batch. The official app walks the log by repeating
    /// this with the timestamp of the last event it saw, and stops when a read
    /// comes back empty.
    func labFetchLogs(from timestamp: UInt32, offset: UInt8) {
        guard connectionState.isConnected else { return }
        enqueue {
            try self.sendPacket(PaxPacket.logSyncRequest(timestamp: timestamp, offset: offset))
        }
    }

    func bluetoothLabLogEvents(_ data: Data) {
        guard !data.isEmpty else {
            log("Lab: the session log has been read to the end — \(PaxLab.shared.logEvents.count) events",
                level: .info)
            return
        }
        var events: [PaxLogEvent] = []
        var index = data.startIndex
        while index + PaxLogEvent.size <= data.endIndex {
            if let event = PaxLogEvent(data[index..<(index + PaxLogEvent.size)]) {
                events.append(event)
            }
            index += PaxLogEvent.size
        }
        guard let last = events.last else { return }
        PaxLab.shared.recordLogEvents(events)
        log("Lab: \(events.count) log events, newest \(last.description)", level: .rx)
        // Walk on from the last event seen. The offset skips the events that
        // share that timestamp, so a second's worth is not read twice for ever.
        let offset = UInt8(min(255, events.filter { $0.time == last.time }.count))
        labFetchLogs(from: last.time, offset: offset)
    }
    #endif

    func bluetoothRestoredPendingConnect(name: String) {
        log("iOS restored the session for \(name) — reconnect re-armed", level: .ble)
        guard !connectionState.isConnected else { return }
        connectionState = .waitingForDevice
        refreshLiveActivity()
    }

    func bluetoothReadyForAutoConnect() {
        guard !automationPaused else { return }
        attemptAutoConnect()
        startDiscoveryIfDisconnected()
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

        case PaxUUIDs.deviceNameChar:
            let name = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return }
            gapName = name
            displayName = deviceLabel
            log("Device name (Generic Access): \(name)\(bluetooth.deviceNameWritable ? " — writable" : " — read only")",
                level: .ble)
            judgeRename(against: name, source: "Generic Access")

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
