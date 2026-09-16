import SwiftUI
import UIKit

/// The dial's motion, as physics rather than as animations.
///
/// Every ring on this screen stands for something that is physically happening
/// — an oven climbing, a lung filling, a battery draining, a session getting
/// longer — and none of those things move in fixed-length steps. SwiftUI's
/// implicit animations do: each one eases from wherever it is to a target over
/// a duration and then stops, which is why a ring driven by them reads as a
/// picture being redrawn rather than as an instrument.
///
/// So the dial keeps its own state and advances it once per frame against the
/// real elapsed time. Nothing here has a duration; everything has a rate, and
/// a value is wherever the rate has carried it by now. That is what makes a
/// nine-second draw look different from a two-second one, and what lets a
/// reading arrive late, early or in a burst without the rings stepping.

// MARK: - Primitives

/// A value that chases a target by closing a fixed proportion of the remaining
/// gap per second. Integrated exactly, so it behaves identically at 120, 60 or
/// 8 frames a second — which matters here, because the dial deliberately drops
/// its frame rate when nothing is happening.
struct Follower {
    private(set) var value: Double
    /// Seconds to close about 63% of the gap. Smaller is tighter.
    var response: Double

    init(_ value: Double = 0, response: Double = 0.3) {
        self.value = value
        self.response = response
    }

    mutating func advance(towards target: Double, dt: Double) {
        guard response > 0.0001, dt > 0 else {
            if response <= 0.0001 { value = target }
            return
        }
        value += (target - value) * (1 - exp(-dt / response))
    }

    mutating func reset(to newValue: Double) { value = newValue }

    func isSettled(at target: Double, epsilon: Double = 0.003) -> Bool {
        abs(target - value) <= epsilon
    }
}

/// A damped spring. Used where a movement should land rather than arrive: the
/// release of a draw settles a hair past rest and comes back, which is what
/// letting go feels like. A `Follower` can only approach, never settle.
struct Spring {
    private(set) var value: Double
    private(set) var velocity: Double = 0
    /// Roughly the period of one oscillation, in seconds.
    var response: Double
    /// 1 is critically damped; below that it overshoots on the way home.
    var damping: Double

    init(_ value: Double = 0, response: Double = 0.4, damping: Double = 0.85) {
        self.value = value
        self.response = response
        self.damping = damping
    }

    mutating func advance(towards target: Double, dt: Double) {
        guard dt > 0 else { return }
        let omega = 2 * Double.pi / max(0.0001, response)
        // Sub-stepped: one big step at a low frame rate would otherwise let the
        // integrator run away, and this dial does run at 8 fps when idle.
        let steps = max(1, min(16, Int((dt / 0.006).rounded(.up))))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let acceleration = -omega * omega * (value - target)
                - 2 * damping * omega * velocity
            velocity += acceleration * h
            value += velocity * h
        }
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }

    func isSettled(at target: Double, epsilon: Double = 0.003) -> Bool {
        abs(target - value) <= epsilon && abs(velocity) <= epsilon * 8
    }
}

/// A sine whose phase is integrated rather than derived from the clock.
///
/// This is the whole reason the battery's breath can speed up as it drains: a
/// wave computed as `sin(now * frequency)` jumps the moment the frequency
/// changes, because the same instant now lands at a different point of the
/// cycle. Integrating the phase means the wave carries on from where it is and
/// simply travels faster.
struct Oscillator {
    private(set) var phase: Double = 0

    @discardableResult
    mutating func advance(dt: Double, frequency: Double) -> Double {
        phase += dt * frequency * 2 * .pi
        if phase > 2 * .pi {
            phase -= 2 * .pi * (phase / (2 * .pi)).rounded(.down)
        }
        return sin(phase)
    }

    var sine: Double { sin(phase) }
}

// MARK: - Curves

