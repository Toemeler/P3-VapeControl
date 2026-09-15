import Foundation
import SwiftUI

/// Everything the dial screen does not need in the moment. It is reached once
/// in a while from the gear button, so it is a sheet rather than a tab.
struct DeviceSheet: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var customColor: Color = LedColor.orange.color
    /// Held apart from `viewModel.displayName` so the 3 s poll cannot rewrite
    /// the field under the user's cursor mid-rename.
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                ledColorSection
                ledModeSection
                alertsSection
                temperatureSection
                ovenSection
                connectionSection
                lockScreenSection
                deviceSection
                diagnosticsSection
                if viewModel.connectionState.isConnected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            viewModel.disconnect()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(viewModel.connectionState.isConnected ? viewModel.deviceLabel : "Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            customColor = settings.ledColor.color
            draftName = viewModel.displayName ?? ""
        }
        .onChange(of: viewModel.displayName) { name in
            guard !nameFieldFocused else { return }
            draftName = name ?? ""
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        if viewModel.connectionState.isConnected {
            Section {
                if let battery = viewModel.batteryLevel {
                    HStack {
                        Text("Battery")
                        Spacer()
                        Text("\(battery)%")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                        Capsule()
                            .fill(Color(.systemFill))
                            .frame(width: 60, height: 8)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(batteryColor(battery))
                                    .frame(width: 60 * CGFloat(battery) / 100, height: 8)
                            }
                    }
                }
                if viewModel.isCharging == true {
                    row("Charging", value: "Yes")
                }
                if let state = viewModel.heatingState {
                    row("State", value: state.description)
                }
                if let locked = viewModel.isLocked {
                    // Read-only: LockStatus (0x06) is documented Device to Host
                    // only, so there is nothing to write back.
                    row("Lock", value: locked ? "Locked" : "Unlocked")
                }
            }
        }
    }

    private var temperatureSection: some View {
        Section("Temperature") {
            Picker("Units", selection: $settings.temperatureUnit) {
                Text("°C").tag(TemperatureUnit.celsius)
                Text("°F").tag(TemperatureUnit.fahrenheit)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.temperatureUnit) { _ in
                viewModel.refreshLiveActivity()
            }
            if let target = viewModel.targetTempC {
                row("On device", value: unit.format(target, decimals: 1))
            }
        }
    }

    /// The lip sensor's hold over the oven. HeatingParams (0x19) is written
    /// wholesale and this firmware has not answered a read of it in any
    /// capture, so the switch is a record of what the app last sent rather than
    /// a reading — the footer says so rather than implying the device
    /// confirmed anything.
    @ViewBuilder
    private var ovenSection: some View {
        Section {
            Toggle("Lip detection", isOn: Binding(
                get: { viewModel.lipDetectionEnabled },
                set: { viewModel.setLipDetection($0) }))
                .disabled(!viewModel.canSetLipDetection)
            if !viewModel.lipDetectionEnabled {
                Button("Restore factory heating settings") {
                    viewModel.restoreStockHeatingParams()
                }
                .disabled(!viewModel.canSetLipDetection)
            }
        } header: {
            Text("Oven")
        } footer: {
            Text(lipDetectionNote)
        }
    }

    private var lipDetectionNote: String {
        guard viewModel.canSetLipDetection else {
            return viewModel.canSendCommands
                ? "This PAX does not report the heating parameters attribute, so lip detection cannot be changed from here."
                : "Connect to the PAX to change this."
        }
        let base = viewModel.lipDetectionEnabled
            ? "The PAX raises the temperature while it senses a draw, then cools and switches off when it stops sensing one."
            : "The oven holds the set point whether or not it senses a draw — no boost on a draw, and no cooling when the lips leave it. It also no longer switches itself off a few minutes after the last draw: it still drops to the standby temperature when the device stops moving, but from there it stays warm until it is switched off by hand or the battery runs down."
        return base + " Written as part of the heating parameters, which a mode change replaces — the app re-sends it after every mode change and on every connection. The PAX does not report this attribute back, so the switch shows what was last sent, not a reading."
    }

    // MARK: - LED color

    private var alertsSection: some View {
        Section {
            Toggle("Tell me when it is ready", isOn: $settings.notifyWhenReady)
                .onChange(of: settings.notifyWhenReady) { on in
                    if on { ReadyNotifier.shared.requestAuthorizationIfNeeded() }
                }
        } header: {
            Text("Alerts")
        } footer: {
            Text("A notification the moment the oven reaches the set point — the app does not have to be open, since the connection is kept in the background.")
        }
    }

    /// The PAX keeps two colours for each of its four states. Hidden unless the
    /// user is actually driving the device's LEDs — with that off, these
    /// colours would go nowhere.
    @ViewBuilder
    private var ledModeSection: some View {
        if settings.pushColorToDevice {
            Section {
                Toggle("A colour per state", isOn: Binding(
                    get: { settings.perModeLedColors },
                    set: { enabled in
                        // Start from what the PAX is showing rather than from
                        // eight copies of the accent colour.
                        if enabled, !settings.perModeLedColors {
                            settings.seedModeColors(from: viewModel.deviceColorTheme)
                        }
                        settings.perModeLedColors = enabled
                        viewModel.resendLedColors()
                    }))
                if settings.perModeLedColors {
                    Toggle("Follow the temperature while heating", isOn: Binding(
                        get: { settings.warmUpGradient },
                        set: { settings.warmUpGradient = $0; viewModel.resendLedColors() }))
                    ForEach(PaxColorTheme.Mode.allCases, id: \.self) { mode in
                        modeColorRow(mode)
                    }
                    Button("Reset to the default colours") {
                        settings.resetModeColorsToCleanDefaults()
                        viewModel.resendLedColors()
                    }
                }
            } header: {
                Text("PAX LED States")
            } footer: {
                Text(settings.perModeLedColors
                     ? "Each state holds two colours; the PAX moves between them. Set both to the same colour for a steady light. While it warms up the heating colour can follow the thermometer instead — green, through yellow, to orange. The colour above still themes the app."
                     : "The PAX keeps a separate pair of colours for each of its four states. Turn this on to set them individually instead of painting all four with the colour above.")
            }
        }
    }

    private func modeColorRow(_ mode: PaxColorTheme.Mode) -> some View {
        let pair = settings.modeColors(mode.rawValue)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.label)
                    .font(.subheadline.weight(.semibold))
                Text(mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                modeColorWell(mode: mode, slot: 0, current: pair.0)
                modeColorWell(mode: mode, slot: 1, current: pair.1)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    private func modeColorWell(mode: PaxColorTheme.Mode, slot: Int, current: LedColor) -> some View {
        HStack(spacing: 7) {
            ColorPicker("", selection: Binding(
                get: { current.color },
                set: { newValue in
                    guard let picked = LedColor.fromColor(newValue), picked.hex != current.hex else { return }
                    settings.setModeColor(picked, mode: mode.rawValue, slot: slot)
                    viewModel.resendLedColors()
                }), supportsOpacity: false)
            .labelsHidden()
            Text(slot == 0 ? "Colour 1" : "Colour 2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ledColorSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                ForEach(LedColor.presets) { preset in
                    swatch(preset)
                }
            }
            .padding(.vertical, 4)

            ColorPicker("Custom", selection: $customColor, supportsOpacity: false)
                .onChange(of: customColor) { newValue in
                    guard let picked = LedColor.fromColor(newValue),
                          picked.hex != settings.ledColorHex else { return }
                    viewModel.applyLedColor(picked)
                }

            Toggle("Also set the PAX's own LEDs", isOn: $settings.pushColorToDevice)
            if settings.pushColorToDevice {
                if viewModel.connectionState.isConnected {
                    Label(deviceLedStatus, systemImage: viewModel.deviceLedColorSupported ? "checkmark.circle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(viewModel.deviceLedColorSupported ? Color.secondary : Color.orange)
                }
                Button("Send colours to device now") {
                    viewModel.resendLedColors()
                }
                .disabled(!viewModel.connectionState.isConnected || !viewModel.deviceLedColorSupported)
            }

            if let haptics = viewModel.hapticAmplitude {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Haptics")
                        Spacer()
                        Text("\(Int(haptics * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { haptics },
                            set: { viewModel.setHapticAmplitude($0) }
                        ),
                        in: 0...1
                    )
                    .tint(settings.ledColor.color)
                }
            }

            if let brightness = viewModel.ledBrightness {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightness * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { brightness },
                            set: { viewModel.setLedBrightness($0) }
                        ),
                        in: 0...1
                    )
                    .tint(settings.ledColor.color)
                }
            }
        } header: {
            Text("LED Color")
        } footer: {
            Text("Colors the dial, chips and buttons. Setting the PAX's own LEDs depends on the device: on connect the app asks which attributes the firmware supports and what its current LED value looks like, then writes a matching payload and reads it back to check it took. Brightness and haptics are the same 0–128 scale the firmware uses. Diagnostics shows the whole exchange.")
        }
    }

    private var deviceLedStatus: String {
        guard viewModel.deviceLedColorSupported else {
            return "This PAX does not expose its LEDs over Bluetooth, so only the app is themed."
        }
        guard let theme = viewModel.deviceColorTheme else {
            return "Waiting for this PAX to report its colour theme."
        }
        return "Setting all \(theme.modes.count) LED states — startup, heating, regulating and standby — to the chosen colour."
    }

    private func swatch(_ preset: LedColor) -> some View {
        let isSelected = preset.hex == settings.ledColorHex
        return Button {
            customColor = preset.color
            viewModel.applyLedColor(preset)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 38, height: 38)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(preset.isLight ? Color.black : Color.white)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                        .frame(width: 44, height: 44)
                )
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            Toggle("Reconnect automatically", isOn: $settings.autoConnectEnabled)
                .onChange(of: settings.autoConnectEnabled) { enabled in
                    if enabled { viewModel.resumeAutomation() }
                }
            if let name = viewModel.rememberedDeviceName {
                row("Remembered", value: name)
                Button("Forget this device", role: .destructive) {
                    viewModel.forgetRememberedDevice()
                    dismiss()
                }
            }
        } header: {
            Text("Auto-Connect")
        } footer: {
            Text("Reconnects on its own whenever the PAX is in range, including while the app is in the background or has been closed by iOS. It cannot reconnect after you force-quit the app from the App Switcher — iOS blocks Bluetooth for every app that was force-quit until it is opened again.")
        }
    }

    // MARK: - Lock screen

    private var lockScreenSection: some View {
        Section {
            Toggle("Show on Lock Screen", isOn: $settings.liveActivityEnabled)
                .onChange(of: settings.liveActivityEnabled) { enabled in
                    if enabled {
                        viewModel.refreshLiveActivity()
                    } else {
                        viewModel.endLiveActivity()
                    }
                }
            if !LiveActivityController.shared.areActivitiesEnabled {
                Label("Live Activities are turned off for this app in iOS Settings.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("Keeps a live status card on the Lock Screen and in the Dynamic Island while the PAX is connected or charging. The card stays up after a disconnect so it can light back up when the device returns.")
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            if viewModel.connectionState.isConnected {
                HStack {
                    Text("Name")
                    TextField("PAX", text: $draftName)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                        .onChange(of: draftName) { new in
                            // The device carries the name in a 15-byte payload,
                            // so keep the field inside what will actually fit
                            // rather than silently truncating on send.
                            var trimmed = new
                            while Data(trimmed.utf8).count > PaxPacket.maxDisplayNameBytes, !trimmed.isEmpty {
                                trimmed.removeLast()
                            }
                            if trimmed != new { draftName = trimmed }
                        }
                        .onSubmit {
                            viewModel.setDisplayName(draftName)
                            nameFieldFocused = false
                        }
                }
            } else {
                row("Name", value: viewModel.displayName)
            }
            if viewModel.connectionState.isConnected {
                Text(nameSourceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            row("Model", value: viewModel.modelNumber)
            row("Serial", value: viewModel.serialNumber)
            row("Firmware", value: viewModel.firmwareRevision)
            if let shell = viewModel.shellColorIndex {
                row("Shell", value: PaxDeviceViewModel.shellColorLabel(shell))
            }
            if !viewModel.supportedAttributes.isEmpty {
                row("Attributes", value: "\(viewModel.supportedAttributes.count) supported")
            }
        }
    }

    /// Renaming is only as good as what the firmware allows, so say which it
    /// is rather than letting a name silently mean nothing.
    private var nameSourceNote: String {
        if viewModel.reportedName != nil { return "Stored on the PAX." }
        if viewModel.gapName != nil {
            return viewModel.canRenameDevice
                ? "From the device itself."
                : "From the device itself, and read only on this firmware — a new name is kept by this app."
        }
        if settings.deviceNickname != nil {
            return "This firmware would not take a name, so this one is kept by the app."
        }
        return "This firmware may not store a name; the app keeps one either way."
    }

    // Shipped in release, not just debug: a sideloaded app's only support
    // channel is the user reading the log back to you.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink("Diagnostics") {
                DebugConsoleView().environmentObject(viewModel)
            }
            #if PAX_LAB
            NavigationLink {
                PaxLabView().environmentObject(viewModel)
            } label: {
                Label("Lab", systemImage: "flask")
            }
            #endif
            if viewModel.connectionState.isConnected {
                Button {
                    viewModel.probeUndecodedAttributes()
                } label: {
                    HStack {
                        Text("Probe unknown attributes")
                        if viewModel.probeInProgress {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(viewModel.probeInProgress)
            }
        } footer: {
            Text("Connection state, PAX service characteristics and the raw packet log. The probe reads the attributes this firmware answers but nobody has decoded, three times each, and writes what the reads agree on to the log — it only reads, never writes.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        if level > 30 { return .green }
        if level > 15 { return .yellow }
        return .red
    }
}
