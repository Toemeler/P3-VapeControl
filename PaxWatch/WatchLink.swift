import Combine
import Foundation
import WatchConnectivity

/// What the watch and the phone say to each other.
///
/// Deliberately small. The phone pushes its snapshot whenever something
/// changes, and the watch sends one of a handful of commands back. Nothing here
/// knows about Bluetooth, packets or heating parameters — the phone is the only
/// thing that talks to the device, and the watch is a remote for it.
enum PaxWatchMessage {
    static let commandKey = "command"
    static let valueKey = "value"
    static let snapshotKey = "snapshot"

    enum Command: String {
        case requestState
        case setTemperature
        case stepTemperature
        case ovenOn
        case ovenOff
        case applyProfile
    }
}

/// The watch's end of the link.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    @Published private(set) var snapshot: PaxSnapshot?
    /// Profile names, so the watch can offer them without knowing what a
    /// profile contains.
    @Published private(set) var profileNames: [String] = []
    @Published private(set) var reachable = false
    /// Set while a command is in flight, so a tap gives immediate feedback on a
    /// link that may take a moment.
    @Published private(set) var sending = false

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    override init() {
        super.init()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func refresh() {
        send(.requestState)
    }

    func setTemperature(_ celsius: Double) {
        send(.setTemperature, value: celsius)
    }

    func stepTemperature(_ delta: Double) {
        send(.stepTemperature, value: delta)
    }

    func setOven(on: Bool) {
        send(on ? .ovenOn : .ovenOff)
    }

    func applyProfile(named name: String) {
        send(.applyProfile, value: name)
    }

    private func send(_ command: PaxWatchMessage.Command, value: Any? = nil) {
        guard let session, session.activationState == .activated else { return }
        var message: [String: Any] = [PaxWatchMessage.commandKey: command.rawValue]
        if let value { message[PaxWatchMessage.valueKey] = value }
        sending = true
        // A message needs the phone awake and reachable; the transfer falls
        // back to the application context, which the phone picks up the next
        // time it runs. A command that cannot be delivered now is dropped
        // rather than queued, because a temperature that arrives ten minutes
        // late is not what anyone asked for.
        guard session.isReachable else {
            sending = false
            reachable = false
            return
        }
        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.sending = false
                self?.apply(reply)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.sending = false
                self?.reachable = false
            }
        })
    }

    fileprivate func apply(_ payload: [String: Any]) {
        if let data = payload[PaxWatchMessage.snapshotKey] as? Data,
           let decoded = try? JSONDecoder().decode(PaxSnapshot.self, from: data) {
            snapshot = decoded
        }
        if let names = payload["profiles"] as? [String] {
            profileNames = names
        }
        reachable = true
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if state == .activated { self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if session.isReachable { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }
}
