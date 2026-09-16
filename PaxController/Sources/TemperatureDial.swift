import SwiftUI
import UIKit

/// The thermostat dial: the filled arc is the oven's current temperature, the
/// white marker is where the target sits, and the four dots are the PAX
/// presets. Dragging anywhere on the ring moves the target.
///
/// Four rings, nested: the oven outermost, the warm-up climb just inside it,
/// the battery inside that, and the time ring innermost — a session off the
/// charger, a charge on it. All of them are drawn into one `Canvas` from one
/// `DialEngine` pass per frame, rather than as a stack of shapes each running
/// its own animation. That is what lets them move continuously instead of
/// easing to a value and stopping, and it is the only way the thickness of a
/// ring can stand for how long something has been going on.
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
    /// 0…100. The battery ring's thickness is the reading: a full battery is a
    /// hairline, an empty one is heavy.
    let batteryLevel: Int?
    let isCharging: Bool
    /// Drives the oven ring's swell during a draw.
    let heatingState: PaxHeatingState?
    /// When the current draw began, so the ring's growth is measured against
    /// the draw itself rather than against an animation's own duration.
    let drawStartedAt: Date?
    /// The running session and the running charge, for the time ring.
    let session: DialTiming
    private let center: Center

    init(current: Double?,
         target: Double,
         accent: Color,
         batteryLevel: Int? = nil,
         isCharging: Bool = false,
         heatingState: PaxHeatingState? = nil,
         drawStartedAt: Date? = nil,
         session: DialTiming = DialTiming(),
         onScrub: @escaping (Double) -> Void,
         onCommit: @escaping (Double) -> Void,
         @ViewBuilder center: () -> Center) {
        self.current = current
        self.target = target
        self.accent = accent
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.heatingState = heatingState
        self.drawStartedAt = drawStartedAt
        self.session = session
        self.onScrub = onScrub
        self.onCommit = onCommit
        self.center = center()
    }

    @Environment(\.colorScheme) private var colorScheme
    /// The dial's motion, kept between frames. Deliberately not observable:
    /// advancing it must not invalidate the view that is drawing it.
    @State private var engine = DialEngine()
    @State private var isScrubbing = false
    /// The last whole degree the finger crossed, so a detent fires per degree
    /// rather than per touch event.
    @State private var lastDetent: Int?

    private let detent = UIImpactFeedbackGenerator(style: .light)
    private let landed = UIImpactFeedbackGenerator(style: .medium)
    private let arrived = UINotificationFeedbackGenerator()

    private var side: CGFloat { DS.Dial.canvas }
    private var mid: CGFloat { side / 2 }

    private var input: DialInput {
        DialInput(current: current,
                  target: target,
                  batteryLevel: batteryLevel,
                  isCharging: isCharging,
                  heatingState: heatingState,
                  drawStartedAt: drawStartedAt,
                  isScrubbing: isScrubbing,
                  sessionStartedAt: session.sessionStartedAt,
                  sessionDraws: session.draws,
                  drawMarks: session.drawMarks,
                  lastDrawAt: session.lastDrawAt,
                  autoOffEnabled: session.autoOffEnabled,
                  autoOffMinutes: session.autoOffMinutes,
                  chargeStartedAt: session.chargeStartedAt,
                  chargeMarks: session.chargeMarks)
    }

    /// Full rate while anything is moving, a slow idle otherwise. Never paused:
    /// a paused timeline holds its date, so a reading that arrived during the
    /// pause would be drawn as a jump rather than a movement.
    private var interval: Double {
        input.isLively || !engine.isResting ? 1.0 / 60 : 1.0 / 8
    }

    var body: some View {
        let input = self.input
        let palette = DialPalette(scheme: colorScheme, accent: accent)
        ZStack {
            TimelineView(.animation(minimumInterval: interval, paused: false)) { timeline in
                let frame = engine.frame(at: timeline.date, input: input, palette: palette)
                Canvas { context, size in
                    render(frame, palette: palette, into: &context, size: size)
                }
            }
            center
        }
        .onAppear {
            detent.prepare()
            landed.prepare()
        }
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

    // MARK: - Drawing

    private func render(_ frame: DialFrame, palette: DialPalette,
                        into context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        track(frame, palette, &context, centre)
        battery(frame, palette, &context, centre)
        timeRing(frame, palette, &context, centre)
        warmUp(frame, palette, &context, centre)
        oven(frame, palette, &context, centre)
        ticks(frame, palette, &context, centre)
        marker(frame, palette, &context, centre)
    }

    private func track(_ f: DialFrame, _ palette: DialPalette,
                       _ context: inout GraphicsContext, _ centre: CGPoint) {
        context.stroke(arc(centre, DS.Dial.radius, 0, f.revealTrack),
                       with: .color(palette.track),
                       style: stroked(DS.Dial.stroke))

        // Past where PAX's own app stopped. Drawn on the track so the end of
        // the dial reads differently from the rest of it.
        let beyond = DS.Range.fraction(of: DS.Range.vendorMax)
        if f.revealTrack > beyond {
            context.stroke(arc(centre, DS.Dial.radius, beyond, f.revealTrack),
                           with: .color(palette.beyondMax),
                           style: StrokeStyle(lineWidth: DS.Dial.stroke, lineCap: .butt))
        }
    }

    private func battery(_ f: DialFrame, _ palette: DialPalette,
                         _ context: inout GraphicsContext, _ centre: CGPoint) {
        guard f.batteryVisible, f.batteryStroke > 0.2 else { return }
        let radius = DS.Dial.radius - DS.Dial.batteryInset
        let width = f.batteryStroke

        context.stroke(arc(centre, radius, 0, f.revealBattery),
                       with: .color(palette.trackSoft),
                       style: stroked(width))
        let filled = f.batteryTrim * f.revealBattery
        context.stroke(arc(centre, radius, 0, filled),
                       with: .color(f.batteryColor),
                       style: stroked(width))

        guard f.chargeHighlight > 0.01, filled > 0.02 else { return }
        // The highlight travels the filled part rather than the whole ring:
        // charging is current moving, and the length of the arc is the level,
        // which the highlight must not appear to change.
        let lap = (f.chargeSpinDegrees / 360).truncatingRemainder(dividingBy: 1)
        let head = lap * filled
        context.stroke(arc(centre, radius, max(0, head - 0.06), head),
                       with: .color(.white.opacity(0.35 * f.chargeHighlight)),
                       style: stroked(width))
    }

    private func timeRing(_ f: DialFrame, _ palette: DialPalette,
                          _ context: inout GraphicsContext, _ centre: CGPoint) {
        guard f.timeOpacity > 0.01 else { return }
        let radius = DS.Dial.timeRadius
        let width = max(DS.Dial.timeStrokeBase, f.timeStroke)

        context.stroke(arc(centre, radius, 0, f.revealTime),
                       with: .color(palette.trackSoft.opacity(0.55 * f.timeOpacity)),
                       style: stroked(1.5))
        context.stroke(arc(centre, radius, 0, f.timeTrim * f.revealTime),
                       with: .color(f.timeColor.opacity(f.timeOpacity)),
                       style: stroked(width))

        // The fuse: what is left of the auto-off window, sitting at the leading
        // edge where the eye already is. Every draw refills it.
        if f.fuseOpacity > 0.01, f.fuseEnd > f.fuseStart {
            context.stroke(arc(centre, radius,
                               f.fuseStart * f.revealTime, f.fuseEnd * f.revealTime),
                           with: .color(palette.brighten(f.timeColor, 0.7).opacity(f.fuseOpacity)),
                           style: stroked(width + 2.5))
        }

        // One bead per draw — or per ten percent of a charge — standing where
        // it happened. The arc is a timeline, so the events belong on it.
        guard f.revealTime > 0.4 else { return }
        let size = max(1.4, min(DS.Dial.timeBead, width * 0.42))
        let colour = palette.brighten(f.timeColor, 0.85).opacity(0.9 * f.timeOpacity)
        for bead in f.beads where bead <= f.timeTrim + 0.001 {
            let at = point(centre, radius, bead * f.revealTime)
            context.fill(Path(ellipseIn: CGRect(x: at.x - size, y: at.y - size,
                                                width: size * 2, height: size * 2)),
                         with: .color(colour))
        }
    }

    private func warmUp(_ f: DialFrame, _ palette: DialPalette,
                        _ context: inout GraphicsContext, _ centre: CGPoint) {
        guard f.warmOpacity > 0.01 else { return }
        // The climb from cold to the bottom of the scale, on a ring of its own.
        // Most of a warm-up happens below 180 °C, where the main arc has
        // nothing to draw. It fades out as the main arc takes over rather than
        // vanishing the moment the oven crosses 180.
        let radius = DS.Dial.radius - DS.Dial.warmUpInset
        let weight = heatingState == .heating ? 0.75 : 0.4
        context.stroke(arc(centre, radius, 0, f.warmTrim * f.revealWarm),
                       with: .color(palette.accent.opacity(weight * f.warmOpacity)),
                       style: stroked(DS.Dial.warmUpStroke))
    }

    private func oven(_ f: DialFrame, _ palette: DialPalette,
                      _ context: inout GraphicsContext, _ centre: CGPoint) {
        let filled = f.heatTrim * f.revealTrack
        guard filled > 0.0005 else { return }

        // The bloom is what carries a long pull. The ring's width is bounded so
        // it can never reach the presets; the bloom is not bounded by the same
        // problem, because it is light rather than an edge — it keeps growing
        // long after the width has all but settled, and it is drawn around the
        // ring's fixed outer edge so it always fades well inside the canvas.
        if f.bloom > 0.01 {
            let edge = arc(centre, DS.Dial.outerEdge, 0, filled)
            context.stroke(edge,
                           with: .color(f.heatColor.opacity(0.07 * f.bloom)),
                           style: stroked(18 * CGFloat(f.bloom)))
            context.stroke(edge,
                           with: .color(f.heatColor.opacity(0.16 * f.bloom)),
                           style: stroked(10 * CGFloat(f.bloom)))
        }

        let path = arc(centre, f.heatRadius, 0, filled)
        // Brightens under the finger, so the ring reads as grabbed rather than
        // as a picture being pointed at.
        if f.scrubGlow > 0.01 {
            context.stroke(path,
                           with: .color(f.heatColor.opacity(0.3 * f.scrubGlow)),
                           style: stroked(f.heatStroke + 12 * CGFloat(f.scrubGlow)))
        }
        context.stroke(path, with: .color(f.heatColor), style: stroked(f.heatStroke))
    }

    private func ticks(_ f: DialFrame, _ palette: DialPalette,
                       _ context: inout GraphicsContext, _ centre: CGPoint) {
        guard f.revealTicks > 0.01 else { return }
        let size = DS.Dial.tickDot
        for preset in PaxPresetTemp.allCases {
            let at = point(centre, DS.Dial.tickRadius,
                           DS.Range.fraction(of: Double(preset.rawValue)))
            context.fill(Path(ellipseIn: CGRect(x: at.x - size, y: at.y - size,
                                                width: size * 2, height: size * 2)),
                         with: .color(palette.tick.opacity(0.55 * f.revealTicks)))
        }
    }

    private func marker(_ f: DialFrame, _ palette: DialPalette,
                        _ context: inout GraphicsContext, _ centre: CGPoint) {
        guard f.revealMarker > 0.01 else { return }
        var marker = context
        marker.opacity = f.revealMarker
        marker.translateBy(x: centre.x, y: centre.y)
        // Rotated about the dial's centre, so the marker travels along the arc.
        // Interpolating its position instead would swing it across the middle.
        marker.rotate(by: .degrees(f.markerAngle))

        let scale = CGFloat(f.markerScale)
        let reach = DS.Dial.markerReach * scale
        let shadow = DS.Dial.markerShadowWidth * scale
        let width = DS.Dial.markerWidth * scale
        let x = DS.Dial.radius - reach
        marker.fill(Path(roundedRect: CGRect(x: x, y: -shadow / 2,
                                             width: reach * 2, height: shadow),
                         cornerRadius: shadow / 2),
                    with: .color(palette.markerShadow))
        marker.fill(Path(roundedRect: CGRect(x: x, y: -width / 2,
                                             width: reach * 2, height: width),
                         cornerRadius: width / 2),
                    with: .color(palette.marker))
    }

    // MARK: - Geometry

    private func stroked(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: max(0, width), lineCap: .round)
    }

    /// An arc of the dial's 270-degree sweep, `from` and `to` in 0…1 of it.
    private func arc(_ centre: CGPoint, _ radius: CGFloat,
                     _ from: Double, _ to: Double) -> Path {
        var path = Path()
        let start = min(max(0, from), 1)
        let end = min(max(0, to), 1)
        guard radius > 0, end > start else { return path }
        path.addArc(center: centre, radius: radius,
                    startAngle: .degrees(DS.Dial.startAngle + start * DS.Dial.sweep),
                    endAngle: .degrees(DS.Dial.startAngle + end * DS.Dial.sweep),
                    clockwise: false)
        return path
    }

    private func point(_ centre: CGPoint, _ radius: CGFloat, _ fraction: Double) -> CGPoint {
        let radians = (DS.Dial.startAngle + min(max(0, fraction), 1) * DS.Dial.sweep) * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(cos(radians)),
                       y: centre.y + radius * CGFloat(sin(radians)))
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

/// What the time ring is timing: a session off the charger, a charge on it.
///
/// Passed as one value so the dial's signature does not grow a parameter every
/// time the ring learns to read something else.
struct DialTiming: Equatable {
    var sessionStartedAt: Date?
    var draws: Int = 0
    /// When each draw happened, in seconds from the session's start.
    var drawMarks: [TimeInterval] = []
    var lastDrawAt: Date?
    var autoOffEnabled: Bool = false
    var autoOffMinutes: Int = 8

    var chargeStartedAt: Date?
    /// When each ten-percent step was crossed, in seconds from the start.
    var chargeMarks: [TimeInterval] = []
}
