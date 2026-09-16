import Combine
import Foundation

/// Hunting for a battery voltage the PAX is not advertising.
///
/// The battery attribute (0x03) is one byte, and on this firmware it appears to
/// move in quarters — which is what the device's own four petals show. If a
/// finer reading exists it is somewhere else: a cell voltage in one of the
/// attributes nobody has decoded, including `0x1A`, which is unnamed even in
/// PAX's own app.
///
/// This looks for it by shape rather than by hoping. A single-cell lithium
/// battery lives between roughly 3.0 V and 4.2 V, so a voltage reported over
/// this bus is a 16-bit word around 2800–4400 (millivolts) or 280–440
/// (centivolts), or a byte around 30–42 (tenths). Plenty of things could land
/// in those windows by chance — a clock's low word, a temperature — so a
/// candidate also has to *move the right way*: down while the device is being
/// used, up while it is on the charger. A clock only ever climbs, and climbs
/// whatever the battery is doing, which is what rules it out.
///
/// **Nothing here is written.** Every request is a StatusUpdate read, the same
/// one the app already sends several times a second.
@MainActor
final class BatteryDecoder: ObservableObject {
    static let shared = BatteryDecoder()

    /// One attribute, as it looked in one round of reads.
    private struct Round {
        let at: Date
        let battery: Int
        let charging: Bool
        /// The bytes the reads of this round agreed on — the real payload,
        /// separated from the uninitialised buffer behind it.
        let agreed: Data
    }

    struct Candidate: Identifiable {
        let attribute: UInt8
        let name: String
        /// Where in the payload the number sits, and how wide.
        let offset: Int
        let width: Int
        let unitLabel: String
        let first: Double
        let last: Double
        let movesWithBattery: Bool
        var id: String { "\(attribute)-\(offset)-\(width)" }

        var volts: String {
            String(format: "%.2f V → %.2f V", first, last)
        }

        var headline: String {
            let hex = String(format: "0x%02X", attribute)
            return "\(hex) \(name), byte \(offset) as \(width == 1 ? "a byte" : "a 16-bit word") (\(unitLabel))"
        }
    }

    struct AttributeSummary: Identifiable {
        let attribute: UInt8
        let name: String
        let payloadLength: Int
        let distinctValues: Int
        let changed: Bool
        var id: UInt8 { attribute }
    }

    @Published private(set) var running = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var rounds = 0
    @Published private(set) var batterySeen: [Int] = []
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var summaries: [AttributeSummary] = []
    @Published private(set) var note: String?

    /// Every attribute a status request can reach. Reading one the device does
    /// not implement costs nothing — it simply never answers, and silence is
    /// recorded as silence.
    private static let watched: [UInt8] = Array(1...63)

    /// Slow on purpose. The app is still polling the temperature twice a second
    /// on the same link, and a voltage does not need watching faster than this.
    private static let roundInterval: TimeInterval = 30
    /// Three reads back to back, far enough apart to arrive as separate
    /// replies. Whatever all three agree on is payload; the rest is buffer.
    private static let readsPerRound = 3
    private static let readSpacing: TimeInterval = 1.2

    private var history: [UInt8: [Round]] = [:]
    private var inFlight: [UInt8: [Data]] = [:]
    private var task: Task<Void, Never>?

    var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Whether the run has seen enough of a change in the battery to judge
    /// anything. Without it, a candidate that "falls" may just be drifting.
    var hasBatterySpan: Bool { batterySeen.count >= 2 }

    // MARK: - Running

