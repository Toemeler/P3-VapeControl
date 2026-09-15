import AppIntents

/// Siri phrases and the Shortcuts gallery entries. App-target only: a shortcut
/// provider belongs to the app, not to its widget extension.
///
/// `shortTitle` and `systemImageName` arrived in iOS 16.4, a little after this
/// app's 16.2 floor, so the whole provider is gated rather than the app's
/// deployment target being raised for it.
@available(iOS 16.4, *)
struct PaxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetPaxTemperatureIntent(),
            phrases: [
                "Set the temperature in \(.applicationName)",
                "Set my \(.applicationName) temperature",
            ],
            shortTitle: "Set temperature",
            systemImageName: "thermometer.medium")

        AppShortcut(
            intent: SetPaxModeIntent(),
            phrases: [
                "Set the mode in \(.applicationName)",
                "Change my \(.applicationName) heating mode",
            ],
            shortTitle: "Set heating mode",
            systemImageName: "dial.medium")

        AppShortcut(
            intent: PaxStatusIntent(),
            phrases: [
                "Check my \(.applicationName)",
                "What is my \(.applicationName) doing",
            ],
            shortTitle: "Check the PAX",
            systemImageName: "bolt.heart")
    }
}
