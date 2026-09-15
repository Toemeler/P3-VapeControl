import Foundation
import UserNotifications

/// Tells the user the oven has come up to temperature.
///
/// The app is usually not on screen when that happens — the whole point of the
/// Lock Screen card is that you put the phone down — so this is a local
/// notification rather than anything in the UI. It fires from the same
/// background BLE callbacks that keep the card up to date.
@MainActor
final class ReadyNotifier {
    static let shared = ReadyNotifier()

    /// The state the last notification was sent for, so one heat-up produces
    /// one notification however many times the device repeats itself.
    private var notifiedForThisHeatUp = false
    private var authorizationAsked = false

    private init() {}

    /// Asks once, the first time the setting is on and a device is connected.
    /// Deliberately not at launch: a permission sheet before the app has done
    /// anything is the kind of thing people deny out of hand.
    func requestAuthorizationIfNeeded() {
        guard !authorizationAsked else { return }
        authorizationAsked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call on every heating-state report. The notification goes out on the
    /// edge into `ready`, and arms again once the PAX starts heating afresh.
    func handle(state: PaxHeatingState?, targetC: Double?, useFahrenheit: Bool) {
        switch state {
        case .heating:
            notifiedForThisHeatUp = false
        case .ready:
            guard !notifiedForThisHeatUp else { return }
            notifiedForThisHeatUp = true
            send(targetC: targetC, useFahrenheit: useFahrenheit)
        default:
            break
        }
    }

    /// A disconnect ends the session: the next heat-up should notify again.
    func reset() {
        notifiedForThisHeatUp = false
    }

    private func send(targetC: Double?, useFahrenheit: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "PAX is ready"
        if let target = targetC {
            let value = useFahrenheit ? target * 9 / 5 + 32 : target
            content.body = String(format: "Up to %.0f°%@.", value, useFahrenheit ? "F" : "C")
        } else {
            content.body = "Up to temperature."
        }
        content.sound = .default
        // nil trigger: deliver now. The app may be in the background, which is
        // exactly when this matters.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
