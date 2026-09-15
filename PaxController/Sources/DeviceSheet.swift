import SwiftUI

/// Everything the dial screen does not need in the moment. It is reached once
/// in a while from the gear button, so it is a sheet rather than a tab.
struct DeviceSheet: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var customColor: Color = LedColor.orange.color

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                ledColorSection
                temperatureSection
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
            .navigationTitle(viewModel.displayName ?? "Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { customColor = settings.ledColor.color }
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

    // MARK: - LED color

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
                Button("Send color to device now") {
                    viewModel.applyLedColor(settings.ledColor)
                }
                .disabled(!viewModel.connectionState.isConnected || !viewModel.deviceLedColorSupported)
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
            Text("Colors the dial, chips and buttons. Setting the PAX's own LEDs depends on the device: on connect the app asks which attributes the firmware supports and what its current LED value looks like, then writes a matching payload and reads it back to check it took. Diagnostics shows the whole exchange.")
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
            row("Name", value: viewModel.displayName)
            row("Model", value: viewModel.modelNumber)
            row("Serial", value: viewModel.serialNumber)
            row("Firmware", value: viewModel.firmwareRevision)
            if let shell = viewModel.shellColorIndex {
                row("Shell", value: PaxDeviceViewModel.shellColorLabel(shell))
            }
            if let haptics = viewModel.hapticAmplitude {
                row("Haptics", value: "\(Int(haptics * 100))%")
            }
            if !viewModel.supportedAttributes.isEmpty {
                row("Attributes", value: "\(viewModel.supportedAttributes.count) supported")
            }
        }
    }

    // Shipped in release, not just debug: a sideloaded app's only support
    // channel is the user reading the log back to you.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink("Diagnostics") {
                DebugConsoleView().environmentObject(viewModel)
            }
        } footer: {
            Text("Connection state, PAX service characteristics and the raw packet log.")
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
