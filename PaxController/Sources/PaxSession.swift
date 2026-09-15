import Combine
import Foundation

/// One heat-up, from the oven waking to it going cold again.
///
/// A PAX 3 has no session log of its own — the log service the official app
/// reads belongs to the Era — so this is the app watching and writing down what
/// it saw. That makes it honest about its limits: a session only exists for the
/// stretch the phone was connected, and a gap in the curve is a gap in the
/// connection, not in the heating.
struct PaxSession: Codable, Identifiable, Equatable {
    /// A point on the temperature curve, stored as seconds from the start so a
    /// session's samples stay small and stay meaningful if it is ever exported.
    struct Sample: Codable, Equatable {
        let at: TimeInterval
        let celsius: Double
    }

    enum Ending: String, Codable {
        case ovenOff, standby, disconnected, autoOff, doseLimit, manual

        var label: String {
            switch self {
            case .ovenOff:      return "Oven off"
            case .standby:      return "Went to standby"
            case .disconnected: return "Lost the connection"
            case .autoOff:      return "Switched off by the timer"
            case .doseLimit:    return "Switched off after the dose"
            case .manual:       return "Switched off from the app"
            }
        }
    }

    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    /// The set point in force when the session started, and the mode with it.
    var setPointC: Double?
    var modeRaw: UInt8?
    var peakTempC: Double?
    var draws: Int
    var samples: [Sample]
    var ending: Ending?

    init(id: UUID = UUID(), startedAt: Date = Date(),
         setPointC: Double? = nil, modeRaw: UInt8? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.setPointC = setPointC
        self.modeRaw = modeRaw
        self.draws = 0
        self.samples = []
    }

    var isRunning: Bool { endedAt == nil }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// How long since the last thing worth calling activity — a draw, or the
    /// start of the session if there has not been one yet. This is what the
    /// auto-off timer counts against, so a session someone is still using never
    /// times out under them.
    func idleSeconds(now: Date = Date(), lastDrawAt: Date?) -> TimeInterval {
        now.timeIntervalSince(lastDrawAt ?? startedAt)
    }

    var durationText: String {
        let total = Int(duration.rounded())
        let minutes = total / 60, seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

/// Where sessions live between launches.
///
/// A JSON file in Application Support rather than UserDefaults: a session with
/// its curve is kilobytes, and hundreds of them do not belong in a plist that
/// is read on every launch and every settings change.
@MainActor
final class PaxSessionStore: ObservableObject {
    static let shared = PaxSessionStore()

    /// Newest first, which is the order everything wants to show them in.
    @Published private(set) var sessions: [PaxSession] = []

    /// Old sessions are worth keeping, but not without limit — this is a
    /// vaporiser app, not an archive. At a handful a day this is well over a
    /// year of history.
    static let maximumSessions = 500

    /// One sample every few seconds is enough to draw a curve that reads the
    /// same as the raw feed, and keeps a long session to a few hundred points.
    static let sampleInterval: TimeInterval = 4

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pax-sessions.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([PaxSession].self, from: data) else { return }
        sessions = stored
    }

    /// Debounced: a running session appends a sample every few seconds, and
    /// rewriting the whole file each time would be wasteful for no benefit.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Recording

    func begin(_ session: PaxSession) {
        sessions.insert(session, at: 0)
        if sessions.count > Self.maximumSessions {
            sessions.removeLast(sessions.count - Self.maximumSessions)
        }
        scheduleSave()
    }

    /// Applies a change to the newest session, if it is still running. Every
    /// update goes through here so a finished session can never be reopened by
    /// a late reading arriving after it ended.
    func updateRunning(_ change: (inout PaxSession) -> Void) {
        guard let first = sessions.first, first.isRunning else { return }
        change(&sessions[0])
        scheduleSave()
    }

    var running: PaxSession? {
        sessions.first.flatMap { $0.isRunning ? $0 : nil }
    }

    func finishRunning(_ ending: PaxSession.Ending, at date: Date = Date()) {
        updateRunning { session in
            session.endedAt = date
            session.ending = ending
        }
        saveTask?.cancel()
        saveNow()
    }

    func delete(_ session: PaxSession) {
        sessions.removeAll { $0.id == session.id }
        saveNow()
    }

    func deleteAll() {
        sessions.removeAll()
        saveNow()
    }

    // MARK: - Totals

    /// Finished sessions only: a session still running would make every total
    /// tick upwards while it is on screen.
    var finished: [PaxSession] { sessions.filter { !$0.isRunning } }

    var totalDraws: Int { finished.reduce(0) { $0 + $1.draws } }

    var totalHeatingMinutes: Int {
        Int(finished.reduce(0) { $0 + $1.duration } / 60)
    }

    func sessions(since date: Date) -> [PaxSession] {
        sessions.filter { $0.startedAt >= date }
    }
}
