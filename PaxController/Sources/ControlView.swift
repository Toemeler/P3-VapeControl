import SwiftUI

/// The app's one screen. The dial is the interface; everything that is not
/// temperature lives behind the two buttons in the top bar.
struct ControlView: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @EnvironmentObject var settings: AppSettings
    @Binding var showDeviceSheet: Bool

    @State private var searchBreath = false

    private var unit: TemperatureUnit { settings.temperatureUnit }

    private var isSearching: Bool {
        switch viewModel.connectionState {
        case .scanning, .waitingForDevice, .connecting, .discoveringServices, .awaitingSerial:
            return true
        default:
            return false
        }
    }

    private var canSendCommands: Bool {
        viewModel.connectionState.isConnected && viewModel.paxServiceConfirmed
    }

    /// The oven is off on the charger, so the steppers, presets and modes have
    /// nothing to act on. They stay exactly where they are and grey out rather
    /// than disappearing: a screen that rebuilds itself every time the device
    /// is put down is worse than one that goes quiet.
    private var controlsActive: Bool {
        canSendCommands && viewModel.isCharging != true
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if viewModel.connectionState.isConnected {
                connected
                    .transition(.opacity)
            } else {
                disconnected
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.connectionState.isConnected)
        .background(DS.Palette.canvas)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // A readout, not a control: connecting is automatic, so there is
            // nothing here for the user to start.
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: DS.Metric.statusDot, height: DS.Metric.statusDot)
                    // Breathing while it looks, steady once it has found it.
                    .opacity(isSearching && searchBreath ? 0.35 : 1)
                    .animation(isSearching
                               ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                               : .easeOut(duration: 0.25),
                               value: searchBreath)
                    .onAppear { searchBreath = isSearching }
                    .onChange(of: isSearching) { searchBreath = $0 }
                Text(viewModel.connectionState.isConnected
                     ? (viewModel.displayName ?? "PAX")
                     : viewModel.statusHeadline)
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: DS.Metric.capsuleHeight)
            .background(DS.Palette.fill, in: Capsule())

            if let battery = viewModel.batteryLevel {
                HStack(spacing: 5) {
                    Text("\(battery)%")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.4), value: battery)
                    if viewModel.isCharging == true {
                        Image(systemName: "bolt.fill").font(.system(size: 11))
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 13)
                .frame(height: DS.Metric.capsuleHeight)
                .background(DS.Palette.fill, in: Capsule())
            }

            Spacer(minLength: 0)

            // The PAX reports its lock state but exposes no way to set it, so
            // this is an indicator and only appears when it has something to say.
            if viewModel.isLocked == true {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: DS.Metric.roundButton, height: DS.Metric.roundButton)
                    .background(DS.Palette.fill, in: Circle())
                    .accessibilityLabel("Device locked")
            }

            Button {
                showDeviceSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: DS.Metric.roundButton, height: DS.Metric.roundButton)
                    .background(DS.Palette.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityLabel("Device settings")
        }
        .padding(.horizontal, DS.Metric.gutter)
        .frame(height: DS.Metric.topBarHeight)
    }

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .ready:                                        return .green
        case .scanning, .connecting, .waitingForDevice,
             .discoveringServices, .awaitingSerial:         return .orange
        case .error:                                        return .red
        case .idle, .disconnecting:                         return .secondary
        }
    }

    // MARK: - Connected

    private var connected: some View {
        VStack(spacing: 0) {
            dial
            targetRow
            presetRow
            Spacer(minLength: 0)
            modeBlock
        }
    }

    private var dial: some View {
        TemperatureDial(
            current: viewModel.actualTempC,
            target: viewModel.customTargetTempC,
            accent: DS.Palette.accent,
            cadence: viewModel.temperatureCadence,
            batteryLevel: viewModel.batteryLevel,
            isCharging: viewModel.isCharging == true,
            heatingState: viewModel.heatingState,
            onScrub: { viewModel.customTargetTempC = $0 },
            onCommit: { celsius in
                guard canSendCommands else { return }
                viewModel.setCustomTemperature(celsius)
            }
        ) {
            dialCentre
        }
        .allowsHitTesting(controlsActive)
        .overlay(alignment: .bottomLeading) {
            rangeLabel(DS.Range.min).padding(.leading, 46).padding(.bottom, 30)
        }
        .overlay(alignment: .bottomTrailing) {
            rangeLabel(DS.Range.max).padding(.trailing, 46).padding(.bottom, 30)
        }
    }

    private func rangeLabel(_ celsius: Double) -> some View {
        Text(unit.format(celsius, includeSymbol: false) + "°")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var dialCentre: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(heatingColor)
                    .frame(width: DS.Metric.statusDot, height: DS.Metric.statusDot)
                Text(heatingLabel)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(heatingColor)
            }
            .padding(.bottom, 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(viewModel.actualTempC.map { unit.format($0, decimals: 1, includeSymbol: false) } ?? "--")
                    .font(.system(size: 66, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-2.3)
                    // Readings arrive twice a second; snapping between them
                    // reads as a counter, rolling reads as an instrument.
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                Text(unit.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var heatingLabel: String {
        guard viewModel.connectionState.isConnected else { return "OFFLINE" }
        if viewModel.isCharging == true { return "CHARGING" }
        guard let state = viewModel.heatingState else { return "—" }
        return state.description.uppercased()
    }

    private var heatingColor: Color {
        if viewModel.isCharging == true { return DS.Palette.charge }
        switch viewModel.heatingState {
        case .heating, .boosting:   return DS.Palette.accent
        case .ready:                return .green
        case .cooling:              return .blue
        case .standby, .ovenOff,
             .tempSetMode, .none:   return .secondary
        }
    }

    // MARK: - Target

    private var targetRow: some View {
        HStack(spacing: 26) {
            stepButton("minus", delta: -1)
            VStack(spacing: 1) {
                Text(unit.format(viewModel.customTargetTempC))
                    .font(.system(size: 25, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: viewModel.customTargetTempC)
                Text("Target")
                    .font(.system(size: 12))
                    .tracking(0.2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120)
            stepButton("plus", delta: 1)
        }
        .padding(.top, 22)
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button {
            let next = (viewModel.customTargetTempC + delta).rounded()
            let clamped = min(DS.Range.max, max(DS.Range.min, next))
            guard clamped != viewModel.customTargetTempC else { return }
            viewModel.customTargetTempC = clamped
            viewModel.setCustomTemperature(clamped)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: DS.Metric.stepButton, height: DS.Metric.stepButton)
                .background(DS.Palette.fill, in: Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .foregroundStyle(Color.primary)
        .disabled(!controlsActive)
        .opacity(controlsActive ? 1 : 0.32)
        .accessibilityLabel(delta > 0 ? "Increase target" : "Decrease target")
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: 9) {
            ForEach(PaxPresetTemp.allCases) { preset in
                let isActive = viewModel.selectedPreset == preset
                Button {
                    viewModel.setTemperature(preset)
                } label: {
                    Text(unit.format(Double(preset.rawValue), includeSymbol: false) + "°")
                        .font(.system(size: 15, weight: isActive ? .semibold : .medium))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .frame(height: DS.Metric.presetHeight)
                        .background(isActive ? DS.Palette.accentTint : DS.Palette.fill,
                                    in: Capsule())
                        .foregroundStyle(isActive ? DS.Palette.accent : Color.primary)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!controlsActive)
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isActive)
            }
        }
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.top, 24)
        .opacity(controlsActive ? 1 : 0.32)
    }

    // MARK: - Heating mode

    private var modeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Heating mode")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                ForEach(PaxDynamicMode.allCases) { mode in
                    let isActive = viewModel.dynamicMode == mode
                    Button {
                        viewModel.setDynamicMode(mode)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 21))
                            Text(mode.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: DS.Metric.modeHeight)
                        .background(isActive ? DS.Palette.accent : DS.Palette.fill,
                                    in: RoundedRectangle(cornerRadius: DS.Metric.modeRadius,
                                                         style: .continuous))
                        .foregroundStyle(isActive ? Color.white : Color.secondary)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.95))
                    .disabled(!controlsActive)
                    .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isActive)
                }
            }
            .padding(.horizontal, DS.Metric.gutter)
        }
        .padding(.bottom, 12)
        .opacity(controlsActive ? 1 : 0.32)
    }

    // MARK: - Disconnected

    private var disconnected: some View {
        VStack(spacing: 0) {
            if viewModel.scannedDevices.isEmpty {
                // Carries its own spacers, so it centres in what is left.
                emptyDiscovery
            } else {
                discoveredList
                Spacer(minLength: 0)
            }
            // The only button on this screen, and only after the user has
            // pressed Disconnect themselves: every other path back to the
            // device happens without them.
            if viewModel.automationPaused { resumeButton }
        }
        // Looking for the device is the app's job, not a tap the user owes it.
        // `resumeDiscoveryIfIdle`, not `resumeAutomation`: this fires again the
        // moment a user-requested disconnect drops us back here, and must not
        // undo it.
        .onAppear { viewModel.resumeDiscoveryIfIdle() }
    }

    private var isScanning: Bool { viewModel.isScanning }

    private var emptyDiscovery: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "thermometer.medium")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 84)
                .background(DS.Palette.fill, in: Circle())

            Text(viewModel.statusHeadline)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.4)
                .padding(.top, 20)

            Text(statusDetail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 7)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var discoveredList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Available devices")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 8) {
                ForEach(viewModel.scannedDevices) { device in
                    Button {
                        viewModel.connect(to: device)
                    } label: {
                        discoveredRow(device)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Metric.gutter)
        }
    }

    private func discoveredRow(_ device: ScannedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 19))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 42, height: 42)
                .background(DS.Palette.accentTint, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                Text("\(device.rssi) dBm")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
        .background(DS.Palette.fill,
                    in: RoundedRectangle(cornerRadius: DS.Metric.modeRadius, style: .continuous))
        .foregroundStyle(Color.primary)
        .contentShape(Rectangle())
    }

    private var resumeButton: some View {
        Button {
            viewModel.resumeAutomation()
        } label: {
            Text("Connect")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(DS.Palette.accent, in: Capsule())
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private var statusDetail: String {
        if case .error(let message) = viewModel.connectionState { return message }
        if viewModel.automationPaused {
            return "Disconnected. Tap Connect to look for your PAX again."
        }
        if isScanning || viewModel.connectionState == .waitingForDevice {
            return "Make sure your PAX is awake and within a few metres. It connects on its own."
        }
        return "Looking for your PAX. It connects on its own."
    }
}
