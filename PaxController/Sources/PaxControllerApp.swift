import SwiftUI

@main
struct PaxControllerApp: App {
    /// Done here rather than in a view's `onAppear`: an intent can launch the
    /// app into the background, where no view ever appears, and the handlers
    /// have to be in place before `perform()` runs.
    init() {
        PaxDeviceViewModel.shared.installIntentHandlers()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
