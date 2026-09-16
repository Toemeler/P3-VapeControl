import SwiftUI

/// The PAX on a wrist.
///
/// The watch has no Bluetooth relationship with the device: the phone holds the
/// connection, and this is a window onto it. That is the honest arrangement —
/// the pairing, the key derivation and the background reconnect all live where
/// the device is already known — and it means the watch says plainly when the
/// phone is out of reach rather than pretending to be in charge.
@main
struct PaxWatchApp: App {
    @StateObject private var link = WatchLink.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(link)
        }
    }
}
