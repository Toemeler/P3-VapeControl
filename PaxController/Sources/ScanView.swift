import SwiftUI

struct ScanView: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel

    var body: some View {
        NavigationView {
            deviceList
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    scanButton
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.connectionState.isConnected {
                        Button("Disconnect", role: .destructive) {
                            viewModel.disconnect()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var scanButton: some View {
        Group {
            if case .scanning = viewModel.connectionState {
                Button("Stop") { viewModel.stopScan() }
            } else if !viewModel.connectionState.isConnected {
                Button("Scan") { viewModel.startScan() }
            }
        }
    }

    private var deviceList: some View {
        Group {
            if viewModel.scannedDevices.isEmpty {
                emptyState
            } else {
                List(viewModel.scannedDevices) { device in
                    DeviceRow(device: device) {
                        viewModel.connect(to: device)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("No devices found")
                .font(.headline)
            Text("Tap Scan to search for nearby PAX devices.\nMake sure the device is powered on.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

}

// MARK: - Device Row

struct DeviceRow: View {
    @EnvironmentObject var settings: AppSettings

    let device: ScannedDevice
    let onConnect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                Text(device.id.uuidString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundColor(rssiColor(device.rssi))
                Button("Connect") { onConnect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(settings.ledColor.color)
            }
        }
        .padding(.vertical, 4)
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -60 { return .green }
        if rssi >= -80 { return .yellow }
        return .red
    }
}
