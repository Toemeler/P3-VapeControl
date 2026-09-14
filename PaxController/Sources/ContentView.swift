import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PaxDeviceViewModel()
    // Launch arguments land in UserDefaults' argument domain, so the screenshot
    // workflow can open a specific tab with `simctl launch ... -uiTab 1`.
    // Without the argument this reads back as 0, the normal first tab.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "uiTab")

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanView()
                .tabItem { Label("Scan", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)

            DeviceView()
                .tabItem { Label("Device", systemImage: "thermometer.medium") }
                .tag(1)

            // The log console ships in debug builds only; the released app has
            // no use for it and it is compiled out entirely.
            #if DEBUG
            DebugConsoleView()
                .tabItem { Label("Log", systemImage: "text.alignleft") }
                .tag(2)
            #endif
        }
        .environmentObject(viewModel)
        .accentColor(.orange)
    }
}
