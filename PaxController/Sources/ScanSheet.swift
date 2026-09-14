import SwiftUI

/// The device picker. Scanning is a transient task, so it gets a sheet off the
/// connection capsule rather than a permanent place in the app.
struct ScanSheet: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @Environment(\.dismiss) private var dismiss

    private var isScanning: Bool { viewModel.connectionState == .scanning }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.scannedDevices.isEmpty {
                    emptyState
                } else {
                    List(viewModel.scannedDevices) { device in
                        DeviceRow(device: device) { viewModel.connect(to: device) }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.stopScan()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isScanning {
                        Button("Stop") { viewModel.stopScan() }
                    } else {
                        Button("Scan") { viewModel.startScan() }
                    }
                }
            }
        }
        .onAppear {
            if !viewModel.connectionState.isConnected { viewModel.startScan() }
        }
        .onDisappear { viewModel.stopScan() }
        .onChange(of: viewModel.connectionState) { state in
            if state.isConnected { dismiss() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if isScanning {
                ProgressView()
                Text("Scanning for nearby PAX devices…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No devices found")
                    .font(.headline)
                Text("Make sure your PAX is awake and within a few metres, then tap Scan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: ScannedDevice
    let onConnect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                Text(device.id.uuidString)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(rssiColor(device.rssi))
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(DS.Palette.accent)
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
