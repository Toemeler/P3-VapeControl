import SwiftUI

/// Everything the dial screen does not need in the moment. It is reached once
/// in a while from the gear button, so it is a sheet rather than a tab.
struct DeviceSheet: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("temperatureUnit") private var temperatureUnitRawValue = TemperatureUnit.celsius.rawValue

    private var unit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRawValue) ?? .celsius
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                temperatureSection
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
            Picker("Units", selection: $temperatureUnitRawValue) {
                Text("°C").tag(TemperatureUnit.celsius.rawValue)
                Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
            }
            .pickerStyle(.segmented)
            if let target = viewModel.targetTempC {
                row("On device", value: unit.format(target, decimals: 1))
            }
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            row("Name", value: viewModel.displayName)
            row("Model", value: viewModel.modelNumber)
            row("Serial", value: viewModel.serialNumber)
            row("Firmware", value: viewModel.firmwareRevision)
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        #if DEBUG
        Section {
            NavigationLink("Diagnostics") {
                DebugConsoleView().environmentObject(viewModel)
            }
        } footer: {
            Text("Connection state, PAX service characteristics and the raw packet log.")
        }
        #endif
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
