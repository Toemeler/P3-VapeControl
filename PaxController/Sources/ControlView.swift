import SwiftUI

/// The app's one screen. The dial is the interface; everything that is not
/// temperature lives behind the two buttons in the top bar.
struct ControlView: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @Binding var showDeviceSheet: Bool
    @Binding var showScanSheet: Bool
    @AppStorage("temperatureUnit") private var temperatureUnitRawValue = TemperatureUnit.celsius.rawValue

    private var unit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRawValue) ?? .celsius
    }

    private var canSendCommands: Bool {
        viewModel.connectionState.isConnected && viewModel.paxServiceConfirmed
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if viewModel.connectionState.isConnected {
                connected
            } else {
                disconnected
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                showScanSheet = true
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: DS.Metric.statusDot, height: DS.Metric.statusDot)
                    Text(viewModel.connectionState.isConnected
                         ? (viewModel.displayName ?? "PAX")
                         : "Not connected")
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: DS.Metric.capsuleHeight)
                .background(DS.Palette.fill, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)

            if let battery = viewModel.batteryLevel {
                HStack(spacing: 5) {
                    Text("\(battery)%").monospacedDigit()
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
        case .scanning, .connecting,
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
            onScrub: { viewModel.customTargetTempC = $0 },
            onCommit: { celsius in
                guard canSendCommands else { return }
                viewModel.setCustomTemperature(celsius)
            }
        ) {
            dialCentre
        }
        .allowsHitTesting(canSendCommands)
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
                Text(unit.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var heatingLabel: String {
        guard viewModel.connectionState.isConnected else { return "OFFLINE" }
        guard let state = viewModel.heatingState else { return "—" }
        return state.description.uppercased()
    }

    private var heatingColor: Color {
        switch viewModel.heatingState {
        case .heating, .boostMode:  return DS.Palette.accent
        case .ready:                return .green
        case .cooling:              return .blue
        case .standby, .off, .none: return .secondary
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
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .disabled(!canSendCommands)
        .opacity(canSendCommands ? 1 : 0.4)
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
                .buttonStyle(.plain)
                .disabled(!canSendCommands)
            }
        }
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.top, 24)
        .opacity(canSendCommands ? 1 : 0.4)
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
                    .buttonStyle(.plain)
                    .disabled(!canSendCommands)
                }
            }
            .padding(.horizontal, DS.Metric.gutter)
        }
        .padding(.bottom, 12)
        .opacity(canSendCommands ? 1 : 0.4)
    }

    // MARK: - Disconnected

    private var disconnected: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "thermometer.medium")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 84)
                .background(DS.Palette.fill, in: Circle())

            Text(statusHeadline)
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

            Button {
                showScanSheet = true
            } label: {
                Text("Connect to a PAX")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(DS.Palette.accent, in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Metric.gutter)
            .padding(.bottom, 20)
        }
    }

    private var statusHeadline: String {
        if case .error = viewModel.connectionState { return "Connection failed" }
        if viewModel.connectionState == .idle { return "Not connected" }
        return viewModel.connectionState.displayString
    }

    private var statusDetail: String {
        if case .error(let message) = viewModel.connectionState { return message }
        return "Connect to your PAX to set temperature and heating mode."
    }
}
