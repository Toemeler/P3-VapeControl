import ActivityKit
import Foundation

/// Owns the single always-on Lock Screen activity.
///
/// Deliberately does *not* end the activity when the PAX drops out: iOS only
/// lets an app **start** a Live Activity from the foreground, while background
/// BLE callbacks may only **update** one. Keeping it alive in a "Waiting for
/// PAX…" state means a reconnect that happens while the app is closed can still
/// light the card back up.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<PaxActivityAttributes>?
    private var lastPushed: PaxActivityAttributes.ContentState?

    private init() {
        // An activity outlives the process that started it, so reattach to one
        // left over from a previous launch rather than orphaning it on screen.
        activity = Activity<PaxActivityAttributes>.activities.first
    }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var isRunning: Bool { activity != nil }

    /// Starts the activity if it isn't running, otherwise pushes an update.
    /// Returns false if a start was attempted and refused (the usual cause is
    /// being in the background, which is expected and not an error).
    @discardableResult
    func sync(deviceName: String, state: PaxActivityAttributes.ContentState) -> Bool {
        guard areActivitiesEnabled else { return false }

        if let current = activity {
            guard state != lastPushed else { return true }
            lastPushed = state
            Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
            return true
        }

        do {
            activity = try Activity.request(
                attributes: PaxActivityAttributes(deviceName: deviceName),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastPushed = state
            return true
        } catch {
            activity = nil
            lastPushed = nil
            return false
        }
    }

    /// Only for a deliberate teardown — user disconnected or switched the
    /// feature off. An unexpected BLE drop should keep the card alive.
    func end() {
        guard let current = activity else { return }
        let final = lastPushed
        activity = nil
        lastPushed = nil
        Task {
            let content = final.map { ActivityContent(state: $0, staleDate: nil) }
            await current.end(content, dismissalPolicy: .immediate)
        }
    }
}
