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
    private let center: Center

    init(current: Double?,
         target: Double,
         accent: Color,
         onScrub: @escaping (Double) -> Void,
         onCommit: @escaping (Double) -> Void,
         @ViewBuilder center: () -> Center) {
        self.current = current
        self.target = target
        self.accent = accent
        self.onScrub = onScrub
        self.onCommit = onCommit
        self.center = center()
    }

    private var side: CGFloat { DS.Dial.canvas }
    private var mid: CGFloat { side / 2 }
    /// The trimmed fraction of a full circle that the 270-degree arc covers.
    private var sweepFraction: Double { DS.Dial.sweep / 360 }

    var body: some View {
        ZStack {
            track
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
            .animation(.easeOut(duration: 0.45), value: current)
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
        let anchor = ringPoint(for: target, radius: DS.Dial.radius)
        let reach = DS.Dial.markerReach * 2
        return ZStack {
            Capsule()
                .fill(Color.black.opacity(0.22))
                .frame(width: reach, height: DS.Dial.markerShadowWidth)
            Capsule()
                .fill(Color.white)
                .frame(width: reach, height: DS.Dial.markerWidth)
        }
        .rotationEffect(.degrees(degrees(for: target)))
        .position(x: anchor.x, y: anchor.y)
        .animation(.easeOut(duration: 0.15), value: target)
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
                guard let celsius = celsius(at: value.location) else { return }
                onScrub(celsius)
            }
            .onEnded { value in
                guard let celsius = celsius(at: value.location) else { return }
                onCommit(celsius)
            }
    }

    /// Maps a touch to a temperature, rounded to whole degrees. Touches in the
    /// dead zone at the bottom snap to whichever end of the arc is nearer, so
    /// a finger sliding off the end stops at 180 or 215 rather than jumping.
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
