#if PAX_LAB
import Combine
import Foundation

/// The lab build's notebook.
///
/// Everything the device says is recorded here, not just what the app knows how
/// to use, and every experiment is written down before it is run — including
/// the ones that take the device offline, which is the whole reason this exists
/// as a separate build. A write that precedes a disconnect is the single most
/// useful thing to know about an undocumented attribute, and it is only useful
/// if it survives the crash, so the write log is persisted the moment a write
/// leaves rather than when it is judged.
@MainActor
final class PaxLab: ObservableObject {
    static let shared = PaxLab()

    /// A reading of every attribute at one moment, under a label the user gave
    /// it — "heating", "on charger", "lid off". Two of these and a diff is how
    /// an undecoded attribute gives up which byte means what.
    struct Snapshot: Identifiable, Codable {
        var id = UUID()
        var label: String
        var takenAt: Date
        /// Attribute number (as a decimal string, so this encodes) to payload hex.
        var values: [String: String]
    }

    struct WriteRecord: Identifiable, Codable {
        var id = UUID()
        var at: Date
        var attribute: UInt8
        var payloadHex: String
        var outcome: Outcome

        enum Outcome: String, Codable {
            case pending
            case survived
            case deviceDropped
            case reportedBack
        }
    }

    /// Every payload seen this session, per attribute. Several samples of the
    /// same attribute differ only in the uninitialised buffer past the payload,
    /// so what they share is the payload.
    @Published private(set) var samples: [UInt8: [Data]] = [:]
    @Published private(set) var snapshots: [Snapshot] = []
    @Published private(set) var writes: [WriteRecord] = []
    @Published private(set) var sweepInProgress = false
    @Published var deviceSummary = ""

    private let defaults = UserDefaults.standard
    private let writesKey = "labWriteLog"
    private let snapshotsKey = "labSnapshots"
    private var survivalTimer: Task<Void, Never>?

    private init() {
        writes = decode([WriteRecord].self, from: writesKey) ?? []
        snapshots = decode([Snapshot].self, from: snapshotsKey) ?? []
    }

    // MARK: - Recording

    func record(type: UInt8, payload: Data) {
        var list = samples[type] ?? []
        list.append(payload)
        // Three is enough to separate payload from padding; keeping more just
        // grows without telling us anything new.
        if list.count > 6 { list.removeFirst(list.count - 6) }
        samples[type] = list

        if let index = writes.lastIndex(where: { $0.attribute == type && $0.outcome == .pending }) {
            let wanted = writes[index].payloadHex
            if Self.hex(payload).hasPrefix(wanted) {
                writes[index].outcome = .reportedBack
                persistWrites()
            }
        }
    }

    /// What the samples of an attribute agree on: its payload, without the
    /// noise behind it.
    func stable(_ attribute: UInt8) -> Data? {
        guard let list = samples[attribute], let first = list.first else { return nil }
        guard list.count > 1 else { return first }
        var shortest = first
        for sample in list.dropFirst() {
            var length = 0
            while length < min(shortest.count, sample.count),
                  shortest[shortest.startIndex + length] == sample[sample.startIndex + length] {
                length += 1
            }
            shortest = Data(shortest.prefix(length))
        }
        return shortest
    }

    var answeredAttributes: [UInt8] { samples.keys.sorted() }

    func setSweeping(_ running: Bool) { sweepInProgress = running }

    func forgetSamples() { samples.removeAll() }

    // MARK: - Snapshots

    func takeSnapshot(label: String) {
        var values: [String: String] = [:]
        for attribute in answeredAttributes {
            guard let payload = stable(attribute), !payload.isEmpty else { continue }
            values[String(attribute)] = Self.hex(payload)
        }
        snapshots.append(Snapshot(label: label.isEmpty ? "unlabelled" : label,
                                  takenAt: Date(),
                                  values: values))
        persist(snapshots, key: snapshotsKey)
    }

    func deleteSnapshots() {
        snapshots.removeAll()
        persist(snapshots, key: snapshotsKey)
    }

