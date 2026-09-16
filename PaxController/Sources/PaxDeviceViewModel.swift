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

    // MARK: Remembered device (auto-connect)
    @Published private(set) var rememberedDeviceName: String?

    // MARK: LED capability, discovered from the device
    /// Attribute IDs the device reported via SupportedAttributes (0x18).
    @Published private(set) var supportedAttributes: Set<UInt8> = []
    /// Why the radio is unusable, when it is. Published because a denied
    /// permission is not a transient condition the app can scan its way out
    /// of — it has to be said on screen.
    @Published private(set) var radioState: PaxRadioState = .unknown
    /// The theme the device last reported, used as the template for a write so
    /// each mode's animation and frequency are preserved rather than invented.
    @Published private(set) var deviceColorTheme: PaxColorTheme?
    /// The heating parameters the device last reported, used as the template
    /// for a write so nothing but the field being changed moves. Usually nil:
    /// this firmware advertises HeatingParams (0x19) but has not answered a
    /// read of it in any capture, so writes start from the vendor preset.
    @Published private(set) var deviceHeatingParams: PaxHeatingParams?
    /// Set when the oven stopped within seconds of a HeatingParams write, which
    /// is what this firmware was seen to do. The settings screen turns it into
    /// a warning and a way back rather than leaving the user to guess.
    @Published private(set) var heatingParamsStoppedOven = false
    /// When the last 0x19 write went out, so the stop above can be tied to it.
    private var lastHeatingParamsWrite: Date?
    /// Recent temperature readings, for working out how fast the oven is
    /// climbing. Short on purpose: an average over the last few seconds tracks
    /// a real change, while a longer one smooths it away.
    private var tempTrail: [(at: Date, value: Double)] = []
    /// Every time the battery reading changed, and to what.
    ///
    /// The battery gets a step log rather than a trail because a trail was the
    /// wrong shape for it: the reading moves in quarters and can sit on one
    /// value for the best part of an hour, so any window short enough to follow
    /// a change usually contains no change at all.
    ///
    /// For the same reason it outlives the connection. A change takes the best
    /// part of an hour and the phone drops the link far more often than that,
    /// so a log cleared on disconnect is a log that never accumulates anything
    /// — the first version of this cleared on every disconnect and needed three
    /// changes to say anything, which together meant it would have said nothing
    /// for the rest of the app's life.
    private var batterySteps: [BatteryStep] = [] {
        didSet { saveBatterySteps() }
    }

    struct BatteryStep: Codable {
        let at: Date
        let level: Int
    }

    private static let batteryStepsKey = "batterySteps"
    /// Seconds until the oven reaches its set point, when it is climbing fast
    /// enough for the estimate to mean anything.
    @Published private(set) var secondsToReady: Int?
    /// Seconds until the battery is full, while it is on the charger.
    @Published private(set) var secondsToFull: Int?
    /// The fast lane. One request outstanding at a time, so it cannot outrun
    /// the link.
    private var temperatureLoop: Task<Void, Never>?
    private var lastStateRequestAt: Date = .distantPast
    /// Requests sent and not yet answered. Bounded by `fastLaneWindow`, which
    /// is what stops this becoming the runaway poll it replaced.
    private var outstandingFastRequests = 0
    /// When a reading last arrived, so a stalled loop can be noticed.
    private var lastReadingAt: Date = .distantPast
    /// The last ChargeStatus byte, so a change is logged once rather than on
    /// every poll.
    private var lastChargeByte: UInt8?
    /// When the current draw began, and nil the moment it ends. The dial's ring
    /// measures its growth against this rather than against an animation, so a
    /// long pull keeps widening instead of settling at whatever width an ease
    /// happened to finish on.
    @Published private(set) var drawStartedAt: Date?
    /// The last time the PAX said anything. The waiting card counts up from it,
    /// so a glance says whether it has just stepped out of range or has been
    /// gone all afternoon.
    private var lastSeenAt: Date?
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
    /// How many times the capability bitfield has been asked for on this
    /// connection.
    private var capabilityAttempt = 0
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
    /// Where the current heat-up started, so the warm-up ramp measures the
    /// climb rather than the whole temperature scale.
    private var warmUpStartTempC: Double?
    #if PAX_LAB
    /// Debounces automatic capture while the device settles into a state.
    private var labAutoCapture: Task<Void, Never>?
    #endif
    /// The last ramp colour written, so an unchanged step writes nothing.
    private var lastWarmUpHex: String?
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
    /// The faster, smaller poll behind the dial's movement.
    private var temperatureTimer: AnyCancellable?
    /// Whether anyone is looking. Polling four times a second at a dial nobody
    /// can see is two batteries spent on nothing.
    private var appIsActive = true
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
        loadBatterySteps()
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

        // A session in progress. The time ring is one of the things worth
        // seeing in a screenshot and it has nothing to draw without one: a
        // quarter of an hour in, six draws deep, the last of them just now.
        let started = Date().addingTimeInterval(-14 * 60)
        // The fuse at the ring's leading edge is the auto-off countdown, and it
        // has nothing to count without the timer on. The simulator this runs in
        // has its own defaults, so nothing a real install chose is touched.
        settings.autoOffEnabled = true
        sessionStartedAt = started
        sessionDraws     = 6
        drawMarks        = [70, 205, 360, 520, 690, 815]
        lastDrawAt       = started.addingTimeInterval(815)

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
    /// Foreground and background, from the scene phase.
    func setActive(_ active: Bool) {
        appIsActive = active
        // Coming back to the foreground, ask straight away rather than waiting
        // out whatever the background cadence had left to run.
        if active { scheduleNextTemperatureRequest() }
    }

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
        // The step log is about this battery, so it goes with the device.
        batterySteps.removeAll()
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
        // A 0x19 write on this firmware has been seen to stop the oven. If the
        // oven goes off within a few seconds of one, that is almost certainly
        // the write and not the user, and it is worth saying so plainly.
        if heatingState == .ovenOff, let written = lastHeatingParamsWrite,
           Date().timeIntervalSince(written) < 8 {
            heatingParamsStoppedOven = true
            log("The oven went off \(String(format: "%.1f", Date().timeIntervalSince(written))) s after the heating-parameters write. The block this app sends is the one the official app sends, so this firmware wants a different one — do not write it again until that is known.",
                level: .error)
        }

        // A session is the stretch between the oven waking and going cold. The
        // draw counter, the dose limit, the idle timer and the history all hang
        // off these two transitions.
        switch heatingState {
        case .heating, .ready, .boosting, .cooling:
            beginSession()
            if heatingState == .boosting {
                if previous != .boosting {
                    drawStartedAt = Date()
                    recordDraw()
                }
            } else {
                drawStartedAt = nil
            }
            // Any sign of heat means the app is no longer the reason it is off,
            // whoever turned it back on.
            ovenPoweredOffByApp = false
        case .ovenOff:
            drawStartedAt = nil
            finishSession(pendingEnding ?? .ovenOff)
            pendingEnding = nil
        case .standby:
            drawStartedAt = nil
            // Standby is not an ending — the oven is warm and a draw brings it
            // straight back — but it is where a forgotten session dies, so the
            // idle timer keeps running through it.
            enforceAutoOff()
        case .tempSetMode, .none:
            break
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
            // Before anything about scanning: if the app has been denied the
            // radio, "Waiting for PAX…" is a lie it would tell for ever.
            if let blocked = radioState.headline { return blocked }
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
            phase: livePhase,
            lastSeen: lastSeenAt,
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
        let name = connectionState.isConnected ? deviceLabel
            : (rememberedDeviceName ?? settings.deviceNickname ?? "PAX")
        LiveActivityController.shared.sync(deviceName: name, state: state)
        publishSnapshot(named: name)
    }

    /// The Home Screen widget's copy of all this. Written on the same beat as
    /// the Lock Screen card, and only when something in it actually changed —
    /// a widget reload costs the system a process launch, and the temperature
    /// moving a tenth of a degree is not worth one.
    private func publishSnapshot(named name: String) {
        let today = Calendar.current.startOfDay(for: Date())
        let todays = sessions.sessions(since: today)
        let snapshot = PaxSnapshot(
            isConnected: connectionState.isConnected,
            headline: statusHeadline,
            deviceName: name,
            batteryLevel: batteryLevel,
            isCharging: isCharging ?? false,
            actualTempC: actualTempC?.rounded(),
            targetTempC: targetTempC?.rounded(),
            useFahrenheit: settings.useFahrenheit,
            ledColorHex: settings.ledColorHex,
            updatedAt: Date(),
            sessionsToday: todays.count,
            drawsToday: todays.reduce(0) { $0 + $1.draws })
        // `updatedAt` differs on every call, so compare everything else.
        var comparable = snapshot
        comparable.updatedAt = lastSnapshot?.updatedAt ?? .distantPast
        guard comparable != lastSnapshot else { return }
        lastSnapshot = comparable
        PaxSharedStore.write(snapshot)
        PaxSharedStore.reloadWidgets()
        PhoneLink.shared.push(snapshot, profiles: settings.profiles.map(\.name))
    }

    private var lastSnapshot: PaxSnapshot?

    /// What the Lock Screen card is about, which is not quite the heating state:
    /// the charger outranks the oven, and a PAX that is not there outranks both.
    private var livePhase: PaxActivityAttributes.ContentState.Phase {
        guard connectionState.isConnected else { return .waiting }
        if isCharging == true { return .charging }
        switch heatingState {
        case .heating:     return .heating
        case .ready:       return .ready
        case .boosting:    return .drawing
        case .cooling:     return .cooling
        case .ovenOff:     return .ovenOff
        case .tempSetMode: return .ready
        // Standby, and the first second or two after connecting when the device
        // has not said yet — both are "nothing is happening", which is what the
        // standby card shows.
        case .standby, .none: return .standby
        }
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
        capabilityAttempt = 0
        askForCapabilities()
    }

    /// How many times to ask before deciding the silence means something. The
    /// first ask goes out at the busiest moment of a connection, behind seven
    /// other attributes, and one dropped reply used to cost the whole session
    /// its oven controls.
    private static let capabilityAttempts = 3

    private func askForCapabilities() {
        capabilityAttempt += 1
        let first = capabilityAttempt == 1
        enqueue {
            // The first ask gathers everything worth having at connect. A retry
            // asks for the bitfield on its own: whatever swallowed the reply, a
            // packet expecting eight of them is the least likely to get through.
            let attrs: [PaxMessageType] = first
                ? [.supportedAttribs, .colorTheme, .shellColor,
                   .brightness, .hapticMode, .uiMode, .lowSoCMode, .heatingParams]
                : [.supportedAttribs]
            try self.sendPacket(PaxPacket.statusRequest(attributes: attrs))
            self.log(first
                     ? "Asked the device which attributes it supports, and for its current settings"
                     : "Asking again which attributes the device supports (try \(self.capabilityAttempt))",
                     level: .tx)
        }
        // Not every firmware implements SupportedAttributes. Without a deadline
        // a device that simply never answers would leave the colour queued for
        // ever, which is worse than the blind write it replaced.
        capabilityTimeout?.cancel()
        capabilityTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.capabilityQueryDidTimeOut()
        }
    }

    private func capabilityQueryDidTimeOut() {
        guard !capabilitiesKnown, connectionState.isConnected else { return }
        guard capabilityAttempt >= Self.capabilityAttempts else {
            log("No capability reply after 2.5 s — asking again rather than assuming the answer is no",
                level: .warn)
            askForCapabilities()
            return
        }
        capabilityQueryUnanswered = true
        capabilitiesKnown = true
        log("No capability reply after \(Self.capabilityAttempts) tries — this firmware may not implement SupportedAttributes (0x18). Nothing is disabled on the strength of that: an unanswered question is not a no.",
            level: .warn)
        pushSavedColorIfReady()
    }

    func requestFullStatus() {
        enqueue {
            // ChargeStatus belongs here: read once at connect it was whatever
            // the PAX happened to be doing then, so putting it on the charger
            // never changed the headline and the heating state showed through
            // instead.
            // Temperature, oven state and working target ride their own
            // timers; asking again here would spend the budget twice.
            let attrs: [PaxMessageType] = [
                .heaterSetPoint, .battery, .lockStatus,
                .dynamicMode, .chargeStatus, .displayName
            ]
            let packet = PaxPacket.statusRequest(attributes: attrs)
            try self.sendPacket(packet)
            self.log("Sent STATUS_REQUEST for the slow attributes", level: .tx)
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
            // Whatever the device reported before this is now the old mode's
            // block. Forgetting it means the re-apply below starts from the new
            // mode's preset rather than writing the old mode's temperatures
            // back over the change that was just made.
            self.deviceHeatingParams = nil
        }
        // A Dynamic Mode *is* a block of heating parameters, and the official
        // app writes both attributes for one mode change. This app only ever
        // sent the byte, so whether the mode took at all depended on the
        // firmware filling the block in by itself — which it may not do. Now
        // the block goes with it: `deviceHeatingParams` was just cleared, so
        // the write below starts from the new mode's own preset, carrying the
        // lip choice along rather than losing it.
        //
        // Safe to do unprompted now that the heater bit is known rather than
        // guessed: the block carries it set, so a mode change cannot be what
        // switches the oven off.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.applyLipSettings(reason: "with the \(mode.label) parameters")
        }
    }

    // MARK: - Lip detection

    /// Connected, and the PAX's own service confirmed — the point from which a
    /// write means something. The same condition the control screen greys its
    /// buttons on.
    var canSendCommands: Bool {
        connectionState.isConnected && paxServiceConfirmed
    }

    /// Whether the device implements HeatingParams (0x19) at all.
    ///
    /// The bitfield settles it when there is one. An *empty* bitfield means the
    /// device has not answered the capability query yet, which is not the same
    /// as answering no — treating it as one is what used to make every oven
    /// control on this screen vanish for a whole connection because a single
    /// reply went missing. Offering a write the device turns out to ignore
    /// costs nothing; withholding one it would have honoured costs the feature.
    var canSetLipDetection: Bool {
        guard canSendCommands else { return false }
        return supportedAttributes.isEmpty
            || supportedAttributes.contains(PaxMessageType.heatingParams.rawValue)
    }

    var lipDetectionEnabled: Bool { settings.lipDetectionEnabled }
    var lipCoolingEnabled: Bool { settings.lipCoolingEnabled }
    var lipShutdownEnabled: Bool { settings.lipShutdownEnabled }

    /// The two halves of the lip sensor's hold over the oven.
    ///
    /// The official app groups three option bits under the lip sensor: a boost
    /// while a draw is detected, the cooldown that starts when it stops seeing
    /// one, and the shutdown that follows. On a PAX 3 the first of those is the
    /// heater instead — clearing it is what stopped the oven — so there are two
    /// to offer, not three, and whichever bit the probe identifies as the
    /// heater is held out of every write.
    ///
    /// Cooling and shutdown are worth separating: a water-pipe adapter runs
    /// into the cooldown, while the shutdown is the thing that stops a
    /// forgotten oven running, and someone may well want one without the other.
    func setLipCooling(_ enabled: Bool) {
        settings.lipCoolingEnabled = enabled
        applyLipSettings(reason: "cooldown \(enabled ? "on" : "off")")
    }

    func setLipShutdown(_ enabled: Bool) {
        settings.lipShutdownEnabled = enabled
        applyLipSettings(reason: "auto power-off \(enabled ? "on" : "off")")
    }

    /// Writes the current lip-detection choice, starting from a complete set of
    /// parameters: what the device reported if it ever has, and otherwise the
    /// vendor preset for the mode it is in. Nothing is assembled field by
    /// field, and nothing goes out that fails the plausibility check.
    private func applyLipSettings(reason: String) {
        let mode = dynamicMode ?? .standard
        heatingParamsStoppedOven = false
        writeHeatingParams(composedHeatingParams(ovenOn: true),
                           note: "\(reason), from the \(mode.label) preset")
    }

    /// Which option bit is the heater.
    ///
    /// The official app's own naming says bit 2. It is wrong on this hardware:
    /// every measurement taken on a PAX 3 came back bit 0 — the bit its source
    /// calls `boost` and groups with the lip sensor — and clearing it is the
    /// only thing that ever stopped the oven. The measurement wins over the
    /// naming, so it is written down here as what it turned out to be: a fact
    /// about the hardware rather than a question to put to the user.
    ///
    /// Being wrong about it on some other firmware costs nothing. Clearing
    /// `boost` where the heater lives elsewhere turns off the boost on a draw
    /// and nothing more, and the next write puts it back. There is no failure
    /// here worth making someone run a measurement to avoid.
    private static let heaterBit = PaxHeatingParams.Options.boost

    /// One block, composed the same way for every write: start from what the
    /// device reported if it ever has and otherwise the preset for the mode it
    /// says it is in, keep that preset's own lip bits less whatever the user
    /// switched off, and set the heater to what the caller asked for.
    private func composedHeatingParams(ovenOn: Bool) -> PaxHeatingParams {
        let mode = dynamicMode ?? .standard
        var params = deviceHeatingParams ?? PaxHeatingParams.stock(for: mode)
        params.options.formUnion(PaxHeatingParams.Options.lipDetection)
        params.options.subtract(lipBitsToClear)
        if ovenOn {
            params.options.insert(Self.heaterBit)
            // Bit 2 as well: on a firmware that really does keep the heater
            // where the official app says, this is the bit that matters, and
            // setting both can only ever mean "on".
            params.options.insert(.heater)
        } else {
            params.options.remove(Self.heaterBit)
        }
        return params
    }

    // MARK: - How long until

    /// Least-squares slope over the recent trail, in units per second, or nil
    /// when there is not enough of a trail to say anything.
    private func slope(of trail: [(at: Date, value: Double)]) -> Double? {
        guard trail.count >= 4, let first = trail.first else { return nil }
        let xs = trail.map { $0.at.timeIntervalSince(first.at) }
        let ys = trail.map(\.value)
        let n = Double(trail.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var numerator = 0.0, denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    private func trim(_ trail: inout [(at: Date, value: Double)], seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        trail.removeAll { $0.at < cutoff }
    }

    private func trackTemperature(_ celsius: Double) {
        tempTrail.append((Date(), celsius))
        trim(&tempTrail, seconds: 20)
        updateReadyEstimate()
    }

    private func trackBattery(_ percent: Double) {
        let level = Int(percent.rounded())
        if batterySteps.last?.level != level {
            batterySteps.append(BatteryStep(at: Date(), level: level))
            if batterySteps.count > 60 { batterySteps.removeFirst() }
        }
        updateChargeEstimate()
    }

    private func saveBatterySteps() {
        guard let data = try? JSONEncoder().encode(batterySteps) else { return }
        UserDefaults.standard.set(data, forKey: Self.batteryStepsKey)
    }

    private func loadBatterySteps() {
        guard let data = UserDefaults.standard.data(forKey: Self.batteryStepsKey),
              let steps = try? JSONDecoder().decode([BatteryStep].self, from: data)
        else { return }
        batterySteps = steps
    }

    /// The finest step the battery reading has been seen to take.
    ///
    /// The device reports a percentage, but on this firmware it does not move
    /// by ones — it moves by the four petals it lights. Rather than assert
    /// that, this measures it: the common divisor of every change seen since
    /// the app connected. Nil until enough changes have happened to say.
    var batteryStepSize: Int? {
        guard batterySteps.count >= 3 else { return nil }
        var divisor = 0
        for index in 1..<batterySteps.count {
            divisor = Self.greatestCommonDivisor(
                divisor, abs(batterySteps[index].level - batterySteps[index - 1].level))
        }
        return divisor > 1 ? divisor : nil
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    private func updateReadyEstimate() {
        guard heatingState == .heating,
              let actual = actualTempC,
              let target = targetTempC ?? currentTargetTempC,
              target > actual,
              // Below about a fifth of a degree a second the estimate is mostly
              // noise, and a number that swings by minutes is worse than none.
              let rate = slope(of: tempTrail), rate > 0.2
        else {
            if secondsToReady != nil { secondsToReady = nil }
            return
        }
        let estimate = Int(((target - actual) / rate).rounded())
        // Clamped rather than hidden at the top end: a long estimate early in a
        // cold start is still true.
        let clamped = min(900, max(1, estimate))
        if secondsToReady != clamped { secondsToReady = clamped }
    }

    /// How long until it is full, measured from how long the last steps took.
    ///
    /// The battery attribute is one byte, but it does not move by ones: on this
    /// firmware it moves in quarters, so the readings are a staircase. Fitting
    /// a slope through a staircase gives one of two wrong answers — zero on the
    /// tread, so the estimate disappears for forty minutes at a time, or
    /// something enormous on the riser, so it collapses to a couple of minutes.
    /// That is what the previous version did, and why the number jumped about.
    ///
    /// Timing the steps instead gives one honest estimate per step. It is
    /// coarse, and it says nothing at all until the level has moved twice since
    /// the cable went in, which is the truthful answer to "how long left" when
    /// the device has said one number the whole time.
    private func updateChargeEstimate() {
        guard isCharging == true, let level = batteryLevel, level < 100 else {
            if secondsToFull != nil { secondsToFull = nil }
            return
        }
        // Only the run of rising readings at the end, and only from the last few
        // hours. A step down from before the cable went in says nothing about
        // how fast it fills, and neither does one from a charge last week — the
        // log persists now, so "the end of the list" is no longer the same
        // thing as "since this charge started".
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        var rising: [BatteryStep] = []
        for step in batterySteps.reversed() where step.at >= cutoff {
            if let oldestKept = rising.first, step.level >= oldestKept.level { break }
            rising.insert(step, at: 0)
            if rising.count >= 6 { break }
        }
        guard let first = rising.first, let last = rising.last,
              last.level > first.level
        else {
            if secondsToFull != nil { secondsToFull = nil }
            return
        }
        let seconds = last.at.timeIntervalSince(first.at)
        let gained = Double(last.level - first.level)
        // A step that arrived within a minute of the previous one is the device
        // settling on a reading, not the battery filling that fast.
        guard seconds > 60 else {
            if secondsToFull != nil { secondsToFull = nil }
            return
        }
        let estimate = Int((Double(100 - level) * (seconds / gained)).rounded())
        let clamped = min(6 * 3600, max(60, estimate))
        if secondsToFull != clamped { secondsToFull = clamped }
    }

    /// "4 min", "45s" — short enough to sit under a temperature without
    /// crowding it.
    static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return String(format: "%.1f h", hours)
    }

    // MARK: - Sessions

    private let sessions = PaxSessionStore.shared
    private let charges = PaxChargeStore.shared
    /// When the last draw ended, which is what the idle timer counts from.
    /// Published because the dial counts from it too: the bright segment at the
    /// leading edge of the time ring is what is left of the auto-off window,
    /// and every draw refills it.
    @Published private(set) var lastDrawAt: Date?
    /// The running session, flattened to the handful of values a ring is drawn
    /// from. The store owns the history; these are published so the screen
    /// follows a session without reaching into it on every frame.
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionDraws: Int = 0
    /// When each draw happened, in seconds from the session's start.
    @Published private(set) var drawMarks: [TimeInterval] = []
    /// The charge in progress, the same way: when it started, and when each
    /// ten-percent step was crossed.
    @Published private(set) var chargeStartedAt: Date?
    @Published private(set) var chargeMarks: [TimeInterval] = []
    /// The last sample written to the running session's curve, so samples land
    /// a few seconds apart rather than twice a second.
    private var lastSampleAt: Date?
    /// The step the schedule last applied, so a temperature is written once per
    /// step rather than on every draw.
    private var lastScheduledTemperature: Double?
    /// Set while the app is switching the oven off itself, so the ending that
    /// gets recorded is the real reason rather than "the oven went off".
    private var pendingEnding: PaxSession.Ending?

    /// The session on screen, if one is running.
    var runningSession: PaxSession? { sessions.running }

    /// What the dial's time ring is timing. One lane, two meanings: a session
    /// off the charger, a charge on it. The PAX is never both.
    var dialTiming: DialTiming {
        DialTiming(sessionStartedAt: sessionStartedAt,
                   draws: sessionDraws,
                   drawMarks: drawMarks,
                   lastDrawAt: lastDrawAt,
                   // The fuse at the ring's leading edge is a countdown to the
                   // oven going off. If the app could not switch it off, there
                   // is nothing to count down to and the ring should not say
                   // there is.
                   autoOffEnabled: settings.autoOffEnabled && canPowerOven,
                   autoOffMinutes: settings.autoOffMinutes,
                   chargeStartedAt: chargeStartedAt,
                   chargeMarks: chargeMarks)
    }

    private func beginSession() {
        guard settings.sessionHistoryEnabled || settings.doseLimitEnabled
                || settings.autoOffEnabled || settings.scheduleEnabled else { return }
        guard sessions.running == nil else { return }
        lastDrawAt = nil
        lastSampleAt = nil
        lastScheduledTemperature = nil
        sessions.begin(PaxSession(setPointC: targetTempC, modeRaw: dynamicMode?.rawValue))
        sessionStartedAt = sessions.running?.startedAt
        sessionDraws = 0
        drawMarks = []
        log("Session started", level: .info)
        // A schedule's first step is the one that applies before any draw, and
        // it has to be written now rather than waiting for one.
        applyScheduleIfDue(draws: 0)
    }

    private func finishSession(_ ending: PaxSession.Ending) {
        guard sessions.running != nil else { return }
        sessions.finishRunning(ending)
        log("Session ended: \(ending.label)", level: .info)
        // The dial fades the ring out from whatever shape it had ended on, so
        // these are cleared rather than wound back.
        sessionStartedAt = nil
        sessionDraws = 0
        drawMarks = []
        lastDrawAt = nil
        lastSampleAt = nil
        lastScheduledTemperature = nil
        // A session nobody asked to keep is recorded only so the dose counter
        // and the timer have something to count against, and is dropped here.
        if !settings.sessionHistoryEnabled, let done = sessions.sessions.first {
            sessions.delete(done)
        }
    }

    private func recordDraw() {
        let now = Date()
        lastDrawAt = now
        sessions.updateRunning { $0.draws += 1 }
        let draws = sessions.running?.draws ?? 0
        if let start = sessionStartedAt {
            drawMarks.append(now.timeIntervalSince(start))
        }
        sessionDraws = draws
        log("Draw \(draws)", level: .info)
        applyScheduleIfDue(draws: draws)
        enforceDoseLimit(draws: draws)
    }

    private func recordTemperature(_ celsius: Double) {
        guard let session = sessions.running else { return }
        let now = Date()
        if let last = lastSampleAt, now.timeIntervalSince(last) < PaxSessionStore.sampleInterval {
            // Still worth tracking the peak between samples: the highest point
            // of a session is often between two of them.
            if celsius > (session.peakTempC ?? -.infinity) {
                sessions.updateRunning { $0.peakTempC = celsius }
            }
            return
        }
        lastSampleAt = now
        let offset = now.timeIntervalSince(session.startedAt)
        sessions.updateRunning {
            $0.samples.append(PaxSession.Sample(at: offset, celsius: celsius))
            if celsius > ($0.peakTempC ?? -.infinity) { $0.peakTempC = celsius }
        }
    }

    // MARK: - Charges

    /// A charge is the stretch on the dock, tracked for the same reason a
    /// session is: the device reports a level and a flag, never how long it has
    /// been filling or how fast. The dial's time ring reads this while the PAX
    /// is charging, and the history turns it into a curve.
    private func beginCharge() {
        guard charges.running == nil, let level = batteryLevel else { return }
        let charge = PaxCharge(startLevel: level)
        charges.begin(charge)
        chargeStartedAt = charge.startedAt
        chargeMarks = []
        log("Charge started at \(level)%", level: .info)
    }

    private func finishCharge() {
        guard let running = charges.running else { return }
        charges.finishRunning()
        chargeStartedAt = nil
        chargeMarks = []
        log("Charge ended at \(running.endLevel)% after \(running.durationText)", level: .info)
    }

    /// One mark per ten percent. The step is what stops a wobbling reading
    /// scattering beads around the ring, and it is what makes the spacing
    /// between them mean something: bunched together is a battery drinking,
    /// spread apart is one tapering off near the top.
    private func recordChargeLevel(_ level: Int) {
        guard isCharging == true else { return }
        if charges.running == nil { beginCharge() }
        guard let charge = charges.running else { return }
        let at = Date().timeIntervalSince(charge.startedAt)
        let step = PaxChargeStore.markStep
        let crossed = (level / step) * step
        let already = charge.marks.last?.level ?? ((charge.startLevel / step) * step)
        charges.updateRunning {
            $0.endLevel = max($0.endLevel, level)
            if level >= 100 { $0.reachedFull = true }
            if crossed > already, crossed > $0.startLevel {
                $0.marks.append(PaxCharge.Mark(at: at, level: crossed))
            }
        }
        chargeMarks = charges.running?.marks.map { $0.at } ?? []
    }

    // MARK: - The oven's own rules, on the app's terms

    /// Called from the telemetry path rather than from a timer: the app holds
    /// the connection in the background, where a timer may not fire, but a
    /// reading always arrives. The clock that matters is the one in the data.
    private func enforceAutoOff() {
        guard settings.autoOffEnabled, canPowerOven, let session = sessions.running else { return }
        let limit = TimeInterval(max(1, settings.autoOffMinutes) * 60)
        guard session.idleSeconds(lastDrawAt: lastDrawAt) >= limit else { return }
        log("No draw for \(settings.autoOffMinutes) minutes — switching the oven off", level: .info)
        pendingEnding = .autoOff
        setOvenEnabled(false, reason: "after \(settings.autoOffMinutes) idle minutes")
    }

    private func enforceDoseLimit(draws: Int) {
        guard settings.doseLimitEnabled, canPowerOven else { return }
        guard draws >= max(1, settings.doseLimitDraws) else { return }
        log("Dose reached (\(draws) draws) — switching the oven off", level: .info)
        pendingEnding = .doseLimit
        setOvenEnabled(false, reason: "after \(draws) draws")
    }

    /// Writes the step the session has reached, if it is not already in force.
    private func applyScheduleIfDue(draws: Int) {
        guard settings.scheduleEnabled, settings.schedule.isUsable, sessions.running != nil else { return }
        guard let wanted = settings.schedule.temperature(atDraws: draws) else { return }
        guard wanted != lastScheduledTemperature else { return }
        lastScheduledTemperature = wanted
        log("Schedule: \(draws) draw(s) in, setting \(Int(wanted))°C", level: .info)
        setCustomTemperature(wanted)
    }

    // MARK: - Profiles

    /// Applies a saved profile: the temperature always, the mode and the colour
    /// only where the profile carries them.
    func apply(_ profile: PaxProfile) {
        log("Applying profile \(profile.name): \(profile.summary)", level: .info)
        setCustomTemperature(profile.temperatureC)
        if let raw = profile.modeRaw, let mode = PaxDynamicMode(rawValue: raw) {
            setDynamicMode(mode)
        }
        if let hex = profile.ledHex, let color = LedColor.fromHex(hex) {
            applyLedColor(color)
        }
    }

    // MARK: - Turning the oven off

    /// Whether the app can switch this oven off.
    ///
    /// It used to also require a measurement the user had to go and run, which
    /// meant the button, the idle timer and the dose limit were all withheld
    /// until they did — and withheld again on any connection where one capability
    /// reply went missing. Which bit is the heater is a constant now, so all
    /// that is left to ask is whether the device takes the attribute at all.
    var canPowerOven: Bool { canSetLipDetection }

    /// Whether the app is the reason the oven is off. Cleared as soon as the
    /// device shows any sign of heating again, including from its own button —
    /// the app does not get to believe it is in charge longer than it is.
    @Published private(set) var ovenPoweredOffByApp = false

    /// The one thing the PAX's own app cannot do: switch the oven off from the
    /// phone. Writes the current heating block with the heater bit cleared, and
    /// puts it back to turn it on again.
    func setOvenEnabled(_ on: Bool, reason: String = "from the app") {
        guard canSendCommands else { return }
        heatingParamsStoppedOven = false
        ovenPoweredOffByApp = !on
        // Whatever asked for this gets the credit when the session is written
        // down — the timer, the dose limit, or the button — and the session
        // ends when the oven actually goes off rather than when the write goes
        // out. Closing it here recorded every automatic switch-off as a manual
        // one: the real reason was still sitting in `pendingEnding` while the
        // session it belonged to had already been written down.
        if !on, pendingEnding == nil { pendingEnding = .manual }
        writeHeatingParams(composedHeatingParams(ovenOn: on),
                           note: "oven \(on ? "on" : "off") \(reason)")
    }



    /// Puts the current mode's factory heating parameters back, both lip
    /// behaviours included, and clears the app's memory of the switches. The
    /// way out if a write ever leaves the oven behaving oddly.
    func restoreStockHeatingParams() {
        let mode = dynamicMode ?? .standard
        let params = PaxHeatingParams.stock(for: mode)
        settings.lipCoolingEnabled = true
        settings.lipShutdownEnabled = true
        deviceHeatingParams = nil
        heatingParamsStoppedOven = false
        writeHeatingParams(params, note: "restoring the stock \(mode.label) preset")
    }

    /// Which lip bits a write should clear: the ones whose switch is off.
    ///
    /// The official app groups three bits under the lip sensor and treats all
    /// three as safe to clear. The first of them is this hardware's heater, so
    /// only the other two are ever offered and only they are ever cleared —
    /// which is why nothing here has to be held back any more.
    private var lipBitsToClear: PaxHeatingParams.Options {
        var bits: PaxHeatingParams.Options = []
        if !settings.lipCoolingEnabled  { bits.insert(.noLipCooling) }
        if !settings.lipShutdownEnabled { bits.insert(.noLipShutdown) }
        return bits
    }

    /// One place that actually puts a block on the wire, so every write is
    /// range-checked and logged the same way.
    private func writeHeatingParams(_ params: PaxHeatingParams, note: String) {
        guard params.isPlausible else {
            log("Refusing to write HeatingParams (\(note)): outside the range every stock preset lives in", level: .error)
            return
        }
        lastHeatingParamsWrite = Date()
        enqueue {
            try self.sendPacket(PaxPacket.setHeatingParams(params))
            self.log("HeatingParams write (\(note)): options 0x\(String(format: "%02X", params.options.rawValue)) — \(params.summary)",
                     level: .tx)
        }
    }

    private func applyHeatingParamsReport(_ packet: PaxPacket) {
        guard let params = packet.heatingParams, params.isPlausible else {
            if let first = packet.payload.first {
                log("HeatingParams came back unreadable (first byte 0x\(String(format: "%02X", first))) — writes will start from the stock preset instead",
                    level: .warn)
            }
            return
        }
        guard params != deviceHeatingParams else { return }
        deviceHeatingParams = params
        log("HeatingParams: \(params.summary)", level: .rx)
        // A report is worth everything here — it is the only thing that could
        // settle what this firmware's block actually looks like — but it does
        // not trigger a write. Nothing writes 0x19 without a tap.
        settings.lipCoolingEnabled = params.options.contains(.noLipCooling)
        settings.lipShutdownEnabled = params.options.contains(.noLipShutdown)
        log("The device reports cooldown \(settings.lipCoolingEnabled ? "on" : "off") and auto power-off \(settings.lipShutdownEnabled ? "on" : "off") — the switches now follow it",
            level: .info)
    }

    /// Asks for attributes by number. Read-only — a StatusUpdate request is
    /// the same thing the poll sends — and public so the battery decode can
    /// drive its own rounds without reaching into the queue.
    func requestRawAttributes(_ attributes: [UInt8]) {
        guard canSendCommands else { return }
        enqueue {
            try self.sendPacket(PaxPacket.statusRequest(rawAttributes: attributes))
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
        PaxIntentBridge.setOvenEnabled = { [weak self] on in
            guard let self, self.canPowerOven else { return false }
            self.setOvenEnabled(on, reason: "from a shortcut")
            return true
        }
        PaxIntentBridge.applyProfile = { [weak self] name in
            guard let self else { return nil }
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            // Spoken names come back with the casing and spacing Siri heard, so
            // match loosely rather than making the user say it exactly.
            guard let profile = self.settings.profiles.first(where: {
                $0.name.lowercased() == wanted
            }) ?? self.settings.profiles.first(where: {
                $0.name.lowercased().hasPrefix(wanted)
            }) else { return nil }
            self.apply(profile)
            return "\(profile.name), \(profile.summary)"
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
            LinkBenchmark.shared.note(attribute: packet.type.rawValue)
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
            log("RX 0x\(tHex) unknown type (ignored)", level: .rx)
        } catch {
            log("RX error: \(error.localizedDescription)", level: .error)
        }
    }

    private func applyPacket(_ packet: PaxPacket) {
        lastSeenAt = Date()
        switch packet.type {
        case .actualTemp:
            actualTempC = packet.temperatureCelsius
            updateWarmUpColor()
            if let celsius = packet.temperatureCelsius {
                trackTemperature(celsius)
                recordTemperature(celsius)
            }
            lastReadingAt = Date()
            outstandingFastRequests = max(0, outstandingFastRequests - 1)
            enforceAutoOff()
            // The reply is what asks the next question.
            scheduleNextTemperatureRequest()
        case .heaterSetPoint:
            targetTempC = packet.temperatureCelsius
            if let t = packet.temperatureCelsius {
                customTargetTempC = min(DS.Range.max, max(DS.Range.min, t))
            }
        case .battery:
            batteryLevel = packet.batteryLevel
            if let level = packet.batteryLevel {
                trackBattery(Double(level))
                recordChargeLevel(level)
            }
            log("Battery: \(packet.batteryLevel.map { "\($0)%" } ?? "nil")", level: .info)
        case .chargeStatus:
            // Logged raw as well as interpreted: the byte carries two flags and
            // the app currently only knows that a non-zero one means something
            // is happening on the dock. Seeing the actual values across a full
            // charge is what will separate "charging" from "charged".
            if let flags = packet.chargeFlags, flags.raw != lastChargeByte {
                lastChargeByte = flags.raw
                log("ChargeStatus raw: 0x\(String(format: "%02X", flags.raw)) at \(batteryLevel.map { "\($0)%" } ?? "unknown")",
                    level: .rx)
            }
            let charging = (packet.payload.count >= 1 && packet.payload[packet.payload.startIndex] != 0)
            if charging != isCharging {
                isCharging = charging
                if charging {
                    beginCharge()
                } else {
                    finishCharge()
                }
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
        case .heatingParams:
            applyHeatingParamsReport(packet)
        case .uiMode, .lowSoCMode, .gameMode, .heaterRanges, .time:
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
        // Same as the mode change: the parameters are the device's to keep, and
        // it does not keep this one, so a switch left off has to be re-sent.
        if !settings.lipDetectionEnabled,
           supported.contains(PaxMessageType.heatingParams.rawValue) {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.connectionState.isConnected,
                      !self.settings.lipDetectionEnabled else { return }
                self.applyLipSettings(reason: "on connect")
            }
        }
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
                // The whole six bytes, with the amplitude swapped in — not one
                // byte on its own.
                //
                // The device reports six (80 04 02 04 01 00) and only the first
                // is known to be the amplitude. A one-byte write asks the
                // firmware to interpret a short payload, and the two ways it
                // could do that are "change byte 0" and "take this as the whole
                // block and zero the rest", which would silently wipe five
                // settings nobody has decoded. The same trap HeatingParams is
                // already documented against: never write part of a block
                // without sending back what was read.
                let payload: Data
                if let known = self.hapticRawPayload, known.count >= 6 {
                    payload = Data([raw]) + known.dropFirst()
                } else {
                    payload = Data([raw])
                }
                try self.sendPacket(PaxPacket(type: .hapticMode, payload: payload))
                self.log("Set haptics → \(Int(clamped * 100))% (\(raw)/128) payload=\(payload.hexString)", level: .tx)
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
        // The link, not the timer, is the limit. Every attribute comes back as
        // its own notification and read, and this device delivers about eight a
        // second — measured at a 120 ms median. Asking for more than that does
        // not make the dial smoother, it makes a queue: four requests a second
        // for three attributes each is twelve a second against a budget of
        // eight, and the readings then arrive in bursts seconds apart.
        //
        // So the three polls are sized to fit inside that budget, about half of
        // it: the temperature alone twice a second, what the oven is doing every
        // two, and everything else every six.
        pollTimer?.cancel()
        unansweredPolls = 0
        pollTimer = Timer.publish(every: 6, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.unansweredPolls += 1
                self.failOverIfSilent()
                self.requestFullStatus()
                self.nudgeTemperatureLoopIfStalled()
            }
        // The fast lane is a loop rather than a timer, started once here and
        // kept turning by its own replies.
        temperatureTimer?.cancel()
        temperatureTimer = nil
        lastStateRequestAt = .distantPast
        outstandingFastRequests = 0
        BluetoothManager.linkStats.reset()
        scheduleNextTemperatureRequest()
    }

    /// Restarts the fast lane if a reply never came. The loop is driven by
    /// arrivals, so a dropped reply would otherwise end it silently; this is the
    /// one timer left, and it exists only to notice that nothing is happening.
    private func nudgeTemperatureLoopIfStalled() {
        guard connectionState.isConnected else { return }
        guard Date().timeIntervalSince(lastReadingAt) > 4 else { return }
        log("No reading for \(Int(Date().timeIntervalSince(lastReadingAt)))s — restarting the fast lane", level: .warn)
        outstandingFastRequests = 0
        scheduleNextTemperatureRequest()
    }

    /// The floor on how often the oven is asked for its temperature while it is
    /// working — not the rate, the *floor*. The rate is whatever the link turns
    /// out to sustain, because the next request goes out when the last reply
    /// lands rather than on a schedule.
    ///
    /// A previous version set the rate from one afternoon's measurement written
    /// into a constant: two readings a second, on the reasoning that the device
    /// answered about eight attributes a second and the polls should fit inside
    /// half of that. It fixed the symptom it was written for — three timers
    /// between them asking for more than the link could carry, so replies
    /// arrived in bursts seconds apart — but it made the guess into the ceiling.
    /// A closed loop cannot over-ask by construction: there is never more than
    /// one request outstanding, so it runs at exactly the rate the link allows
    /// and no faster.
    private static let temperatureFloor: TimeInterval = 0.06
    /// How often the oven's state and working target are asked for. They change
    /// in steps rather than continuously, so they ride the slow lane, and they
    /// take a turn in the loop rather than competing with it from a timer.
    private static let stateTick: TimeInterval = 1.5

    /// The gap the loop is currently leaving between readings. The dial
    /// interpolates over it, so it wants the real figure rather than a nominal
    /// one.
    var temperatureCadence: TimeInterval {
        guard appIsActive else { return 3 }
        switch heatingState {
        case .heating, .boosting, .cooling:
            let measured = BluetoothManager.linkStats.snapshot
            guard measured.isMeaningful, measured.medianGapMs > 0 else { return 0.5 }
            // The measured gap between replies is the gap between readings:
            // with the window filled, a temperature comes back every reply, and
            // the state request carries one too.
            return min(1.0, max(Self.temperatureFloor, measured.medianGapMs / 1000))
        case .ready:
            return 1.5
        default:
            return 3
        }
    }

    /// How many requests the fast lane keeps in the air at once.
    ///
    /// Measured on a PAX 3: a round trip takes 226 ms, but the device streams
    /// replies 120 ms apart when several are asked for together, and the
    /// fastest round trip seen was 21 ms. So 226 ms is not what the link costs
    /// — it is mostly the app waiting, about 106 ms per reading spent on a
    /// question that could already have been asked.
    ///
    /// Two outstanding requests cover that wait: the second is already on its
    /// way while the first is being answered, and readings arrive at the rate
    /// the device produces them rather than at the rate a round trip allows.
    ///
    /// It is a window rather than a free-for-all, which is what keeps this from
    /// being the bug it looks like. The timers that caused readings to arrive
    /// four seconds apart had no idea how far behind they were; this cannot get
    /// more than two ahead, so a device that slows down is followed down.
    private var fastLaneWindow: Int {
        guard appIsActive else { return 1 }
        switch heatingState {
        case .heating, .boosting: return 2
        default:                  return 1
        }
    }

    /// What the fast lane is doing right now, in words, for the Link screen.
    ///
    /// The rate the link reports is only meaningful next to the shape it was
    /// measured in: a window of one is a round trip per reading by design, and
    /// reading "4.5 a second" off a benchmark that deliberately asks one at a
    /// time says nothing about whether pipelining works. This puts the window
    /// and the state that chose it on screen, so the number can be read
    /// honestly.
    var fastLaneDescription: String {
        let state = heatingState.map { "\($0)" } ?? "not reported"
        let window = fastLaneWindow
        let shape = window > 1 ? "\(window) in the air" : "one at a time"
        return "\(shape) · \(state)"
    }

    /// Fills the window, or waits out the cadence when there is nothing worth
    /// hurrying for.
    private func scheduleNextTemperatureRequest() {
        guard connectionState.isConnected else { return }

        if fastLaneWindow > 1 {
            temperatureLoop?.cancel()
            temperatureLoop = nil
            while outstandingFastRequests < fastLaneWindow {
                sendFastLaneRequest()
            }
            return
        }

        guard outstandingFastRequests == 0 else { return }
        temperatureLoop?.cancel()
        let idle = idleCadence
        temperatureLoop = Task { [weak self] in
            if idle > 0 {
                try? await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.connectionState.isConnected else { return }
            self.sendFastLaneRequest()
        }
    }

    /// One request, always carrying the temperature.
    ///
    /// When the oven's state and working target are due they ride along in the
    /// same packet rather than taking a turn of their own: a request costs a
    /// write and each attribute costs a reply, so three in one packet is one
    /// write instead of three, and the temperature does not lose its place in
    /// the queue to them.
    private func sendFastLaneRequest() {
        outstandingFastRequests += 1
        if Date().timeIntervalSince(lastStateRequestAt) >= Self.stateTick {
            lastStateRequestAt = Date()
            requestOvenState()
        } else {
            requestTemperature()
        }
    }

    /// What to wait before asking again. While the oven is working this is the
    /// floor — effectively "as soon as the reply is in" — and it lengthens once
    /// there is nothing to watch, because the radio spends two batteries.
    private var idleCadence: TimeInterval {
        // Backgrounded, the only reader is the Lock Screen card, and it is
        // rate-limited by iOS anyway. The loop keeps turning — stopping it
        // would leave the card frozen, which is the one place the app is
        // supposed to keep working while closed — but slowly.
        guard appIsActive else { return 3 }
        switch heatingState {
        // Climbing towards the set point, and drawing on it. This is the whole
        // reason the dial exists, so ask again the moment the answer is in.
        case .heating, .boosting:
            return Self.temperatureFloor
        // Cooling can run for minutes after a draw. Fast, but not flat out:
        // the radio costs two batteries, and nothing here changes by the
        // tenth of a degree that full speed would catch.
        case .cooling:
            return 0.3
        // Holding temperature. The number barely moves; what matters is
        // noticing when it stops holding.
        case .ready:
            return 0.75
        // Standby, oven off, or nothing reported yet: there is no temperature
        // worth watching closely, and this is where a PAX spends most of its
        // life.
        default:
            return 2.5
        }
    }

    /// One attribute, which is one reply. This is the fast lane and it stays
    /// one attribute wide.
    private func requestTemperature() {
        guard connectionState.isConnected else { return }
        enqueue {
            try self.sendPacket(PaxPacket.statusRequest(attributes: [.actualTemp]))
        }
    }

    /// The oven's state and working target, with the temperature alongside
    /// them. Three attributes, one write, three replies — and every fast-lane
    /// request yields exactly one temperature, which is what the window counts.
    private func requestOvenState() {
        guard connectionState.isConnected else { return }
        enqueue {
            try self.sendPacket(PaxPacket.statusRequest(
                attributes: [.actualTemp, .heatingState, .currentTargetTemp]))
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
        temperatureTimer?.cancel()
        temperatureTimer = nil
        temperatureLoop?.cancel()
        temperatureLoop = nil
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
        deviceHeatingParams = nil
        heatingParamsStoppedOven = false
        lastHeatingParamsWrite = nil
        // A session cannot be watched through a dropped link, so it ends here
        // and says why, rather than being left open and later reporting a
        // duration that includes however long the phone was away. A charge goes
        // the same way, and for the same reason: what happened on the dock
        // while the phone was gone is not something this app saw.
        finishSession(.disconnected)
        finishCharge()
        pendingEnding = nil
        drawStartedAt = nil
        ovenPoweredOffByApp = false
        tempTrail.removeAll()
        secondsToReady = nil
        secondsToFull = nil
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
        warmUpStartTempC = nil
        lastWarmUpHex = nil
        ReadyNotifier.shared.reset()
        pendingLedWrite = nil
        pushColorOnceDiscovered = false
        capabilitiesKnown = false
        capabilityAttempt = 0
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

    func bluetoothDidUpdateRadio(_ state: PaxRadioState) {
        log("Bluetooth radio: \(state)", level: .ble)
        // The simulator reports the radio as unavailable immediately, which
        // would wipe the fixture straight after init — and would now also put
        // "No Bluetooth on this device" across every screenshot.
        guard !demoMode else { return }
        radioState = state
        if state != .ready {
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
