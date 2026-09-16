import Combine
import Foundation

/// One charge, from the PAX going on the dock to it coming off again.
///
/// The device reports a level and a charge flag and nothing else — it does not
/// say how long it has been on, or how fast it is filling. So, as with
/// `PaxSession`, this is the app watching and writing down what it saw, which
/// makes it honest about its limits: a charge is only recorded for the stretch
/// the phone was connected, and a gap in the curve is a gap in the connection.
struct PaxCharge: Codable, Identifiable, Equatable {

    /// A level crossing, stored as seconds from the start. Ten of these are
    /// enough to draw the curve and to show, at a glance, where the charge
    /// slowed down — which is the part of a lithium charge worth seeing.
    struct Mark: Codable, Equatable {
        let at: TimeInterval
        let level: Int
    }

    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    let startLevel: Int
    var endLevel: Int
    var marks: [Mark]
    /// True once the device reported a full battery while still on the dock.
    var reachedFull: Bool

    init(id: UUID = UUID(), startedAt: Date = Date(), startLevel: Int) {
        self.id = id
        self.startedAt = startedAt
        self.startLevel = startLevel
        self.endLevel = startLevel
        self.marks = []
        self.reachedFull = false
    }

    var isRunning: Bool { endedAt == nil }

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    var gained: Int { max(0, endLevel - startLevel) }

    var durationText: String { Self.text(for: duration) }

    /// How long it took to reach a level, if it got there at all.
    func seconds(to level: Int) -> TimeInterval? {
        marks.first { $0.level >= level }?.at
    }

    static func text(for seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "\(total)s"
    }
}

/// Where charges live between launches. A sibling of `PaxSessionStore`, in its
/// own file for the same reason: a charge with its curve is kilobytes, and a
/// plist read on every launch is the wrong place for it.
@MainActor
final class PaxChargeStore: ObservableObject {
    static let shared = PaxChargeStore()

    /// Newest first.
    @Published private(set) var charges: [PaxCharge] = []

    /// Charges are rarer than sessions, so fewer of them cover the same span of
    /// time — this is comfortably over a year of daily charging.
    static let maximumCharges = 200

    /// The step between marks. Ten percent is fine enough to show the taper at
    /// the top of a charge and coarse enough that a wobbling reading cannot
    /// scatter beads across the ring.
    static let markStep = 10

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
        return base.appendingPathComponent("pax-charges.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([PaxCharge].self, from: data) else { return }
        charges = stored
    }

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
        guard let data = try? encoder.encode(charges) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Recording

    func begin(_ charge: PaxCharge) {
        charges.insert(charge, at: 0)
        if charges.count > Self.maximumCharges {
            charges.removeLast(charges.count - Self.maximumCharges)
        }
        scheduleSave()
    }

    /// Applies a change to the newest charge, if it is still running, so a
    /// finished one can never be reopened by a late reading.
    func updateRunning(_ change: (inout PaxCharge) -> Void) {
        guard let first = charges.first, first.isRunning else { return }
        change(&charges[0])
        scheduleSave()
    }

    var running: PaxCharge? {
        charges.first.flatMap { $0.isRunning ? $0 : nil }
    }

    func finishRunning(at date: Date = Date()) {
        updateRunning { $0.endedAt = date }
        saveTask?.cancel()
        saveNow()
    }

    func delete(_ charge: PaxCharge) {
        charges.removeAll { $0.id == charge.id }
        saveNow()
    }

    func deleteAll() {
        charges.removeAll()
        saveNow()
    }

    // MARK: - Totals

    var finished: [PaxCharge] { charges.filter { !$0.isRunning } }

    /// Only charges that actually reached the level count towards an average:
    /// a charge someone unplugged at 60% says nothing about how long full takes.
    func averageSeconds(to level: Int) -> TimeInterval? {
        let times = finished.compactMap { $0.seconds(to: level) }
        guard !times.isEmpty else { return nil }
        return times.reduce(0, +) / Double(times.count)
    }

    /// The most recent charges that have a curve worth drawing.
    func recentCurves(limit: Int = 5) -> [PaxCharge] {
        Array(finished.filter { $0.marks.count >= 2 }.prefix(limit))
    }
}
