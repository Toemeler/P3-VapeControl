import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PaxDeviceViewModel.shared
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDeviceSheet = false

    /// Launch arguments land in UserDefaults' argument domain, so the
    /// screenshot workflow can open a sheet with `simctl launch ... -uiScreen
    /// device`. Without the argument this reads back nil and the app opens on
    /// the dial, as it does for everyone else.
    private let launchScreen = UserDefaults.standard.string(forKey: "uiScreen")

    var body: some View {
        ControlView(showDeviceSheet: $showDeviceSheet)
            .environmentObject(viewModel)
            .environmentObject(settings)
            .sheet(isPresented: $showDeviceSheet) {
                DeviceSheet()
                    .environmentObject(viewModel)
                    .environmentObject(settings)
            }
            .tint(DS.Palette.accent)
            .onAppear {
                if launchScreen == "device" { showDeviceSheet = true }
            }
            .onChange(of: scenePhase) { phase in
                // A background reconnect can only *update* a Live Activity, never
                // start one, so retry the start whenever we are foregrounded —
                // and pick discovery back up, since iOS suspends a scan that was
                // running when the app went away.
                viewModel.setActive(phase == .active)
                if phase == .active {
                    viewModel.refreshLiveActivity()
                    viewModel.resumeDiscoveryIfIdle()
                }
            }
    }
}