enum DialCurve {
    static func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
        Swift.min(high, Swift.max(low, value))
    }

    /// Eased 0…1, for staged arrivals.
    static func easeOut(_ t: Double) -> Double {
        let x = clamp(t)
        return 1 - pow(1 - x, 3)
    }

    /// Saturating growth that is always climbing and never arrives: half way at
    /// `halfLife`, three quarters at three times it, nine tenths at nine.
    ///
    /// This is the shape of a breath, and the reason the draw ring keeps
    /// widening for as long as the draw lasts instead of easing to a width and
    /// sitting there. It is bounded, so nothing it drives can overflow the
    /// dial however long the draw goes on.
    static func saturating(_ elapsed: Double, halfLife: Double) -> Double {
        guard elapsed > 0, halfLife > 0 else { return 0 }
        return elapsed / (elapsed + halfLife)
    }

    /// The same idea with a gentler shoulder, for arcs measured in minutes.
    static func compress(_ seconds: Double, tau: Double) -> Double {
        guard seconds > 0, tau > 0 else { return 0 }
        return 1 - exp(-seconds / tau)
    }

    /// Smooth 0…1 ramp between two thresholds, in either direction.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard from != to else { return value >= to ? 1 : 0 }
        let t = clamp((value - from) / (to - from))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Colours

/// The dial's colours resolved for the current appearance.
///
/// `Canvas` draws from numbers, not from views, so the dynamic colours in
/// `DS.Palette` are flattened here once per render against the scheme in the
/// environment. Doing it here also makes blending possible — SwiftUI has no
/// colour mixing on iOS 16, and the battery has to travel from grey through
/// amber to red without a step anywhere along the way.
struct DialPalette {
    let accent: Color
    let track: Color
    let trackSoft: Color
    let beyondMax: Color
    let batteryCalm: Color
    let batteryWarn: Color
    let batteryLow: Color
    let charge: Color
    let marker: Color
    let markerShadow: Color
    let session: Color
    let tick: Color

    private let scheme: ColorScheme

    init(scheme: ColorScheme, accent: Color) {
        self.scheme = scheme
        self.accent = accent
        self.track = DialPalette.flatten(DS.Palette.track, scheme)
        self.trackSoft = DialPalette.flatten(DS.Palette.track, scheme).opacity(0.5)
        self.beyondMax = Color.orange.opacity(0.22)
        self.batteryCalm = scheme == .dark
            ? Color(red: 0.56, green: 0.56, blue: 0.60)
            : Color(red: 0.47, green: 0.47, blue: 0.50)
        self.batteryWarn = Color(red: 1, green: 0.68, blue: 0.12)
        self.batteryLow = DS.Palette.low
        self.charge = DS.Palette.charge
        self.marker = .white
        self.markerShadow = Color.black.opacity(0.22)
        self.session = scheme == .dark
            ? Color(red: 0.56, green: 0.56, blue: 0.60)
            : Color(red: 0.47, green: 0.47, blue: 0.50)
        self.tick = scheme == .dark
            ? Color(red: 0.56, green: 0.56, blue: 0.60)
            : Color(red: 0.47, green: 0.47, blue: 0.50)
    }

    /// Resolves a dynamic colour against one appearance so it can be drawn and
    /// blended as plain numbers.
    private static func flatten(_ color: Color, _ scheme: ColorScheme) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        return Color(uiColor: resolved)
    }

    func components(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &a)
            return (Double(white), Double(white), Double(white), Double(a))
        }
        return (Double(r), Double(g), Double(b), Double(a))
    }

    /// Linear blend, resolved for the current appearance first so a dynamic
    /// colour mixes with a fixed one without either losing its scheme.
    func mix(_ from: Color, _ to: Color, _ amount: Double) -> Color {
        let t = DialCurve.clamp(amount)
        guard t > 0 else { return from }
        guard t < 1 else { return to }
        let a = components(from), b = components(to)
        return Color(.sRGB,
                     red: a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue: a.b + (b.b - a.b) * t,
                     opacity: a.a + (b.a - a.a) * t)
    }

    /// Lifts a colour towards white, for the brightening under a draw.
    func brighten(_ color: Color, _ amount: Double) -> Color {
        mix(color, .white, DialCurve.clamp(amount) * 0.5)
    }
}

