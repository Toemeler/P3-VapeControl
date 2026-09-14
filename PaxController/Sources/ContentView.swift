import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PaxDeviceViewModel()
    @State private var showDeviceSheet = false
    @State private var showScanSheet = false

    /// Launch arguments land in UserDefaults' argument domain, so the
    /// screenshot workflow can open a sheet with `simctl launch ... -uiScreen
    /// device`. Without the argument this reads back nil and the app opens on
    /// the dial, as it does for everyone else.
    private let launchScreen = UserDefaults.standard.string(forKey: "uiScreen")

    var body: some View {
        ControlView(showDeviceSheet: $showDeviceSheet, showScanSheet: $showScanSheet)
            .environmentObject(viewModel)
            .sheet(isPresented: $showDeviceSheet) {
                DeviceSheet().environmentObject(viewModel)
            }
            .sheet(isPresented: $showScanSheet) {
                ScanSheet().environmentObject(viewModel)
            }
            .tint(DS.Palette.accent)
            .onAppear {
                switch launchScreen {
                case "device": showDeviceSheet = true
                case "scan":   showScanSheet = true
                default:       break
                }
            }
    }
}
