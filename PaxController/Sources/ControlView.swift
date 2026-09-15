import SwiftUI

/// The app's one screen.
///
/// Everything it draws now comes from the active theme: `ThemedScreen` picks a
/// shell (stacked, chart, field, prose, object or countdown), and the shell
/// picks which hero and which flavour of each control to compose. The layout
/// that used to live here is the `classic` theme — a stacked shell with the arc
/// hero — and is still what a fresh install opens on.
struct ControlView: View {
    @Binding var showDeviceSheet: Bool

    var body: some View {
        ThemedScreen(showDeviceSheet: $showDeviceSheet)
    }
}