// MARK: - Input

/// Everything the rings are drawn from, gathered once per frame.
struct DialInput: Equatable {
    var current: Double?
    var target: Double = DS.Range.min
    var batteryLevel: Int?
    var isCharging: Bool = false
    var heatingState: PaxHeatingState?
    var drawStartedAt: Date?
    var isScrubbing: Bool = false

    /// The running session, if there is one.
    var sessionStartedAt: Date?
    var sessionDraws: Int = 0
    /// When each draw happened, in seconds from the session's start.
    var drawMarks: [TimeInterval] = []
    var lastDrawAt: Date?
    var autoOffEnabled: Bool = false
    var autoOffMinutes: Int = 8

    /// The charge in progress, if the PAX is on the dock.
    var chargeStartedAt: Date?
    /// When each ten-percent step was crossed, in seconds from the start.
    var chargeMarks: [TimeInterval] = []

    /// True while anything on the dial is expected to be moving on its own.
    /// The frame rate follows it, so an idle dial costs almost nothing.
    var isLively: Bool {
        if isScrubbing || isCharging { return true }
        if heatingState == .boosting || heatingState == .heating { return true }
        if sessionStartedAt != nil || chargeStartedAt != nil { return true }
        if let level = batteryLevel, level <= 60, !isCharging { return true }
        return false
    }
}

// MARK: - Frame

/// One rendered instant. Plain numbers: the view draws it and keeps no state.
struct DialFrame {
    var revealTrack: Double = 0
    var revealWarm: Double = 0
    var revealBattery: Double = 0
    var revealTime: Double = 0
    var revealTicks: Double = 0
    var revealMarker: Double = 0

    // Oven
    var heatTrim: Double = 0
    var heatRadius: CGFloat = DS.Dial.radius
    var heatStroke: CGFloat = DS.Dial.stroke
    var heatColor: Color = .orange
    var bloom: Double = 0
    var scrubGlow: Double = 0

    // Warm-up
    var warmTrim: Double = 0
    var warmOpacity: Double = 0

    // Battery
    var batteryVisible: Bool = false
    var batteryTrim: Double = 0
    var batteryStroke: CGFloat = 0
    var batteryColor: Color = .gray
    var chargeSpinDegrees: Double = 0
    var chargeHighlight: Double = 0

    // Time ring
    var timePresence: Double = 0
    var timeTrim: Double = 0
    var timeStroke: CGFloat = 0
    var timeColor: Color = .gray
    var timeOpacity: Double = 0
    var beads: [Double] = []
    var fuseStart: Double = 0
    var fuseEnd: Double = 0
    var fuseOpacity: Double = 0

    // Target marker
    var markerAngle: Double = DS.Dial.startAngle
    var markerScale: Double = 1

    /// True when nothing is mid-flight, so the dial can drop its frame rate.
    var isResting: Bool = true
}

// MARK: - Engine

/// Holds the dial's motion between frames.
///
/// A reference type held in `@State` and advanced inside the timeline's body:
/// it publishes nothing, so mutating it cannot invalidate the view that is
/// drawing it, and the whole dial resolves in one pass per frame instead of
/// ten animators racing each other property by property.
final class DialEngine {

    private var lastFrameAt: Date?
    private var appearedAt: Date?

    // Oven
    private var heatTrim = Follower(0, response: 0.42)
    private var lung = Spring(0, response: 0.52, damping: 0.78)
    private var bloom = Follower(0, response: 0.5)
    private var tremor = Oscillator()
    private var scrubGlow = Follower(0, response: 0.16)

    // Warm-up
    private var warmTrim = Follower(0, response: 0.42)
    private var warmOpacity = Follower(0, response: 0.4)

    // Battery
    private var batteryTrim = Follower(0, response: 0.75)
    private var batteryStroke = Follower(Double(DS.Dial.batteryStrokeFull), response: 0.7)
    private var batteryTint = Follower(0, response: 1.1)
    private var batteryBreath = Oscillator()
    private var chargeSpin = Oscillator()
    private var chargeHighlight = Follower(0, response: 0.6)

