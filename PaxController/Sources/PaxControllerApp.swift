import SwiftUI

@main
struct PaxControllerApp: App {
    /// Done here rather than in a view's `onAppear`: an intent can launch the
    /// app into the background, where no view ever appears, and the handlers
    /// have to be in place before `perform()` runs.
    init() {
        PaxDeviceViewModel.shared.installIntentHandlers()
        // Same reasoning: the watch can wake the app in the background, and the
        // session has to be activated before a message arrives rather than when
        // a view first appears.
        PhoneLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
