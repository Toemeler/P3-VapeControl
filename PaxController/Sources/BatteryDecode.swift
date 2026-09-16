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
        /// The distinct payloads themselves, in hex, newest last, and the
        /// battery level each was seen at.
        ///
        /// Counting how many values an attribute took is enough to rule it out
        /// as a constant; it is not enough to work out what it means. A short
        /// attribute that took two values across a charge — ChargeStatus, say —
        /// is decoded by *reading* those two values next to the battery, which
        /// a count cannot give and a shared report should.
        let observed: [String]
        var id: UInt8 { attribute }
    }

    @Published private(set) var running = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var rounds = 0
    @Published private(set) var batterySeen: [Int] = []
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var summaries: [AttributeSummary] = []
    @Published private(set) var note: String?
    /// What the last round actually collected. Visible because a round that
    /// gathers nothing is the difference between "the device has no voltage"
    /// and "this tool is broken", and the first version could not tell them
    /// apart.
    @Published private(set) var lastRoundReplies = 0
    @Published private(set) var lastRoundAttributes = 0

    /// Attributes worth asking for: the ones the device said it implements,
    /// plus a few it does not advertise but might still answer — `0x1A` above
    /// all, which is unnamed even in PAX's own app and is the likeliest place
    /// for something undocumented to be.
    ///
    /// Not all sixty-three. Asking for every address three times is 189 replies
    /// against a link that carries a handful a second, which is more than a
    /// round can collect — the first version did exactly that and threw away
    /// nearly everything it asked for.
    private var watched: [UInt8] {
        let supported = PaxDeviceViewModel.shared.supportedAttributes
        let extras: Set<UInt8> = [0x1A, 0x04, 0x05, 0x12, 0x24, 0x29, 0x2A]
        guard !supported.isEmpty else { return Array(extras).sorted() }
        return Array(supported.union(extras)).sorted()
    }

    /// How often a round starts, on top of however long the round itself took.
    /// A voltage does not need watching faster than this, and the app is still
    /// polling the temperature on the same link.
    private static let roundInterval: TimeInterval = 10
    /// Attributes per request. One StatusUpdate can name many, and each one
    /// named costs a reply.
    private static let batchWidth = 8
    /// Three reads of every attribute, each pass sent only once the last one
    /// has been answered. Whatever all three agree on is payload; the rest is
    /// the uninitialised buffer behind it.
    private static let readsPerRound = 3
    /// How long the replies to one batch have to stop arriving before the next
    /// batch is sent.
    private static let quietPeriod: TimeInterval = 1.5
    /// An absolute ceiling on that wait, because the interesting case is a
    /// device that answers only *some* of what it was asked: without a ceiling,
    /// a batch waits forever for a reply that is never coming.
    ///
    /// The ceiling, and counting only the replies a round asked for, are
    /// between them why this now finishes at all. The previous version waited
    /// for the whole link to go quiet — but the app's own temperature poll
    /// never stops, so the link was never quiet, the wait never ended, and not
    /// one round ever closed. Seven minutes of running reported nothing
    /// because nothing had been counted, not because the device had nothing
    /// to say.
    private static let maxPassWait: TimeInterval = 12

    private var history: [UInt8: [Round]] = [:]
    private var inFlight: [UInt8: [Data]] = [:]
    /// What this round asked for, so an answer can be told apart from the
    /// app's own polling crossing the same link.
    private var wanted: Set<UInt8> = []
    /// Everything that arrived, which is what the screen shows: a round that
    /// collects nothing should say so rather than looking like a device with
    /// nothing to say.
    private var repliesThisRound = 0
    /// Replies to attributes this round is still collecting. Quiet is judged on
    /// this, not on everything that crosses the link.
    private var usefulReplies = 0
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
        wanted = []
        rounds = 0
        repliesThisRound = 0
        usefulReplies = 0
        lastRoundReplies = 0
        lastRoundAttributes = 0
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
        let list = watched
        guard !list.isEmpty else { return }
        inFlight = [:]
        wanted = Set(list)
        repliesThisRound = 0
        usefulReplies = 0

        for _ in 0..<Self.readsPerRound {
            guard running, !Task.isCancelled else { break }
            // In batches, because the device answers each attribute separately
            // and a request naming eight produces eight replies — and one batch
            // at a time, waiting for its answers before the next goes out.
            //
            // That wait is not politeness, it is flow control. Commands are
            // written without response and nothing checks whether the radio can
            // take another, so four batch writes in a row is four writes into a
            // queue that holds fewer, and the rest are dropped in silence. An
            // earlier run of this decode collected 33 rounds in which exactly
            // one attribute ever answered, which is what that looks like from
            // the outside.
            for batch in stride(from: 0, to: list.count, by: Self.batchWidth) {
                guard running, !Task.isCancelled else { break }
                let slice = Array(list[batch..<min(list.count, batch + Self.batchWidth)])
                viewModel.requestRawAttributes(slice)
                await drain()
            }
        }
        closeRound()
    }

    /// Wait until the replies this round asked for stop arriving, or until the
    /// ceiling, whichever comes first.
    ///
    /// "The replies this round asked for" is doing the work: the app's own
    /// temperature poll never stops, so waiting for the *link* to go quiet is
    /// waiting for something that never happens.
    private func drain() async {
        let deadline = Date().addingTimeInterval(Self.maxPassWait)
        var quietFor = 0.0
        var lastUseful = usefulReplies
        while running, !Task.isCancelled, Date() < deadline, quietFor < Self.quietPeriod {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if usefulReplies == lastUseful {
                quietFor += 0.25
            } else {
                lastUseful = usefulReplies
                quietFor = 0
            }
        }
    }

    /// Called for every decoded reply while a run is going, named or not.
    ///
    /// Most of what crosses this link is the app's own temperature poll rather
    /// than an answer to anything asked here, so only the first few reads of
    /// each attribute are kept: a round wants three reads to compare, and three
    /// dozen temperatures would agree on nothing.
    func record(attribute: UInt8, payload: Data) {
        guard running else { return }
        repliesThisRound += 1
        var reads = inFlight[attribute] ?? []
        guard reads.count < Self.readsPerRound else { return }
        reads.append(payload)
        inFlight[attribute] = reads
        if wanted.contains(attribute) { usefulReplies += 1 }
    }

    private func closeRound() {
        // Counted first and unconditionally. A round that collected nothing is
        // a result — it is how a broken tool is told from a silent device — and
        // the previous version's early return meant the screen said "0 rounds"
        // either way.
        lastRoundReplies = repliesThisRound
        lastRoundAttributes = inFlight.count
        rounds += 1

        let viewModel = PaxDeviceViewModel.shared
        if let battery = viewModel.batteryLevel {
            let charging = viewModel.isCharging == true
            let now = Date()
            for (attribute, reads) in inFlight where reads.count >= 2 {
                let agreed = Self.agreedPrefix(of: reads)
                guard !agreed.isEmpty else { continue }
                history[attribute, default: []].append(
                    Round(at: now, battery: battery, charging: charging, agreed: agreed))
            }
            if !batterySeen.contains(battery) { batterySeen.append(battery) }
            note = inFlight.isEmpty
                ? "The device answered nothing this round — it may have gone to sleep."
                : nil
        } else {
            // Counted, but not kept: a payload with no battery level beside it
            // cannot be judged against the battery afterwards.
            note = "No battery reading yet, so this round was not kept."
        }
        viewModel.log("Battery decode round \(rounds): \(repliesThisRound) replies, \(lastRoundAttributes) attributes",
                      level: .info)
        inFlight = [:]
        wanted = []
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
                changed: payloads.count > 1,
                observed: Self.observedValues(of: entries))
        }
        candidates = findCandidates()
    }

    /// Each distinct payload once, in the order it first appeared, with the
    /// battery level and dock state it was first seen at. Long payloads are
    /// skipped: a 22-byte HeatingParams in a list is noise, and the ones worth
    /// reading by eye are the short flag bytes.
    private static func observedValues(of entries: [Round]) -> [String] {
        guard let width = entries.map(\.agreed.count).max(), width <= 4 else { return [] }
        var seen: Set<Data> = []
        var out: [String] = []
        for entry in entries where !seen.contains(entry.agreed) {
            seen.insert(entry.agreed)
            out.append("\(entry.agreed.hexString) at \(entry.battery)%"
                       + (entry.charging ? " on the dock" : ""))
            if out.count >= 8 { break }
        }
        return out
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
        lines.append("last round collected: \(lastRoundReplies) replies across \(lastRoundAttributes) attributes")
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
            for value in summary.observed {
                lines.append("      \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen

import SwiftUI

/// The decode run, and what it has found so far.
struct BatteryDecodeView: View {
    @ObservedObject private var decoder = BatteryDecoder.shared
    @ObservedObject private var benchmark = LinkBenchmark.shared
    @EnvironmentObject private var viewModel: PaxDeviceViewModel
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                if decoder.running {
                    LabeledContent("Running", value: elapsedText)
                    LabeledContent("Rounds", value: "\(decoder.rounds)")
                    LabeledContent("Last round",
                                   value: "\(decoder.lastRoundReplies) replies · \(decoder.lastRoundAttributes) attributes")
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
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(
                                String(format: "0x%02X %@", summary.attribute, summary.name),
                                value: "\(summary.payloadLength)B · \(summary.distinctValues)"
                                    + (summary.changed ? " ✓" : ""))
                            ForEach(summary.observed, id: \.self) { value in
                                Text(value)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.monospacedDigit())
                    }
                } header: {
                    Text("Everything that answered")
                } footer: {
                    Text("Bytes the reads agreed on, and how many distinct values each has taken. A tick means it has changed at least once — a constant cannot be a voltage. Short attributes list the values themselves next to the battery level they were seen at, which is what a flag byte has to be read against to mean anything.")
                }
            }

            Section {
                if benchmark.running {
                    HStack {
                        ProgressView()
                        Text(benchmark.progress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .destructive) { benchmark.stop() }
                } else {
                    Button("Measure the fastest possible timing") { benchmark.start() }
                        .disabled(!viewModel.canSendCommands)
                }
                if let result = benchmark.result {
                    LabeledContent("Round trip",
                                   value: String(format: "%.0f ms · %.1f/s",
                                                 result.roundTripMedianMs,
                                                 1000 / max(1, result.roundTripMedianMs)))
                    LabeledContent("In a burst",
                                   value: String(format: "%.0f ms · %.1f/s",
                                                 result.burstMedianGapMs,
                                                 1000 / max(1, result.burstMedianGapMs)))
                    Text(result.recommendation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ShareLink(item: benchmark.report) {
                        Label("Share the benchmark", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("How fast can it go")
            } footer: {
                Text("Two ways of asking, timed against each other. One attribute at a time measures a round trip, which is what the app's fast lane does. Eight at once measures whether the device streams replies back to back — if it does, asking for several at a time is free speed, and the app should. Reads only, about a minute.")
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
                    LabeledContent("Asking", value: viewModel.fastLaneDescription)
                } else {
                    Text("Not enough traffic yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Link speed")
            } footer: {
                Text("Measured, not assumed. Every attribute costs a notification and then a read, so the gap between replies is what decides how fast the dial can move — and the poll now runs at whatever this turns out to be rather than at a rate written into the app. Read the rate next to what it says under Asking: while the oven is working there are two requests in the air at once, and while it is idle there is deliberately one, so a round-trip-shaped number here is the loop behaving, not failing. A benchmark run also fills this window with its own one-at-a-time traffic for two minutes afterwards.")
            }

            if decoder.rounds > 0 {
                Section {
                    ShareLink(item: decoder.report) {
                        Label("Share the report", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Link and battery")
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
        if let note = decoder.note {
            return note
        }
        if decoder.running && decoder.rounds == 0 {
            return "Collecting the first round. It takes up to half a minute — if it is still on zero after two, the device has stopped answering."
        }
        if decoder.running && !decoder.hasBatterySpan {
            return "Reading every addressable attribute, three times each, every 30 seconds. Nothing is written. Leave it running while you use the PAX — until the battery has moved at least one step, nothing here can tell a voltage from a number that happens to sit in the right range."
        }
        return "Reads only: the same status request the app already sends. It needs the battery to change to prove anything, so the useful run is a long one — a session or a charge, not a minute."
    }
}