    // Time ring
    private var timePresence = Follower(0, response: 0.55)
    private var timeTrim = Follower(0, response: 0.7)
    private var timeStroke = Follower(Double(DS.Dial.timeStrokeBase), response: 0.8)
    private var timeWeight = Follower(0, response: 0.9)
    private var drawBump = Follower(0, response: 1.7)
    private var fuse = Follower(1, response: 0.4)
    private var urgencyPulse = Oscillator()
    private var seenMarks = 0
    /// The shape the time ring last had. A session that ends fades out from
    /// where it was rather than snapping back to a hairline on the way.
    private var lastTimeColor: Color = .gray
    private var lastBeads: [Double] = []

    // Marker
    private var markerAngle = Follower(DS.Dial.startAngle, response: 0.09)
    private var markerScale = Spring(1, response: 0.3, damping: 0.7)

    private(set) var isResting = true

    /// Advances every quantity to `now` and returns what to draw.
    func frame(at now: Date, input: DialInput, palette: DialPalette) -> DialFrame {
        if appearedAt == nil {
            appearedAt = now
            seed(input)
        }
        // Clamped: the schedule slows down when the dial is idle and stops
        // entirely when the app is backgrounded, and neither is a reason to
        // integrate a ten-second step the moment it comes back.
        let dt = min(0.1, max(0, now.timeIntervalSince(lastFrameAt ?? now)))
        lastFrameAt = now
        let since = now.timeIntervalSince(appearedAt ?? now)

        // Re-earned every frame: each ring that is still in flight clears it,
        // and the dial keeps asking for frames only while one of them does.
        isResting = since > 0.8

        var out = DialFrame()
        stageReveal(&out, since: since)
        advanceOven(&out, now: now, dt: dt, input: input, palette: palette)
        advanceBattery(&out, dt: dt, input: input, palette: palette)
        advanceTimeRing(&out, now: now, dt: dt, input: input, palette: palette)
        advanceMarker(&out, dt: dt, input: input)

        out.isResting = isResting
        return out
    }

    /// The rings draw themselves on the first time they appear, staggered from
    /// the outside in. It happens whenever the device is picked up, which makes
    /// it the moment in this app most worth spending on.
    private func stageReveal(_ out: inout DialFrame, since: TimeInterval) {
        func stage(_ delay: Double, _ duration: Double) -> Double {
            DialCurve.easeOut((since - delay) / duration)
        }
        out.revealTrack = stage(0, 0.75)
        out.revealWarm = stage(0.12, 0.7)
        out.revealBattery = stage(0.2, 0.7)
        out.revealTime = stage(0.3, 0.7)
        out.revealTicks = stage(0.34, 0.4)
        out.revealMarker = stage(0.28, 0.5)
    }

    /// Starts the followers on the values they should already have, so a dial
    /// that appears with a half-empty battery reveals at that width rather than
    /// growing into it.
    private func seed(_ input: DialInput) {
        if let level = input.batteryLevel {
            let fraction = DialCurve.clamp(Double(level) / 100)
            batteryTrim.reset(to: fraction)
            batteryStroke.reset(to: Double(Self.batteryStrokeTarget(for: input)))
            batteryTint.reset(to: Self.batteryTintTarget(for: input))
        }
        if let celsius = input.current {
            heatTrim.reset(to: DS.Range.fraction(of: celsius))
            warmTrim.reset(to: DS.WarmUp.fraction(of: celsius))
        }
        markerAngle.reset(to: DS.Dial.startAngle + DS.Range.fraction(of: input.target) * DS.Dial.sweep)
    }

    // MARK: Oven and the lung

