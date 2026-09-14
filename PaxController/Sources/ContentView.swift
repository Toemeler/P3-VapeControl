import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PaxDeviceViewModel()
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    // Launch arguments land in UserDefaults' argument domain, so the screenshot
    // workflow can open a specific tab with `simctl launch ... -uiTab 1`.
    // Without the argument this reads back as 0, the normal first tab.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "uiTab")

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner()

            TabView(selection: $selectedTab) {
                ScanView()
                    .tabItem { Label("Scan", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(0)

                DeviceView()
                    .tabItem { Label("Device", systemImage: "thermometer.medium") }
                    .tag(1)

                DebugConsoleView()
                    .tabItem { Label("Log", systemImage: "text.alignleft") }
                    .tag(2)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
        }
        .environmentObject(viewModel)
        .environmentObject(settings)
        .accentColor(settings.ledColor.color)
        .onChange(of: scenePhase) { phase in
            // A background reconnect can't start a Live Activity — only update
            // one — so retry the start whenever we're foregrounded again.
            if phase == .active { viewModel.refreshLiveActivity() }
        }
    }
}

// MARK: - Always-visible status strip

/// Sits above the tab content so the PAX's state is readable from any tab,
/// mirroring what the Lock Screen card shows. Hidden only on a clean first run
/// with nothing to report.
struct StatusBanner: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if isVisible {
            HStack(spacing: 10) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)

                Text(viewModel.displayName ?? viewModel.rememberedDeviceName ?? "PAX")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(viewModel.statusHeadline)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if viewModel.connectionState.isConnected {
                    if viewModel.isCharging == true {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    if let battery = viewModel.batteryLevel {
                        Text("\(battery)%")
                            .font(.subheadline.monospacedDigit())
                    }
                    if let temp = viewModel.actualTempC {
                        Text(formatted(temp))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(accent)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    private var isVisible: Bool {
        // Hidden only on a clean first run: nothing paired and nothing happening.
        if viewModel.rememberedDeviceName != nil { return true }
        return viewModel.connectionState != .idle
    }

    private var accent: Color {
        viewModel.connectionState.isConnected ? settings.ledColor.color : .secondary
    }

    private func formatted(_ celsius: Double) -> String {
        let value = settings.useFahrenheit ? (celsius * 9 / 5) + 32 : celsius
        return String(format: "%.0f°%@", value, settings.useFahrenheit ? "F" : "C")
    }
}
