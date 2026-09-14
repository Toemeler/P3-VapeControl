import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @EnvironmentObject var settings: AppSettings

    @State private var customColor: Color = LedColor.orange.color

    var body: some View {
        NavigationView {
            Form {
                ledColorSection
                devicePushSection
                connectionSection
                lockScreenSection
                unitsSection
            }
            .navigationTitle("Settings")
        }
        .onAppear { customColor = settings.ledColor.color }
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

            ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                .onChange(of: customColor) { newValue in
                    guard let picked = LedColor.fromColor(newValue) else { return }
                    guard picked.hex != settings.ledColorHex else { return }
                    viewModel.applyLedColor(picked)
                }
        } header: {
            Text("LED Color")
        } footer: {
            Text("Sets the accent color used throughout the app. Default is orange.")
        }
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
                            .foregroundColor(preset.isLight ? .black : .white)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                        .frame(width: 44, height: 44)
                )
                Text(preset.name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Experimental device push

    private var devicePushSection: some View {
        Section {
            Toggle("Also set the PAX's own LEDs", isOn: $settings.pushColorToDevice)
                .tint(settings.ledColor.color)
            if settings.pushColorToDevice {
                Button("Send color to device now") {
                    viewModel.applyLedColor(settings.ledColor)
                }
                .disabled(!viewModel.connectionState.isConnected)
            }
        } header: {
            Text("Device LEDs (experimental)")
        } footer: {
            Text("The PAX's ShellColor command is not publicly documented, so the app sends a best-guess RGB payload. It may simply be ignored by the device — check the Log tab to see whether it is acknowledged. Turning this off keeps the color purely in-app.")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            Toggle("Reconnect automatically", isOn: $settings.autoConnectEnabled)
                .tint(settings.ledColor.color)
                .onChange(of: settings.autoConnectEnabled) { enabled in
                    if enabled { viewModel.attemptAutoConnect() }
                }

            if let name = viewModel.rememberedDeviceName {
                HStack {
                    Text("Remembered")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(name)
                        .fontWeight(.medium)
                }
                Button("Forget this device", role: .destructive) {
                    viewModel.forgetRememberedDevice()
                }
            } else {
                Text("No device remembered yet — connect once from the Scan tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                .tint(settings.ledColor.color)
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
                    .foregroundColor(.orange)
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("Keeps a live status card on the Lock Screen and in the Dynamic Island while the PAX is connected or charging. The card stays up after a disconnect so it can light back up when the device returns.")
        }
    }

    // MARK: - Units

    private var unitsSection: some View {
        Section("Units") {
            Picker("Temperature", selection: $settings.useFahrenheit) {
                Text("Celsius").tag(false)
                Text("Fahrenheit").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.useFahrenheit) { _ in
                viewModel.refreshLiveActivity()
            }
        }
    }
}