    private func advanceOven(_ out: inout DialFrame, now: Date, dt: Double,
                             input: DialInput, palette: DialPalette) {
        let celsius = input.current ?? DS.Range.min
        heatTrim.advance(towards: DS.Range.fraction(of: celsius), dt: dt)

        // How far into a draw we are. The width saturates — always climbing,
        // never arriving, and hard-bounded so no draw can push the ring past
        // the dial however long it lasts. Everything else about the swell
        // (bloom, brightness, tremor) keeps growing after the width has all but
        // stopped, which is what carries the feeling of a long pull.
        var drawElapsed: Double = 0
        var lungTarget: Double = 0
        if input.heatingState == .boosting, let started = input.drawStartedAt {
            drawElapsed = max(0, now.timeIntervalSince(started))
            lungTarget = Double(DS.Dial.inhaleSwellMax)
                * DialCurve.saturating(drawElapsed, halfLife: DS.Dial.inhaleHalfLife)
        }
        // Asymmetric on purpose: filling is a pull and should answer at once,
        // letting go is a release and should land.
        let filling = lungTarget > lung.value
        lung.response = filling ? DS.Dial.inhaleAttack : DS.Dial.inhaleRelease
        lung.damping = filling ? 0.95 : 0.72
        lung.advance(towards: lungTarget, dt: dt)

        let bloomTarget = lungTarget > 0
            ? DialCurve.saturating(drawElapsed, halfLife: DS.Dial.bloomHalfLife)
            : 0
        bloom.advance(towards: bloomTarget, dt: dt)

        // A held breath is never perfectly still. Sub-point, and scaled by how
        // full the lung is, so it is absent at rest and only ever a texture.
        let fullness = DialCurve.clamp(lung.value / Double(DS.Dial.inhaleSwellMax))
        let wobble = tremor.advance(dt: dt, frequency: 1.6 + 0.9 * fullness)
            * DS.Dial.inhaleTremor * fullness

        let swell = max(0, lung.value + wobble)
        // The outer edge is pinned and the ring thickens inward. That is what
        // makes an overflow impossible by construction rather than by luck, and
        // it reads better too: the ring fills towards you instead of shoving
        // its way out into the presets.
        out.heatStroke = DS.Dial.stroke + CGFloat(swell)
        out.heatRadius = DS.Dial.outerEdge - out.heatStroke / 2
        out.heatTrim = heatTrim.value
        out.bloom = bloom.value
        out.heatColor = palette.brighten(palette.accent, fullness * 0.55)

        scrubGlow.advance(towards: input.isScrubbing ? 1 : 0, dt: dt)
        out.scrubGlow = scrubGlow.value

        // Below the bottom of the scale the main arc has nothing to draw, so
        // the warm-up ring carries the climb. It hands over rather than
        // vanishing, and stays out of the way of a swelling ring.
        warmTrim.advance(towards: DS.WarmUp.fraction(of: celsius), dt: dt)
        let handover = 1 - DialCurve.ramp(celsius, from: DS.Range.min - 12, to: DS.Range.min)
        warmOpacity.advance(towards: handover, dt: dt)
        out.warmTrim = warmTrim.value
        out.warmOpacity = warmOpacity.value * (1 - fullness)

        if !lung.isSettled(at: lungTarget) || !heatTrim.isSettled(at: DS.Range.fraction(of: celsius)) {
            isResting = false
        }
    }

    // MARK: Battery

    private static func batteryStrokeTarget(for input: DialInput) -> CGFloat {
        guard let level = input.batteryLevel else { return 0 }
        let emptiness = 1 - CGFloat(DialCurve.clamp(Double(level) / 100))
        let resting = DS.Dial.batteryStrokeFull
            + (DS.Dial.batteryStrokeEmpty - DS.Dial.batteryStrokeFull) * emptiness
        return input.isCharging ? max(resting, DS.Dial.batteryStrokeCharging) : resting
    }

    /// 0 is a battery nobody needs to think about; 1 is one about to stop.
    private static func batteryTintTarget(for input: DialInput) -> Double {
        guard let level = input.batteryLevel, !input.isCharging else { return 0 }
        return DialCurve.ramp(Double(level), from: 45, to: 8)
    }