    /// Attributes whose value differs between two snapshots, which is where the
    /// meaning of an undecoded attribute shows itself.
    func differences(_ a: Snapshot, _ b: Snapshot) -> [(attribute: UInt8, before: String, after: String)] {
        let keys = Set(a.values.keys).union(b.values.keys)
        return keys.compactMap { key -> (UInt8, String, String)? in
            guard let attribute = UInt8(key) else { return nil }
            let before = a.values[key] ?? "—"
            let after = b.values[key] ?? "—"
            guard before != after else { return nil }
            return (attribute, before, after)
        }
        .sorted { $0.0 < $1.0 }
    }

    // MARK: - Writes

    /// Written down before the packet leaves, so a write that kills the link is
    /// still on record when the app comes back.
    func noteWrite(attribute: UInt8, payload: Data) {
        writes.append(WriteRecord(at: Date(),
                                  attribute: attribute,
                                  payloadHex: Self.hex(payload),
                                  outcome: .pending))
        if writes.count > 200 { writes.removeFirst(writes.count - 200) }
        persistWrites()

        survivalTimer?.cancel()
        survivalTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.markSurvived()
        }
    }

    private func markSurvived() {
        guard let index = writes.lastIndex(where: { $0.outcome == .pending }) else { return }
        writes[index].outcome = .survived
        persistWrites()
    }

    /// The link dropped. Anything still pending is the prime suspect.
    func noteDisconnect() {
        survivalTimer?.cancel()
        var changed = false
        for index in writes.indices where writes[index].outcome == .pending {
            writes[index].outcome = .deviceDropped
            changed = true
        }
        if changed { persistWrites() }
    }

    func clearWrites() {
        writes.removeAll()
        persistWrites()
    }

    /// The write that was in flight when the device last went away, if any.
    var lastFatalWrite: WriteRecord? {
        writes.last { $0.outcome == .deviceDropped }
    }

    // MARK: - Report

    /// Everything, as text to paste somewhere useful.
    func report() -> String {
        var out = ["PAX lab report", "Taken \(Date())", deviceSummary, ""]

        out.append("## Attributes answered (\(answeredAttributes.count))")
        for attribute in answeredAttributes {
            guard let payload = stable(attribute) else { continue }
            let name = PaxMessageType(rawValue: attribute).map { "\($0)" } ?? "unnamed"
            let notes = PaxDeviceViewModel.interpretation(of: payload, id: attribute)
            out.append(String(format: "0x%02X %@: %d bytes %@%@",
                              attribute, name, payload.count, Self.hex(payload), notes))
        }

        if !snapshots.isEmpty {
            out.append("")
            out.append("## Snapshots")
            for snapshot in snapshots {
                out.append("- \(snapshot.label) at \(snapshot.takenAt) (\(snapshot.values.count) attributes)")
            }
            if snapshots.count >= 2 {
                let a = snapshots[snapshots.count - 2], b = snapshots[snapshots.count - 1]
                out.append("")
                out.append("### \(a.label) → \(b.label)")
                let diffs = differences(a, b)
                if diffs.isEmpty {
                    out.append("nothing changed")
                } else {
                    for diff in diffs {
                        let name = PaxMessageType(rawValue: diff.attribute).map { "\($0)" } ?? "unnamed"
                        out.append(String(format: "0x%02X %@: %@ → %@",
                                          diff.attribute, name, diff.before, diff.after))
                    }
                }
            }
        }

        if !writes.isEmpty {
            out.append("")
            out.append("## Writes")
            for write in writes {
                let name = PaxMessageType(rawValue: write.attribute).map { "\($0)" } ?? "unnamed"
                out.append(String(format: "0x%02X %@ ← %@ — %@",
                                  write.attribute, name, write.payloadHex, write.outcome.rawValue))
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// "1F 00" or "1f00" alike, so a value can be typed however it was read.
    static func bytes(fromHex text: String) -> Data? {
        let cleaned = text.replacingOccurrences(of: "0x", with: "")
            .filter { $0.isHexDigit }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private func persistWrites() { persist(writes, key: writesKey) }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, from key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
#endif