    func start() {
        guard !running else { return }
        history = [:]
        inFlight = [:]
        rounds = 0
        batterySeen = []
        candidates = []
        summaries = []
        note = nil
        running = true
        startedAt = Date()
        let viewModel = PaxDeviceViewModel.shared
        viewModel.log("Battery decode: reading every addressable attribute three times, every \(Int(Self.roundInterval))s, looking for something shaped like a cell voltage. Nothing is written.",
                      level: .info)
        task = Task { [weak self] in
            while let self, self.running, !Task.isCancelled {
                await self.runRound()
                try? await Task.sleep(nanoseconds: UInt64(Self.roundInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        PaxDeviceViewModel.shared.log("Battery decode: stopped after \(rounds) rounds", level: .info)
    }

    private func runRound() async {
        let viewModel = PaxDeviceViewModel.shared
        guard viewModel.canSendCommands else { return }
        inFlight = [:]
        for _ in 0..<Self.readsPerRound {
            guard running, !Task.isCancelled else { return }
            // In batches, because one request cannot name more than it can fit
            // and the device answers each attribute separately anyway.
            for batch in stride(from: 0, to: Self.watched.count, by: 8) {
                let slice = Array(Self.watched[batch..<min(Self.watched.count, batch + 8)])
                viewModel.requestRawAttributes(slice)
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.readSpacing * 1_000_000_000))
        }
        closeRound()
    }

    /// Called for every decoded reply while a run is going, named or not.
    func note(attribute: UInt8, payload: Data) {
        guard running else { return }
        inFlight[attribute, default: []].append(payload)
    }

    private func closeRound() {
        let viewModel = PaxDeviceViewModel.shared
        guard let battery = viewModel.batteryLevel else { return }
        let charging = viewModel.isCharging == true
        let now = Date()

        for (attribute, reads) in inFlight where reads.count >= 2 {
            let agreed = Self.agreedPrefix(of: reads)
            guard !agreed.isEmpty else { continue }
            history[attribute, default: []].append(
                Round(at: now, battery: battery, charging: charging, agreed: agreed))
        }
        inFlight = [:]
        rounds += 1
        if !batterySeen.contains(battery) { batterySeen.append(battery) }
        recompute()
    }

    /// The longest prefix every read agrees on. The bytes past a payload are
    /// uninitialised and differ on every read, so agreement is what separates
    /// the value from the noise behind it.
    static func agreedPrefix(of reads: [Data]) -> Data {
        guard let first = reads.first else { return Data() }
        var length = first.count
        for read in reads.dropFirst() {
            var shared = 0
            while shared < min(length, read.count), read[read.startIndex + shared] == first[first.startIndex + shared] {
                shared += 1
            }
            length = min(length, shared)
        }
        return Data(first.prefix(length))
    }

    // MARK: - Analysis

    private func recompute() {
        summaries = history.keys.sorted().map { attribute in
            let entries = history[attribute] ?? []
            let payloads = Set(entries.map { $0.agreed })
            return AttributeSummary(
                attribute: attribute,
                name: PaxMessageType(rawValue: attribute).map { "\($0)" } ?? "unnamed",
                payloadLength: entries.map(\.agreed.count).min() ?? 0,
                distinctValues: payloads.count,
                changed: payloads.count > 1)
        }
        candidates = findCandidates()
    }

    /// Every number in every payload, tested against the shape of a cell
    /// voltage and against the direction the battery is going.
    private func findCandidates() -> [Candidate] {
        var found: [Candidate] = []
        for (attribute, entries) in history where entries.count >= 3 {
            let width = entries.map(\.agreed.count).min() ?? 0
            guard width > 0 else { continue }
            let name = PaxMessageType(rawValue: attribute).map { "\($0)" } ?? "unnamed"

            for offset in 0..<width {
                // As a byte, in tenths of a volt.
                let bytes = entries.map { Double($0.agreed[$0.agreed.startIndex + offset]) }
                if let candidate = judge(attribute: attribute, name: name, offset: offset, width: 1,
                                         raw: bytes, scale: 10, unit: "tenths of a volt", entries: entries) {
                    found.append(candidate)
                }
                // As a little-endian 16-bit word, in millivolts and centivolts.
                guard offset + 1 < width else { continue }
                let words = entries.map { entry -> Double in
                    let low = UInt16(entry.agreed[entry.agreed.startIndex + offset])
                    let high = UInt16(entry.agreed[entry.agreed.startIndex + offset + 1])
                    return Double(low | (high << 8))
                }
                if let candidate = judge(attribute: attribute, name: name, offset: offset, width: 2,
                                         raw: words, scale: 1000, unit: "millivolts", entries: entries) {
                    found.append(candidate)
                } else if let candidate = judge(attribute: attribute, name: name, offset: offset, width: 2,
                                                raw: words, scale: 100, unit: "centivolts", entries: entries) {
                    found.append(candidate)
                }
            }
        }
        // The ones that move with the battery first: a value merely sitting in
        // the right range is a coincidence until it behaves like a battery.
        return found.sorted { ($0.movesWithBattery ? 0 : 1) < ($1.movesWithBattery ? 0 : 1) }
    }

    /// A number is a voltage candidate if every reading of it sits in the range
    /// a single cell can be, and it is not pinned to one value.
    private func judge(attribute: UInt8, name: String, offset: Int, width: Int,
                       raw: [Double], scale: Double, unit: String,
                       entries: [Round]) -> Candidate? {
        let volts = raw.map { $0 / scale }
        guard let low = volts.min(), let high = volts.max() else { return nil }
        // 2.8 V is below where a PAX would still run; 4.4 V is above a full
        // cell. Anything outside is not a cell voltage.
        guard low >= 2.8, high <= 4.4 else { return nil }
        // A constant is not a reading.
        guard high - low >= 0.01 else { return nil }

        return Candidate(attribute: attribute, name: name, offset: offset, width: width,
                         unitLabel: unit, first: volts.first ?? 0, last: volts.last ?? 0,
                         movesWithBattery: tracksBattery(volts: volts, entries: entries))
    }

    /// Does it fall as the battery falls, and rise on the charger?
    ///
    /// The battery byte moves in big steps, so this does not ask for
    /// correlation — it asks whether the two ever disagree about direction.
    /// A clock, which climbs regardless, fails on the first discharging round.
    private func tracksBattery(volts: [Double], entries: [Round]) -> Bool {
        var agreements = 0, disagreements = 0
        for index in 1..<min(volts.count, entries.count) {
            let voltageDelta = volts[index] - volts[index - 1]
            guard abs(voltageDelta) > 0.005 else { continue }
            let batteryDelta = entries[index].battery - entries[index - 1].battery
            let charging = entries[index].charging
            let expected: Double = batteryDelta != 0 ? Double(batteryDelta) : (charging ? 1 : -1)
            if (voltageDelta > 0) == (expected > 0) { agreements += 1 } else { disagreements += 1 }
        }
        guard agreements + disagreements >= 3 else { return false }
        return Double(agreements) / Double(agreements + disagreements) >= 0.75
    }

    // MARK: - Report

    var report: String {
        var lines: [String] = []
        lines.append("PAX battery decode")
        lines.append("\(rounds) rounds over \(Int(elapsed / 60)) min")
        lines.append("battery values seen: \(batterySeen.map(String.init).joined(separator: ", "))")
        lines.append("")
        if candidates.isEmpty {
            lines.append("No value in the range of a single cell was found.")
        } else {
            lines.append("Voltage candidates:")
            for candidate in candidates {
                lines.append("  \(candidate.headline) — \(candidate.volts)"
                             + (candidate.movesWithBattery ? "  [tracks the battery]" : "  [does not track]"))
            }
        }
        lines.append("")
        lines.append("Every attribute that answered:")
        for summary in summaries {
            let hex = String(format: "0x%02X", summary.attribute)
            lines.append("  \(hex) \(summary.name): \(summary.payloadLength) byte(s), "
                         + "\(summary.distinctValues) distinct value(s)"
                         + (summary.changed ? ", changed" : ", constant"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen

import SwiftUI

/// The decode run, and what it has found so far.
struct BatteryDecodeView: View {
    @ObservedObject private var decoder = BatteryDecoder.shared
    @EnvironmentObject private var viewModel: PaxDeviceViewModel
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                if decoder.running {
                    LabeledContent("Running", value: elapsedText)
                    LabeledContent("Rounds", value: "\(decoder.rounds)")
                    LabeledContent("Battery seen", value: batteryText)
                    Button("Stop", role: .destructive) { decoder.stop() }
                } else {
                    Button("Start the decode") { decoder.start() }
                        .disabled(!viewModel.canSendCommands)
                    if decoder.rounds > 0 {
                        LabeledContent("Rounds", value: "\(decoder.rounds)")
                        LabeledContent("Battery seen", value: batteryText)
                    }
                }
            } header: {
                Text("Battery decode")
            } footer: {
                Text(runNote)
            }

            if !decoder.candidates.isEmpty {
                Section {
                    ForEach(decoder.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.headline)
                                .font(.subheadline.weight(.medium))
                            Text(candidate.volts)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Label(candidate.movesWithBattery
                                  ? "Moves with the battery"
                                  : "Does not move with the battery",
                                  systemImage: candidate.movesWithBattery ? "checkmark.circle" : "circle")
                                .font(.caption)
                                .foregroundStyle(candidate.movesWithBattery ? Color.green : Color.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Voltage candidates")
                } footer: {
                    Text("A number in the range a single cell can be. Sitting in range is a coincidence until it also falls as the battery falls and rises on the charger — which is what the line under each one says.")
                }
            }

            if !decoder.summaries.isEmpty {
                Section {
                    ForEach(decoder.summaries) { summary in
                        LabeledContent(
                            String(format: "0x%02X %@", summary.attribute, summary.name),
                            value: "\(summary.payloadLength)B · \(summary.distinctValues)"
                                + (summary.changed ? " ✓" : ""))
                            .font(.caption.monospacedDigit())
                    }
                } header: {
                    Text("Everything that answered")
                } footer: {
                    Text("Bytes the reads agreed on, and how many distinct values each has taken. A tick means it has changed at least once — a constant cannot be a voltage.")
                }
            }

            Section {
                let link = BluetoothManager.linkStats.snapshot
                if link.isMeaningful {
                    LabeledContent("Readings a second",
                                   value: String(format: "%.1f", link.repliesPerSecond))
                    LabeledContent("Typical gap",
                                   value: String(format: "%.0f ms", link.medianGapMs))
                    LabeledContent("Best gap",
                                   value: String(format: "%.0f ms", link.fastestGapMs))
                    LabeledContent("Notify to bytes",
                                   value: String(format: "%.0f ms", link.medianTurnaroundMs))
                } else {
                    Text("Not enough traffic yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Link speed")
            } footer: {
                Text("Measured, not assumed. Every attribute costs a notification and then a read, so the gap between replies is what decides how fast the dial can move — and the poll now runs at whatever this turns out to be rather than at a rate written into the app.")
            }

            if decoder.rounds > 0 {
                Section {
                    ShareLink(item: decoder.report) {
                        Label("Share the report", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
    }

    private var elapsedText: String {
        let minutes = Int(decoder.elapsed) / 60
        return minutes < 1 ? "\(Int(decoder.elapsed))s" : "\(minutes) min"
    }

    private var batteryText: String {
        decoder.batterySeen.isEmpty
            ? "—"
            : decoder.batterySeen.map { "\($0)%" }.joined(separator: ", ")
    }

    private var runNote: String {
        guard viewModel.canSendCommands || decoder.running else {
            return "Connect to the PAX to run this."
        }
        if decoder.running && !decoder.hasBatterySpan {
            return "Reading every addressable attribute, three times each, every 30 seconds. Nothing is written. Leave it running while you use the PAX — until the battery has moved at least one step, nothing here can tell a voltage from a number that happens to sit in the right range."
        }
        return "Reads only: the same status request the app already sends. It needs the battery to change to prove anything, so the useful run is a long one — a session or a charge, not a minute."
    }
}