    private func advanceBattery(_ out: inout DialFrame, dt: Double,
                                input: DialInput, palette: DialPalette) {
        guard let level = input.batteryLevel else {
            out.batteryVisible = false
            return
        }
        out.batteryVisible = true
        let fraction = DialCurve.clamp(Double(level) / 100)
        batteryTrim.advance(towards: fraction, dt: dt)

        let strokeTarget = Double(Self.batteryStrokeTarget(for: input))
        batteryStroke.advance(towards: strokeTarget, dt: dt)

        let tintTarget = Self.batteryTintTarget(for: input)
        batteryTint.advance(towards: tintTarget, dt: dt)

        // The breath replaces the blink the ring used to do below 15%. A full
        // battery is genuinely still; from about 60% down it starts to move,
        // and it breathes deeper and faster the emptier it gets. The phase is
        // integrated, so speeding up never makes the wave jump.
        let effort = input.isCharging ? 0 : DialCurve.ramp(Double(level), from: 60, to: 0)
        let frequency = 1 / (DS.Dial.batteryBreathSlow
            - (DS.Dial.batteryBreathSlow - DS.Dial.batteryBreathFast) * effort)
        let breath = batteryBreath.advance(dt: dt, frequency: frequency)
        let pulse = breath * effort * Double(DS.Dial.batteryBreathDepth)

        out.batteryTrim = batteryTrim.value
        out.batteryStroke = max(0, CGFloat(batteryStroke.value + pulse))

        if input.isCharging {
            out.batteryColor = palette.charge
        } else {
            let warm = palette.mix(palette.batteryCalm, palette.batteryWarn,
                                   DialCurve.clamp(batteryTint.value * 1.6))
            out.batteryColor = palette.mix(warm, palette.batteryLow,
                                           DialCurve.ramp(batteryTint.value, from: 0.55, to: 1))
        }

        // Charging is current moving, not a level rising, so the highlight
        // travels and nothing about it changes length. It hurries when the
        // battery is empty and calms down as it fills, then bows out at full.
        chargeHighlight.advance(towards: input.isCharging && level < 100 ? 1 : 0, dt: dt)
        let revolutions = 1 / (DS.Dial.chargeSpinSlow
            - (DS.Dial.chargeSpinSlow - DS.Dial.chargeSpinFast) * (1 - fraction))
        chargeSpin.advance(dt: dt, frequency: input.isCharging ? revolutions : 0)
        out.chargeSpinDegrees = chargeSpin.phase * 180 / .pi
        out.chargeHighlight = chargeHighlight.value

        if !batteryTrim.isSettled(at: fraction) || !batteryStroke.isSettled(at: strokeTarget)
            || effort > 0.01 || input.isCharging {
            isResting = false
        }
    }

    // MARK: The time ring

