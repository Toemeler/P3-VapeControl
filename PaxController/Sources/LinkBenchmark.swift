import Foundation

/// How fast this link can actually go, measured two ways, because there are two
/// ways to ask and they do not cost the same.
///
/// **Round trip.** Ask for one attribute, wait for the answer, ask again. This
/// is what the app's fast lane does, and what it measures is the time for a
/// request to reach the device and a reply to come back. Nothing the app does
/// can beat it while it asks one question at a time.
///
/// **Burst.** Ask for eight attributes in one request and let the device send
/// eight replies back to back. If the device streams them, the gap between
/// replies is much smaller than a round trip — and then the fast lane should be
/// asking for the temperature, the state and the working target *together*
/// rather than taking turns, because three in a burst would cost less than
/// three round trips.
///
/// The benchmark exists to settle which of those is true on real hardware,
/// rather than reasoning about connection intervals from the outside. It is
/// read-only: every request is a StatusUpdate.
@MainActor
final class LinkBenchmark: ObservableObject {
    static let shared = LinkBenchmark()

    enum Phase: String {
        case idle, roundTrip, burst, done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = ""
    @Published private(set) var result: Result?

    struct Result {
        let roundTripSamples: Int
        let roundTripMedianMs: Double
        let roundTripBestMs: Double
        let burstReplies: Int
        let burstMedianGapMs: Double
        let burstBestGapMs: Double

        /// What one attribute costs in each mode. The comparison is the point:
        /// if a burst reply is much cheaper than a round trip, asking for
        /// several attributes at once is free speed.
        var burstIsCheaper: Bool {
            burstReplies >= 4 && burstMedianGapMs > 0
                && burstMedianGapMs < roundTripMedianMs * 0.7
        }

        var recommendation: String {
            guard roundTripSamples >= 5 else {
                return "Not enough replies to say anything. Run it again with the PAX connected and awake."
            }
            let perSecond = 1000 / max(1, roundTripMedianMs)
            if burstIsCheaper {
                return String(format: """
                    A round trip costs %.0f ms, so asking one attribute at a time tops out near %.1f readings a second. \
                    In a burst the replies arrive %.0f ms apart — %.1f times cheaper — so the fast lane should ask for \
                    the temperature, the oven state and the working target in one request instead of taking turns.
                    """, roundTripMedianMs, perSecond, burstMedianGapMs, roundTripMedianMs / max(1, burstMedianGapMs))
            }
            return String(format: """
                A round trip costs %.0f ms, which is about %.1f readings a second, and replies in a burst arrive \
                %.0f ms apart — no cheaper. The device answers at its own pace whichever way it is asked, so \
                one at a time is the right shape and this is the ceiling.
                """, roundTripMedianMs, perSecond, burstMedianGapMs)
        }
    }

    /// Enough to have a median that means something, short enough that nobody
    /// is left holding the phone.
    private static let roundTrips = 40
    private static let burstRounds = 6
    private static let burstWidth = 8

    private var roundTripTimes: [Double] = []
    private var burstGaps: [Double] = []
    private var awaiting: CFAbsoluteTime?
    private var lastBurstReply: CFAbsoluteTime?
    private var burstRepliesSeen = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?

    var running: Bool { phase == .roundTrip || phase == .burst }

    func start() {
        guard !running else { return }
        let viewModel = PaxDeviceViewModel.shared
        guard viewModel.canSendCommands else { return }
        roundTripTimes = []
        burstGaps = []
        burstRepliesSeen = 0
        result = nil
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation?.resume()
        continuation = nil
        phase = .idle
        progress = ""
    }

    private func run() async {
        let viewModel = PaxDeviceViewModel.shared

        phase = .roundTrip
        for index in 0..<Self.roundTrips {
            guard !Task.isCancelled, viewModel.canSendCommands else { break }
            progress = "Round trip \(index + 1) of \(Self.roundTrips)"
            awaiting = CFAbsoluteTimeGetCurrent()
            viewModel.requestRawAttributes([PaxMessageType.actualTemp.rawValue])
            await waitForReply(timeout: 2)
        }

        phase = .burst
        for index in 0..<Self.burstRounds {
            guard !Task.isCancelled, viewModel.canSendCommands else { break }
            progress = "Burst \(index + 1) of \(Self.burstRounds)"
            lastBurstReply = nil
            // Eight attributes this device is known to answer, so the burst is
            // eight replies rather than however many happen to exist.
            viewModel.requestRawAttributes([
                PaxMessageType.actualTemp.rawValue,
                PaxMessageType.heaterSetPoint.rawValue,
                PaxMessageType.battery.rawValue,
                PaxMessageType.lockStatus.rawValue,
                PaxMessageType.chargeStatus.rawValue,
                PaxMessageType.dynamicMode.rawValue,
                PaxMessageType.currentTargetTemp.rawValue,
                PaxMessageType.heatingState.rawValue,
            ])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        finish()
    }

    private func waitForReply(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let pending = self.continuation else { return }
                // A reply that never came is not a fast one; it is dropped from
                // the sample rather than recorded as the timeout.
                self.continuation = nil
                self.awaiting = nil
                pending.resume()
            }
        }
    }

    /// Every decoded reply, while a run is going.
    func note(attribute: UInt8) {
        guard running else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if phase == .roundTrip, attribute == PaxMessageType.actualTemp.rawValue,
           let sent = awaiting {
            roundTripTimes.append((now - sent) * 1000)
            awaiting = nil
            let pending = continuation
            continuation = nil
            pending?.resume()
            return
        }

        if phase == .burst {
            burstRepliesSeen += 1
            if let last = lastBurstReply {
                let gap = (now - last) * 1000
                // Only gaps inside a burst: the wait between rounds is not a
                // measurement of anything.
                if gap < 800 { burstGaps.append(gap) }
            }
            lastBurstReply = now
        }
    }

    private func finish() {
        phase = .done
        progress = ""
        result = Result(
            roundTripSamples: roundTripTimes.count,
            roundTripMedianMs: Self.median(roundTripTimes),
            roundTripBestMs: roundTripTimes.min() ?? 0,
            burstReplies: burstRepliesSeen,
            burstMedianGapMs: Self.median(burstGaps),
            burstBestGapMs: burstGaps.min() ?? 0)
        PaxDeviceViewModel.shared.log("Link benchmark: \(report)", level: .info)
    }

    var report: String {
        guard let result else { return "No benchmark has been run." }
        let link = BluetoothManager.linkStats.snapshot
        return """
        PAX link benchmark

        One attribute at a time (round trip)
          samples: \(result.roundTripSamples)
          median:  \(String(format: "%.0f ms", result.roundTripMedianMs))
          best:    \(String(format: "%.0f ms", result.roundTripBestMs))
          ceiling: \(String(format: "%.1f readings/s", 1000 / max(1, result.roundTripMedianMs)))

        Eight at once (burst)
          replies: \(result.burstReplies)
          median gap: \(String(format: "%.0f ms", result.burstMedianGapMs))
          best gap:   \(String(format: "%.0f ms", result.burstBestGapMs))
          ceiling:    \(String(format: "%.1f replies/s", 1000 / max(1, result.burstMedianGapMs)))

        While running normally
          \(String(format: "%.1f replies/s", link.repliesPerSecond)), median gap \
        \(String(format: "%.0f ms", link.medianGapMs)), notify to bytes \
        \(String(format: "%.0f ms", link.medianTurnaroundMs))

        \(result.recommendation)
        """
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
