import SwiftUI
import UIKit

/// The thermostat dial: the filled arc is the oven's current temperature, the
/// white marker is where the target sits, and the four dots are the PAX
/// presets. Dragging anywhere on the ring moves the target.
struct TemperatureDial<Center: View>: View {

    /// Live oven temperature. `nil` leaves the arc empty.
    let current: Double?
    /// The target the ring's marker points at.
    let target: Double
    /// Colour of the filled arc.
    let accent: Color
    /// Called continuously while dragging.
    let onScrub: (Double) -> Void
    /// Called once when the finger lifts, so only one packet is written.
    let onCommit: (Double) -> Void
    /// How far apart the readings behind `current` are. The arc interpolates
    /// over slightly longer than this, so it is still travelling towards one
    /// reading when the next arrives.
    let cadence: Double
    /// 0…100. The battery ring's thickness is the reading: a full battery is a
    /// hairline, an empty one is heavy.
    let batteryLevel: Int?
    let isCharging: Bool
    /// Drives the oven ring's swell during a draw.
    let heatingState: PaxHeatingState?
    /// When the current draw began, so the ring's growth is measured against
    /// the draw itself rather than against an animation's own duration.
    let drawStartedAt: Date?
    private let center: Center
    @State private var isScrubbing = false

    init(current: Double?,
         target: Double,
         accent: Color,
         cadence: Double = 1,
         batteryLevel: Int? = nil,
         isCharging: Bool = false,
         heatingState: PaxHeatingState? = nil,
         drawStartedAt: Date? = nil,
         onScrub: @escaping (Double) -> Void,
         onCommit: @escaping (Double) -> Void,
         @ViewBuilder center: () -> Center) {
        self.current = current
        self.target = target
        self.accent = accent
        self.cadence = cadence
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.heatingState = heatingState
        self.drawStartedAt = drawStartedAt
        self.onScrub = onScrub
        self.onCommit = onCommit
        self.center = center()
    }

    /// Long enough to carry the arc into the next reading, short enough that it
    /// is never chasing one that has already been replaced.
    private var travel: Double { min(1.4, cadence * 1.15) }

    /// Drives the highlight that travels around the battery ring while it
    /// charges. Started on appear so the rotation is already running whenever
    /// the ring becomes visible.
    @State private var chargeSpin = false
    /// 0 while the rings are absent, 1 once they have drawn themselves on.
    /// Every trim is multiplied by it, so one value stages the whole arrival.
    @State private var reveal: Double = 0
    /// Drives the slow pulse of a nearly flat battery.
    @State private var lowBreath = false
    /// The last whole degree the finger crossed, so a detent fires per degree
    /// rather than per touch event.
    @State private var lastDetent: Int?

    private let detent = UIImpactFeedbackGenerator(style: .light)
    private let landed = UIImpactFeedbackGenerator(style: .medium)
    private let arrived = UINotificationFeedbackGenerator()

    private var side: CGFloat { DS.Dial.canvas }
    private var mid: CGFloat { side / 2 }
    /// The trimmed fraction of a full circle that the 270-degree arc covers.
    private var sweepFraction: Double { DS.Dial.sweep / 360 }

    var body: some View {
        ZStack {
            track
            aboveVendorMax
            batteryRing
            warmUp
            progress
            presetTicks
            targetMarker
            center
        }
        .onAppear {
            chargeSpin = true
            detent.prepare()
            landed.prepare()
            // The rings draw themselves on rather than appearing complete. It
            // happens every time the device is picked up, which makes it the
            // moment in this app most worth spending on.
            withAnimation(.easeOut(duration: 0.75)) { reveal = 1 }
            if isLowBattery { lowBreath = true }
        }
        .onChange(of: isLowBattery) { low in lowBreath = low }
        .onChange(of: heatingState) { state in
            guard state == .ready else { return }
            // The haptic stays: reaching temperature, and finishing a draw, are
            // both worth feeling. The highlight that used to sweep the ring
            // here does not — the oven returns to `ready` after every draw, so
            // it fired on every exhale, and a flourish that happens constantly
            // is not a flourish.
            arrived.notificationOccurred(.success)
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        .gesture(scrub)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Target temperature")
        .accessibilityValue(String(format: "%.0f degrees Celsius", target))
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? target + 1 : target - 1
            let clamped = min(DS.Range.max, max(DS.Range.min, next))
            onScrub(clamped)
            onCommit(clamped)
        }
    }