    private func advanceTimeRing(_ out: inout DialFrame, now: Date, dt: Double,
                                 input: DialInput, palette: DialPalette) {
        // One lane, two meanings. The PAX is either in a session or on the
        // charger and never both, so the ring that times a sitting is the same
        // ring that times a charge — which costs the dial no room at all.
        let charging = input.isCharging && input.chargeStartedAt != nil
        let start = charging ? input.chargeStartedAt : input.sessionStartedAt
        let marks = charging ? input.chargeMarks : input.drawMarks

        timePresence.advance(towards: start == nil ? 0 : 1, dt: dt)
        out.timePresence = timePresence.value
        guard let start else {
            // Fades out and keeps its shape on the way, rather than snapping
            // to nothing the moment the oven goes off.
            out.timeTrim = timeTrim.value
            out.timeStroke = CGFloat(timeStroke.value)
            out.timeOpacity = timePresence.value
            out.timeColor = lastTimeColor
            out.beads = lastBeads
            if timePresence.value > 0.01 { isResting = false }
            return
        }

        let elapsed = max(0, now.timeIntervalSince(start))
        let window = Double(max(1, input.autoOffMinutes)) * 60

        // The arc is a timeline: it never resets and it never fills, so the
        // beads standing on it keep meaning what they meant when they landed.
        let tau = charging
            ? DS.Dial.chargeTau
            : (input.autoOffEnabled ? window * 1.5 : DS.Dial.sessionTau)
        timeTrim.advance(towards: DialCurve.compress(elapsed, tau: tau), dt: dt)

        // Weight is the other half of the reading: a long sitting with a lot of
        // draws in it is a heavy line, and every draw lands as a bump on top of
        // a baseline that only rises.
        if marks.count > seenMarks {
            seenMarks = marks.count
            drawBump.reset(to: 1)
        } else if marks.count < seenMarks {
            seenMarks = marks.count
        }
        drawBump.advance(towards: 0, dt: dt)

        let byTime = DialCurve.compress(elapsed, tau: charging ? DS.Dial.chargeWeightTau
                                                              : DS.Dial.sessionWeightTau)
        let byDraws = charging ? 0 : DialCurve.compress(Double(input.sessionDraws), tau: 6)
        let weight = Double(DS.Dial.timeStrokeByTime) * byTime
            + Double(DS.Dial.timeStrokeByDraws) * byDraws
        timeWeight.advance(towards: weight, dt: dt)
        let stroke = Double(DS.Dial.timeStrokeBase) + timeWeight.value
            + Double(DS.Dial.timeStrokeDrawBump) * drawBump.value

        let width = min(Double(DS.Dial.timeStrokeMax), stroke)
        timeStroke.reset(to: width)
        out.timeTrim = timeTrim.value
        out.timeStroke = CGFloat(width)
        out.timeOpacity = timePresence.value
        out.beads = marks.map { DialCurve.compress(max(0, $0), tau: tau) }
        lastBeads = out.beads

        if charging {
            out.timeColor = palette.charge
            lastTimeColor = out.timeColor
            out.fuseOpacity = 0
            isResting = false
            return
        }

        // The fuse: the bright segment at the leading edge is what is left of
        // the auto-off window, and a draw refills it. The countdown sits where
        // the eye already is instead of asking for a ring of its own.
        let idle = now.timeIntervalSince(input.lastDrawAt ?? start)
        let remaining = input.autoOffEnabled
            ? DialCurve.clamp(1 - idle / window)
            : 1
        fuse.advance(towards: remaining, dt: dt)

        let urgency = input.autoOffEnabled
            ? DialCurve.ramp(fuse.value, from: 0.28, to: 0.02)
            : 0
        let breath = urgencyPulse.advance(dt: dt, frequency: 0.55 + 0.6 * urgency)
        let deep = DialCurve.compress(elapsed, tau: DS.Dial.sessionWeightTau)

        let base = palette.mix(palette.session, palette.accent, 0.35 + 0.65 * deep)
        out.timeColor = palette.mix(base, palette.batteryLow, urgency * 0.85)
        lastTimeColor = out.timeColor
        out.timeOpacity = timePresence.value * (1 - 0.22 * urgency * (0.5 + 0.5 * breath))

        if input.autoOffEnabled {
            let length = DS.Dial.fuseSweep / DS.Dial.sweep * fuse.value
            out.fuseEnd = timeTrim.value
            out.fuseStart = max(0, timeTrim.value - length)
            out.fuseOpacity = timePresence.value * DialCurve.clamp(fuse.value * 3)
        }
        isResting = false
    }

    // MARK: Marker

    private func advanceMarker(_ out: inout DialFrame, dt: Double, input: DialInput) {
        let angle = DS.Dial.startAngle + DS.Range.fraction(of: input.target) * DS.Dial.sweep
        if input.isScrubbing {
            // A drag has to track the finger exactly; anything easing it lags.
            markerAngle.reset(to: angle)
        } else {
            markerAngle.advance(towards: angle, dt: dt)
            if !markerAngle.isSettled(at: angle, epsilon: 0.05) { isResting = false }
        }
        markerScale.advance(towards: input.isScrubbing ? 1.3 : 1, dt: dt)
        if !markerScale.isSettled(at: input.isScrubbing ? 1.3 : 1) { isResting = false }

        out.markerAngle = markerAngle.value
        out.markerScale = markerScale.value
    }
}
