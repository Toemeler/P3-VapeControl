import Foundation

/// What the link is actually doing, measured rather than assumed.
///
/// Every attribute this app reads costs a notification and then a read, so the
/// rate of readings is a property of the connection — its interval, the phone's
/// scheduling, how fast the device turns a request around — and not something
/// worth guessing at from the outside. An earlier version of this app set its
/// poll rate from one afternoon's measurement written into a constant. That
/// constant then *became* the ceiling, which is a bad way to find out what a
/// link can do.
///
/// So: count it, continuously, and let the poll run at whatever the numbers
/// say. Written from the Bluetooth queue and read from anywhere, which is why
/// it is a lock around plain values rather than an actor — the Bluetooth
/// callback must never wait on anything.
final class LinkStats: @unchecked Sendable {
    private let lock = NSLock()
    private var replyTimes: [CFAbsoluteTime] = []
    private var notificationTimes: [CFAbsoluteTime] = []
    /// Notification to read, which is the turnaround this app controls.
    private var turnarounds: [Double] = []
    private var pendingNotification: CFAbsoluteTime?

    /// Two minutes of history: long enough to be stable, short enough to follow
    /// the link changing — which it does, when the phone is busy or the device
    /// moves out of a pocket.
    private static let window: CFAbsoluteTime = 120
    private static let maxSamples = 600

    func noteNotification() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        notificationTimes.append(now)
        pendingNotification = now
        trimLocked(now)
        lock.unlock()
    }

    func noteReply() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        replyTimes.append(now)
        if let pending = pendingNotification {
            turnarounds.append(now - pending)
            if turnarounds.count > Self.maxSamples { turnarounds.removeFirst() }
            pendingNotification = nil
        }
        trimLocked(now)
        lock.unlock()
    }

    private func trimLocked(_ now: CFAbsoluteTime) {
        let cutoff = now - Self.window
        while let first = replyTimes.first, first < cutoff { replyTimes.removeFirst() }
        while let first = notificationTimes.first, first < cutoff { notificationTimes.removeFirst() }
    }

    struct Snapshot {
        /// Readings a second, over the window.
        let repliesPerSecond: Double
        /// Median gap between consecutive readings, in milliseconds. This is
        /// the number that decides how fast the dial can move.
        let medianGapMs: Double
        let fastestGapMs: Double
        /// Median time from "there is something to read" to the bytes arriving.
        let medianTurnaroundMs: Double
        let sampleCount: Int

        var isMeaningful: Bool { sampleCount >= 8 }
    }

    var snapshot: Snapshot {
        lock.lock()
        let replies = replyTimes
        let turns = turnarounds
        lock.unlock()

        guard replies.count >= 2 else {
            return Snapshot(repliesPerSecond: 0, medianGapMs: 0, fastestGapMs: 0,
                            medianTurnaroundMs: 0, sampleCount: replies.count)
        }
        var gaps: [Double] = []
        for index in 1..<replies.count {
            gaps.append((replies[index] - replies[index - 1]) * 1000)
        }
        let span = replies[replies.count - 1] - replies[0]
        return Snapshot(
            repliesPerSecond: span > 0 ? Double(replies.count - 1) / span : 0,
            medianGapMs: Self.median(gaps),
            fastestGapMs: gaps.min() ?? 0,
            medianTurnaroundMs: Self.median(turns.map { $0 * 1000 }),
            sampleCount: replies.count)
    }

    func reset() {
        lock.lock()
        replyTimes.removeAll()
        notificationTimes.removeAll()
        turnarounds.removeAll()
        pendingNotification = nil
        lock.unlock()
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
