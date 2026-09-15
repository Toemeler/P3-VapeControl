import SwiftUI

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
    private let center: Center
    @State private var isScrubbing = false

    init(current: Double?,
         target: Double,
         accent: Color,
         cadence: Double = 1,
         onScrub: @escaping (Double) -> Void,
         onCommit: @escaping (Double) -> Void,
         @ViewBuilder center: () -> Center) {
        self.current = current
        self.target = target
        self.accent = accent
        self.cadence = cadence
        self.onScrub = onScrub
        self.onCommit = onCommit
        self.center = center()
    }

    /// Long enough to carry the arc into the next reading, short enough that it
    /// is never chasing one that has already been replaced.
    private var travel: Double { min(1.4, cadence * 1.15) }

    private var side: CGFloat { DS.Dial.canvas }
    private var mid: CGFloat { side / 2 }
    /// The trimmed fraction of a full circle that the 270-degree arc covers.
    private var sweepFraction: Double { DS.Dial.sweep / 360 }

    var body: some View {
        ZStack {
            track
            aboveVendorMax
            warmUp
            progress
            presetTicks
            targetMarker
            center
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
            .trim(from: 0, to: CGFloat(sweepFraction))
            .stroke(DS.Palette.track,
                    style: StrokeStyle(lineWidth: DS.Dial.stroke, lineCap: .round))
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: DS.Dial.radius * 2, height: DS.Dial.radius * 2)
    }

    private var progress: some View {
        Circle()
            .trim(from: 0, to: CGFloat(sweepFraction * DS.Range.fraction(of: current ?? DS.Range.min)))
            .stroke(accent,
                    style: StrokeStyle(lineWidth: DS.Dial.stroke, lineCap: .round))
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: DS.Dial.radius * 2, height: DS.Dial.radius * 2)
            // Linear, and just longer than the gap between readings, so the arc
            // is still travelling towards one temperature when the next
            // arrives: it moves continuously rather than stepping and settling.
            .animation(.linear(duration: travel), value: current)
    }

    /// The climb from cold to the bottom of the scale, on a ring of its own
    /// just inside the main one. Most of a warm-up happens below 180 °C, where
    /// the main arc has nothing to draw.
    private var warmUp: some View {
        let celsius = current ?? DS.WarmUp.floor
        let filled = DS.WarmUp.fraction(of: celsius)
        let diameter = (DS.Dial.radius - DS.Dial.warmUpInset) * 2
        return Circle()
            .trim(from: 0, to: CGFloat(sweepFraction * filled))
            .stroke(accent.opacity(0.4),
                    style: StrokeStyle(lineWidth: DS.Dial.warmUpStroke, lineCap: .round))
            .rotationEffect(.degrees(DS.Dial.startAngle))
            .frame(width: diameter, height: diameter)
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
        // A drag should track the finger exactly; easing it lags behind.
        .animation(isScrubbing ? nil : .easeOut(duration: 0.18), value: target)
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
                onScrub(celsius)
            }
            .onEnded { value in
                isScrubbing = false
                guard let celsius = celsius(at: value.location) else { return }
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
