import Foundation
import WatchConnectivity

/// The phone's end of the watch link.
///
/// The phone is the only thing that talks to the PAX — it holds the connection,
/// the derived key and the background reconnect — so the watch asks and this
/// answers. Every command arrives as one of a handful of named strings and is
/// checked here before it reaches the view model; nothing from the watch is
/// handed through unexamined.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    static let shared = PhoneLink()

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private var lastPushed: Data?

    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Pushes the current state to the watch. Called on the same beat as the
    /// Lock Screen card and the widget, and skips a push when nothing changed —
    /// the watch redraws on receipt, and redrawing the same numbers costs
    /// battery on the smallest battery in the room.
    func push(_ snapshot: PaxSnapshot, profiles: [String]) {
        guard let session, session.activationState == .activated else { return }
        var comparable = snapshot
        comparable.updatedAt = .distantPast
        guard let payload = try? JSONEncoder().encode(comparable) else { return }
        guard payload != lastPushed else { return }
        lastPushed = payload
        guard let full = try? JSONEncoder().encode(snapshot) else { return }
        let context: [String: Any] = [
            PaxWatchMessage.snapshotKey: full,
            "profiles": profiles,
        ]
        if session.isReachable {
            session.sendMessage(context, replyHandler: nil, errorHandler: nil)
        }
        // The context survives the watch app being closed and is what it reads
        // on next launch, so it is set whether or not the watch is listening.
        try? session.updateApplicationContext(context)
    }

    // MARK: - Commands

    private func handle(_ message: [String: Any]) -> [String: Any] {
        let viewModel = PaxDeviceViewModel.shared
        if let raw = message[PaxWatchMessage.commandKey] as? String,
           let command = PaxWatchMessage.Command(rawValue: raw) {
            switch command {
            case .requestState:
                break
            case .setTemperature:
                if let celsius = message[PaxWatchMessage.valueKey] as? Double {
                    viewModel.setCustomTemperature(clamped(celsius))
                }
            case .stepTemperature:
                if let delta = message[PaxWatchMessage.valueKey] as? Double {
                    let base = viewModel.targetTempC ?? viewModel.customTargetTempC
                    viewModel.setCustomTemperature(clamped(base + delta))
                }
            case .ovenOn:
                viewModel.setOvenEnabled(true, reason: "from the watch")
            case .ovenOff:
                viewModel.setOvenEnabled(false, reason: "from the watch")
            case .applyProfile:
                if let name = message[PaxWatchMessage.valueKey] as? String,
                   let profile = AppSettings.shared.profiles.first(where: { $0.name == name }) {
                    viewModel.apply(profile)
                }
            }
        }
        return reply()
    }

    /// The dial's range, applied here as well as on the phone's own controls: a
    /// value arriving over the link is input like any other.
    private func clamped(_ celsius: Double) -> Double {
        min(DS.Range.max, max(DS.Range.min, celsius.rounded()))
    }

    private func reply() -> [String: Any] {
        var payload: [String: Any] = ["profiles": AppSettings.shared.profiles.map(\.name)]
        if let snapshot = PaxSharedStore.read(),
           let data = try? JSONEncoder().encode(snapshot) {
            payload[PaxWatchMessage.snapshotKey] = data
        }
        return payload
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Reactivated rather than left dormant: a phone can be paired to a new
    /// watch, and the session has to be brought back for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            replyHandler(self.handle(message))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in _ = self.handle(message) }
    }
}