    // MARK: - Ring

    private var track: some View {
        Circle()
            .trim(from: 0, to: CGFloat(sweepFraction) * reveal)
            .stroke(DS.Palette.track,
                    style: StrokeStyle(lineWidth: DS.Dial.stroke, lineCap: .round))
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: DS.Dial.radius * 2, height: DS.Dial.radius * 2)
    }

    // MARK: - Battery

    /// How thick the battery's ring is drawn. The reading is the thickness
    /// rather than a number: nearly full is a hairline you stop noticing,
    /// nearly empty is heavy and red, and charging is always substantial.
    private var batteryStroke: CGFloat {
        guard let level = batteryLevel else { return 0 }
        let emptiness = 1 - min(1, max(0, CGFloat(level) / 100))
        let resting = DS.Dial.batteryStrokeFull
            + (DS.Dial.batteryStrokeEmpty - DS.Dial.batteryStrokeFull) * emptiness
        return isCharging ? max(resting, DS.Dial.batteryStrokeCharging) : resting
    }

    private var batteryColour: Color {
        if isCharging { return DS.Palette.charge }
        guard let level = batteryLevel, level <= 15 else {
            return Color.secondary.opacity(0.45)
        }
        return DS.Palette.low
    }

    @ViewBuilder
    private var batteryRing: some View {
        if let level = batteryLevel {
            let diameter = (DS.Dial.radius - DS.Dial.batteryInset) * 2
            let filled = CGFloat(min(100, max(0, level))) / 100
            ZStack {
                Circle()
                    .trim(from: 0, to: CGFloat(sweepFraction) * reveal)
                    .stroke(DS.Palette.track.opacity(0.5),
                            style: StrokeStyle(lineWidth: batteryStroke, lineCap: .round))
                Circle()
                    .trim(from: 0, to: CGFloat(sweepFraction) * filled * reveal)
                    .stroke(batteryColour,
                            style: StrokeStyle(lineWidth: batteryStroke, lineCap: .round))
                if isCharging {
                    // A highlight travelling the ring: charging is current
                    // moving, not a level rising, so nothing here changes length.
                    Circle()
                        .trim(from: 0, to: 0.06)
                        .stroke(Color.white.opacity(0.35),
                                style: StrokeStyle(lineWidth: batteryStroke, lineCap: .round))
                        .rotationEffect(.degrees(chargeSpin ? 360 : 0))
                        .animation(.linear(duration: 2.6).repeatForever(autoreverses: false),
                                   value: chargeSpin)
                        .mask(
                            Circle()
                                .trim(from: 0, to: CGFloat(sweepFraction) * filled)
                                .stroke(Color.black,
                                        style: StrokeStyle(lineWidth: batteryStroke, lineCap: .round))
                                .rotationEffect(.degrees(DS.Dial.startAngle))
                                .frame(width: diameter, height: diameter)
                        )
                }
            }
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: diameter, height: diameter)
            .animation(.easeOut(duration: 0.75).delay(0.24), value: reveal)
            .animation(.easeInOut(duration: 0.9), value: batteryStroke)
            .animation(.easeInOut(duration: 0.9), value: filled)
            .opacity(lowBreath ? 0.62 : 1)
            .animation(lowBreath
                       ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
                       : .easeOut(duration: 0.3),
                       value: lowBreath)
        }
    }

    private var isLowBattery: Bool {
        guard let level = batteryLevel, !isCharging else { return false }
        return level <= 15
    }

    // MARK: - Oven

    /// How thick the oven's ring is at this instant.
    ///
    /// It grows for as long as the draw lasts and never settles at a width:
    /// an ease that finishes leaves the ring sitting still halfway through a
    /// long pull, which reads as the app having lost interest. The curve is
    /// logarithmic, so it is always climbing and never runs away — quick at
    /// first, then slower, the way a long breath feels.
    ///
    /// The release is not animated. It ends the moment the draw does.
    private func liveStroke(at now: Date) -> CGFloat {
        guard heatingState == .boosting, let started = drawStartedAt else { return DS.Dial.stroke }
        let elapsed = max(0, now.timeIntervalSince(started))
        let growth = log1p(elapsed / DS.Dial.inhaleTimeConstant)
        return DS.Dial.stroke + DS.Dial.inhaleGrowth * CGFloat(growth)
    }

    private var progress: some View {
        // A clock rather than an animation: the width is recomputed each frame
        // from how long the draw has actually been going, and the schedule
        // stops running the moment it ends.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: heatingState != .boosting)) { timeline in
            Circle()
                .trim(from: 0, to: CGFloat(sweepFraction * DS.Range.fraction(of: current ?? DS.Range.min)) * reveal)
                .stroke(accent,
                        style: StrokeStyle(lineWidth: liveStroke(at: timeline.date), lineCap: .round))
                .rotationEffect(.degrees(DS.Dial.startAngle))
                .frame(width: DS.Dial.radius * 2, height: DS.Dial.radius * 2)
                // Linear, and just longer than the gap between readings, so the arc
                // is still travelling towards one temperature when the next
                // arrives: it moves continuously rather than stepping and settling.
                .animation(.linear(duration: travel), value: current)
                .animation(.easeOut(duration: 0.75), value: reveal)
                // Brightens under the finger, so the ring reads as grabbed rather
                // than as a picture being pointed at.
                .shadow(color: accent.opacity(isScrubbing ? 0.55 : 0), radius: 10)
                .animation(.easeOut(duration: 0.2), value: isScrubbing)
        }
    }

    /// The climb from cold to the bottom of the scale, on a ring of its own
    /// just inside the main one. Most of a warm-up happens below 180 °C, where
    /// the main arc has nothing to draw.
    private var warmUp: some View {
        let celsius = current ?? DS.WarmUp.floor
        let filled = DS.WarmUp.fraction(of: celsius)
        let diameter = (DS.Dial.radius - DS.Dial.warmUpInset) * 2
        return Circle()
            .trim(from: 0, to: CGFloat(sweepFraction * filled) * reveal)
            .stroke(accent.opacity(heatingState == .heating ? 0.75 : 0.4),
                    style: StrokeStyle(lineWidth: DS.Dial.warmUpStroke, lineCap: .round))
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: diameter, height: diameter)
            .animation(.easeOut(duration: 0.75).delay(0.12), value: reveal)
            // Fades out as the main arc takes over, rather than vanishing the
            // moment the oven crosses 180.
            .opacity(celsius >= DS.Range.min ? 0 : 1)
            .animation(.linear(duration: travel), value: current)
    }

    /// Past where PAX's own app stopped. Drawn on the track so the end of the
    /// dial reads differently from the rest of it.
    private var aboveVendorMax: some View {
        let start = DS.Range.fraction(of: DS.Range.vendorMax)
        return Circle()
            .trim(from: CGFloat(sweepFraction * start), to: CGFloat(sweepFraction))
            .stroke(Color.orange.opacity(0.22),
                    style: StrokeStyle(lineWidth: DS.Dial.stroke, lineCap: .butt))
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: DS.Dial.radius * 2, height: DS.Dial.radius * 2)
    }

    private var presetTicks: some View {
        ForEach(PaxPresetTemp.allCases) { preset in
            let anchor = ringPoint(for: Double(preset.rawValue), radius: DS.Dial.tickRadius)
            Circle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: DS.Dial.tickDot * 2, height: DS.Dial.tickDot * 2)
                .position(x: anchor.x, y: anchor.y)
                .opacity(reveal)
                .animation(.easeOut(duration: 0.4).delay(0.3), value: reveal)
        }
    }

    private var targetMarker: some View {
        let reach = DS.Dial.markerReach * 2
        return ZStack {
            Capsule()
                .fill(Color.black.opacity(0.22))
                .frame(width: reach, height: DS.Dial.markerShadowWidth)
            Capsule()
                .fill(Color.white)
                .frame(width: reach, height: DS.Dial.markerWidth)
        }
        // Pushed out to the ring and then rotated about the dial's centre, so
        // the only animatable quantity is the angle and the marker travels
        // along the arc. Animating a .position instead interpolates the point
        // in a straight line, which swings the marker across the dial's middle.
        .offset(x: DS.Dial.radius)
        .rotationEffect(.degrees(degrees(for: target)))
        .scaleEffect(isScrubbing ? 1.3 : 1)
        // A drag should track the finger exactly; easing it lags behind. When
        // the finger is gone the marker springs, because the movement then
        // stands for something physical arriving rather than data updating.
        .animation(isScrubbing ? nil : .spring(response: 0.34, dampingFraction: 0.66),
                   value: target)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isScrubbing)
        .opacity(reveal)
        .animation(.easeOut(duration: 0.5).delay(0.25), value: reveal)
    }

    // MARK: - Geometry

    /// Screen-space angle of a temperature: 0 degrees is 3 o'clock and the
    /// sweep runs clockwise, matching SwiftUI's rotation direction.
    private func degrees(for celsius: Double) -> Double {
        DS.Dial.startAngle + DS.Range.fraction(of: celsius) * DS.Dial.sweep
    }

    private func ringPoint(for celsius: Double, radius: CGFloat) -> CGPoint {
        let radians = degrees(for: celsius) * .pi / 180
        return CGPoint(x: mid + radius * CGFloat(cos(radians)),
                       y: mid + radius * CGFloat(sin(radians)))
    }

    // MARK: - Dragging

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isScrubbing = true
                guard let celsius = celsius(at: value.location) else { return }
                // A degree is a detent. Without this the ring is a silent
                // slider; with it the dial has a mechanism under the thumb.
                let degree = Int(celsius)
                if degree != lastDetent {
                    lastDetent = degree
                    detent.impactOccurred(intensity: 0.7)
                    detent.prepare()
                }
                onScrub(celsius)
            }
            .onEnded { value in
                isScrubbing = false
                lastDetent = nil
                guard let celsius = celsius(at: value.location) else { return }
                landed.impactOccurred()
                landed.prepare()
                onCommit(celsius)
            }
    }

    /// Maps a touch to a temperature, rounded to whole degrees. Touches in the
    /// dead zone at the bottom snap to whichever end of the arc is nearer, so
    /// a finger sliding off the end stops at either limit rather than jumping.
    private func celsius(at location: CGPoint) -> Double? {
        let dx = Double(location.x - mid)
        let dy = Double(location.y - mid)
        guard dx != 0 || dy != 0 else { return nil }

        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }

        var travelled = degrees - DS.Dial.startAngle
        if travelled < 0 { travelled += 360 }

        if travelled > DS.Dial.sweep {
            // Past the end of the arc: the dead zone spans the remaining 90
            // degrees, so its midpoint decides which end is closer.
            let deadZoneMidpoint = DS.Dial.sweep + (360 - DS.Dial.sweep) / 2
            return travelled < deadZoneMidpoint ? DS.Range.max : DS.Range.min
        }
        return (DS.Range.celsius(atFraction: travelled / DS.Dial.sweep)).rounded()
    }
}
