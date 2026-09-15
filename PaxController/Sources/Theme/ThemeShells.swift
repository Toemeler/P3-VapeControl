import Combine
import SwiftUI

// MARK: - Session recording

/// A short rolling record of what the oven has been doing, kept in the view
/// rather than in the device model: it exists only to draw the Chart and Clock
/// themes, and only while one of them is on screen.
///
/// Draws are not inferred from the curve. The PAX reports `boosting` while lip
/// detection has you drawing, so a draw is a transition into that state.
@MainActor
final class SessionRecorder: ObservableObject {
    struct Sample: Identifiable {
        let id = UUID()
        let at: Date
        let celsius: Double
    }

    /// Five minutes: long enough to hold a session, short enough that the trace
    /// still has resolution on a phone-width chart.
    static let window: TimeInterval = 300

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var draws: [Date] = []
    @Published private(set) var readySince: Date?
    @Published private(set) var startedAt: Date?

    private var lastState: PaxHeatingState?

    func note(state: PaxHeatingState?, now: Date = Date()) {
        if state == .boosting, lastState != .boosting { draws.append(now) }
        if state == .ready, lastState != .ready { readySince = now }
        if state != .ready, state != .boosting { readySince = nil }
        lastState = state
    }

    func record(_ celsius: Double?, now: Date = Date()) {
        guard let celsius else { return }
        if startedAt == nil { startedAt = now }
        if let last = samples.last, now.timeIntervalSince(last.at) < 1 { return }
        samples.append(Sample(at: now, celsius: celsius))
        let cutoff = now.addingTimeInterval(-Self.window)
        samples.removeAll { $0.at < cutoff }
        draws.removeAll { $0 < cutoff }
    }

    /// The trace, normalised into the unit square: x is time across the window,
    /// y is temperature across the hero span.
    var points: [CGPoint] {
        guard let last = samples.last else { return [] }
        let end = last.at
        return samples.map { sample in
            let age = end.timeIntervalSince(sample.at)
            let x = 1 - min(1, age / Self.window)
            return CGPoint(x: CGFloat(x), y: CGFloat(HeroSpan.fraction(of: sample.celsius)))
        }
    }

    func drawPositions() -> [CGFloat] {
        guard let last = samples.last else { return [] }
        return draws.map { moment in
            let age = last.at.timeIntervalSince(moment)
            return CGFloat(1 - min(1, max(0, age / Self.window)))
        }
    }

    var sessionLength: TimeInterval {
        guard let startedAt, let last = samples.last else { return 0 }
        return last.at.timeIntervalSince(startedAt)
    }

    /// Mean of the samples taken at or above the bottom of the dial's range —
    /// what the oven actually held, rather than an average dragged down by the
    /// warm-up.
    var heldAverage: Double? {
        let held = samples.map(\.celsius).filter { $0 >= DS.Range.min }
        guard !held.isEmpty else { return nil }
        return held.reduce(0, +) / Double(held.count)
    }

    /// Seconds to the target, from the slope of the last few samples. Returns
    /// nil rather than a guess when the climb is too short or too flat to say,
    /// because a countdown that jumps about is worse than none at all.
    func secondsToTarget(_ target: Double) -> Int? {
        let recent = samples.suffix(8)
        guard recent.count >= 4,
              let first = recent.first, let last = recent.last else { return nil }
        let elapsed = last.at.timeIntervalSince(first.at)
        let climbed = last.celsius - first.celsius
        guard elapsed > 1, climbed > 0.5 else { return nil }
        let remaining = target - last.celsius
        guard remaining > 0 else { return nil }
        let rate = climbed / elapsed
        let seconds = remaining / rate
        guard seconds.isFinite, seconds > 0, seconds < 600 else { return nil }
        return Int(seconds.rounded())
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Router

/// The one screen, drawn the way the active theme asks for.
struct ThemedScreen: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var themes: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var showDeviceSheet: Bool

    private var tokens: ThemeTokens {
        themes.tokens(scheme: colorScheme, ledAccent: settings.ledColor.color)
    }

    /// The oven is off on the charger, so the steppers, presets and modes have
    /// nothing to act on. They stay where they are and grey out rather than
    /// disappearing: a screen that rebuilds itself when the device is put down
    /// is worse than one that goes quiet.
    private var active: Bool {
        viewModel.connectionState.isConnected
            && viewModel.paxServiceConfirmed
            && viewModel.isCharging != true
    }

    private var context: ThemeContext {
        ThemeContext(tokens: tokens, unit: settings.temperatureUnit, active: active)
    }

    var body: some View {
        let t = tokens
        return Group {
            if viewModel.connectionState.isConnected || t.theme.shellKind == .prose {
                shell(context: context)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ThemedHeader(context: context,
                                 style: t.theme.shellKind,
                                 showDeviceSheet: $showDeviceSheet)
                    ThemedDiscovery(context: context)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.connectionState.isConnected)
        .background(t.canvas.ignoresSafeArea())
        .environment(\.tokens, t)
    }

    @ViewBuilder
    private func shell(context: ThemeContext) -> some View {
        switch context.tokens.theme.shellKind {
        case .stacked:
            StackedShell(context: context, showDeviceSheet: $showDeviceSheet)
        case .chart:
            ChartShell(context: context, showDeviceSheet: $showDeviceSheet)
        case .field:
            FieldShell(context: context, showDeviceSheet: $showDeviceSheet)
        case .prose:
            ProseShell(context: context, showDeviceSheet: $showDeviceSheet)
        case .object:
            ObjectShell(context: context, showDeviceSheet: $showDeviceSheet)
        case .countdown:
            CountdownShell(context: context, showDeviceSheet: $showDeviceSheet)
        }
    }
}

// MARK: - Stacked

/// Header, hero, target, presets, modes. Which hero and which flavour of each
/// control comes from the theme, which is what makes Classic, Werkstatt,
/// Editorial, Native, Thermal and Instrument one shell rather than six.
struct StackedShell: View {
    let context: ThemeContext
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    var body: some View {
        VStack(spacing: 0) {
            ThemedHeader(context: context, style: .stacked, showDeviceSheet: $showDeviceSheet)
            hero
            ThemedTarget(context: context, style: t.theme.targetKind)
                .padding(.top, t.metric(.sectionGap))
            ThemedPresets(context: context, style: t.theme.presetKind)
                .padding(.top, t.metric(.sectionGap) * 0.6)
            Spacer(minLength: 0)
            ThemedModes(context: context, style: t.theme.modeKind)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var hero: some View {
        switch t.theme.heroKind {
        case .arc:
            ArcHero(context: context)
        case .linearScale:
            LinearScaleHero(context: context).padding(.top, 14)
        case .rule:
            RuleHero(context: context).padding(.top, 26)
        case .card:
            CardHero(context: context).padding(.top, 20)
        case .column:
            ColumnHero(context: context).frame(height: 348).padding(.top, 16)
        case .gauge:
            GaugeHero(context: context).padding(.top, 10)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Chart

/// The session is the screen. One control underneath, whose detents are the
/// presets.
struct ChartShell: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @StateObject private var recorder = SessionRecorder()
    let context: ThemeContext
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ThemedHeader(context: context, style: .chart, showDeviceSheet: $showDeviceSheet)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.labelText("Oven"))
                        .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                    ThemedReadoutState(context: context, dotted: false)
                }
                .padding(.bottom, 6)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                        .font(t.display(t.heroSize))
                        .tracking(t.heroTracking)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                    Text(context.unit.symbol)
                        .font(t.body(17, .medium)).foregroundStyle(t.muted)
                }
                .foregroundStyle(t.ink)
            }
            .padding(.horizontal, t.gutter)
            .padding(.top, 16)
            .padding(.bottom, 10)

            trace
            stats.padding(.top, 14)

            Spacer(minLength: 0)

            ThemedDetentScale(context: context)
            ThemedModes(context: context, style: t.theme.modeKind, showLabel: false)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .onReceive(tick) { _ in recorder.record(viewModel.actualTempC) }
        .onChange(of: viewModel.heatingState) { state in recorder.note(state: state) }
        .onAppear {
            recorder.note(state: viewModel.heatingState)
            recorder.record(viewModel.actualTempC)
        }
    }

    private var trace: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                axisLabel(DS.Range.max)
                Spacer(minLength: 0)
                axisLabel(DS.Range.min)
                Spacer(minLength: 0)
                axisLabel(100)
                Spacer(minLength: 0)
                axisLabel(HeroSpan.floor)
            }
            .frame(width: 30, height: 300)

            GeometryReader { geo in
                let size = geo.size
                let points = recorder.points
                ZStack(alignment: .topLeading) {
                    ForEach([DS.Range.max, DS.Range.min, 100.0, HeroSpan.floor], id: \.self) { value in
                        Rectangle().fill(t.hairline)
                            .frame(height: 1)
                            .offset(y: size.height * CGFloat(1 - HeroSpan.fraction(of: value)))
                    }

                    // The line you asked the oven to sit on.
                    Rectangle()
                        .fill(t.accent)
                        .frame(height: 1)
                        .offset(y: size.height * CGFloat(1 - HeroSpan.fraction(of: viewModel.customTargetTempC)))
                        .opacity(0.65)

                    if points.count > 1 {
                        TraceShape(points: points, closed: true)
                            .fill(t.ink.opacity(0.05))
                        TraceShape(points: points)
                            .stroke(t.ink, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    } else {
                        Text(t.labelText("Recording"))
                            .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                            .frame(width: size.width, height: size.height)
                    }

                    ForEach(Array(recorder.drawPositions().enumerated()), id: \.offset) { _, x in
                        Rectangle().fill(t.accent)
                            .frame(width: 1.6, height: 8)
                            .offset(x: size.width * x, y: size.height + 2)
                    }
                }
            }
            .frame(height: 300)
            .padding(.trailing, t.gutter)
        }
        .padding(.leading, t.gutter - 10)
    }

    private func axisLabel(_ value: Double) -> some View {
        Text(context.unit.format(value, includeSymbol: false))
            .font(t.label()).tracking(0.6).foregroundStyle(t.muted)
            .monospacedDigit()
            .padding(.trailing, 6)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            cell("Session", SessionRecorder.clock(recorder.sessionLength))
            Rectangle().fill(t.hairline).frame(width: 1, height: 34)
            cell("Draws", "\(recorder.draws.count)")
            Rectangle().fill(t.hairline).frame(width: 1, height: 34)
            cell("Held avg", recorder.heldAverage.map { context.degrees($0) } ?? "—")
        }
        .overlay(alignment: .top) { Rectangle().fill(t.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(t.hairline).frame(height: 1) }
        .padding(.horizontal, t.gutter)
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t.labelText(label))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
            Text(value)
                .font(t.body(16, .medium)).monospacedDigit().foregroundStyle(t.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.leading, 14)
    }
}

// MARK: - Field

/// The display is the control: the field's height is the target, the number is
/// its handle, and the presets are detents down the edge.
struct FieldShell: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    private var target: CGFloat { CGFloat(DS.Range.fraction(of: viewModel.customTargetTempC)) }
    private var actual: CGFloat {
        CGFloat(DS.Range.fraction(of: viewModel.actualTempC ?? DS.Range.min))
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [t.color(.heroFill), t.color(.heroFillEnd)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: height * target)
                    .animation(.easeOut(duration: 0.2), value: target)

                // What the oven actually reads, chasing the line you set.
                Rectangle()
                    .fill(t.ink.opacity(0.35))
                    .frame(height: 1.5)
                    .offset(y: -(height * actual))
                    .animation(.easeOut(duration: 0.5), value: actual)

                VStack(spacing: 0) {
                    ThemedHeader(context: context, style: .field, showDeviceSheet: $showDeviceSheet)
                    Spacer(minLength: 0)
                }

                // Battery: a hairline down the left edge. No icon, no chip.
                if let battery = viewModel.batteryLevel {
                    VStack {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(battery <= 10 ? t.color(.low) : t.ink.opacity(0.22))
                            .frame(width: 2, height: height * CGFloat(battery) / 100)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                readout(height: height)
                detents(height: height)
                modeLine
            }
            .frame(width: geo.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard context.active, height > 0 else { return }
                        let f = min(1, max(0, 1 - value.location.y / height))
                        viewModel.customTargetTempC = DS.Range.celsius(atFraction: Double(f)).rounded()
                    }
                    .onEnded { _ in
                        guard context.active else { return }
                        viewModel.setCustomTemperature(viewModel.customTargetTempC)
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func readout(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t.labelText("Target"))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(context.unit.format(viewModel.customTargetTempC, includeSymbol: false))
                    .font(t.display(t.heroSize))
                    .tracking(t.heroTracking)
                    .monospacedDigit()
                    .foregroundStyle(t.ink)
                Text(context.unit.symbol)
                    .font(t.display(t.heroSize * 0.21, .medium))
                    .foregroundStyle(t.muted)
            }
            Text(t.labelText(oneLineStatus))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                .padding(.top, 6)
        }
        .padding(.horizontal, t.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, height * target + 14)
    }

    private var oneLineStatus: String {
        guard let actual = viewModel.actualTempC else { return "waiting" }
        let state = viewModel.isCharging == true
            ? "charging"
            : (viewModel.heatingState?.description ?? "—")
        return "oven \(context.format(actual, decimals: 1)) · \(state)"
    }

    private func detents(height: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(PaxPresetTemp.allCases) { preset in
                let selected = viewModel.selectedPreset == preset
                let y = height * CGFloat(DS.Range.fraction(of: Double(preset.rawValue)))
                HStack(spacing: 7) {
                    Text(context.unit.format(Double(preset.rawValue), includeSymbol: false))
                        .font(t.label()).tracking(t.labelTracking)
                        .foregroundStyle(selected ? t.accent : t.muted)
                    Rectangle()
                        .fill(selected ? t.accent : t.ink.opacity(0.3))
                        .frame(width: selected ? 22 : 14, height: selected ? 2 : 1.5)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard context.active else { return }
                    viewModel.setTemperature(preset)
                }
                .offset(y: -y + 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var modeLine: some View {
        HStack(spacing: 18) {
            chevron("chevron.left", step: -1)
            Text(t.labelText(viewModel.dynamicMode?.label ?? "—"))
                .font(t.body(12, .semibold))
                .tracking(t.labelTracking + 0.6)
                .foregroundStyle(t.onAccent)
            chevron("chevron.right", step: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 34)
        .opacity(context.active ? 1 : 0.4)
    }

    private func chevron(_ symbol: String, step: Int) -> some View {
        Button {
            let modes = PaxDynamicMode.allCases
            guard context.active, let current = viewModel.dynamicMode,
                  let index = modes.firstIndex(of: current) else { return }
            viewModel.setDynamicMode(modes[(index + step + modes.count) % modes.count])
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(t.onAccent.opacity(0.55))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Prose

/// No components. The state is a sentence, the words you can change are the
/// controls, and the accent colour is the state.
struct ProseShell: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    private var connected: Bool { viewModel.connectionState.isConnected }

    private var stateColor: Color {
        t.stateColor(viewModel.heatingState,
                     charging: viewModel.isCharging == true,
                     connected: connected)
    }

    /// One word, always first, always in the same place: the eye learns the
    /// shape and the colour and stops having to read.
    private var headline: String {
        guard connected else { return "Searching." }
        if viewModel.isCharging == true { return "Charging." }
        switch viewModel.heatingState {
        case .heating:     return "Heating."
        case .ready:       return "Ready."
        case .boosting:    return "Drawing."
        case .cooling:     return "Cooling."
        case .standby:     return "Standby."
        case .ovenOff:     return "Oven off."
        case .tempSetMode: return "Setting."
        case .none:        return "Linked."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedHeader(context: context, style: .prose, showDeviceSheet: $showDeviceSheet)

            Text(headline)
                .font(t.display(t.heroSize))
                .tracking(t.heroTracking)
                .foregroundStyle(stateColor)
                .padding(.horizontal, t.gutter)
                .padding(.top, 30)

            if connected {
                gauge.padding(.top, 24)
                sentence.padding(.top, 26)
            } else {
                Text("Your PAX connects on its own. Keep it awake and within a few metres.")
                    .font(t.body(19))
                    .foregroundStyle(t.muted)
                    .padding(.horizontal, t.gutter)
                    .padding(.top, 26)
            }

            Spacer(minLength: 0)

            ThemedPresets(context: context, style: t.theme.presetKind)
            ThemedModes(context: context, style: t.theme.modeKind)
                .padding(.bottom, 12)
        }
    }

    /// The one graphic: a rule under the paragraph, filled from cold to now.
    private var gauge: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(t.track).frame(width: width, height: 1).offset(y: 1)
                    Rectangle().fill(stateColor)
                        .frame(width: width * CGFloat(HeroSpan.fraction(of: viewModel.actualTempC ?? HeroSpan.floor)),
                               height: 3)
                        .animation(.easeOut(duration: 0.5), value: viewModel.actualTempC)
                    Rectangle().fill(t.ink.opacity(0.5))
                        .frame(width: 1, height: 13)
                        .offset(x: width * CGFloat(HeroSpan.fraction(of: viewModel.customTargetTempC)), y: -5)
                }
            }
            .frame(height: 4)

            HStack {
                Text(t.labelText("cold"))
                Spacer()
                Text(t.labelText("target"))
                Spacer()
                Text(t.labelText(context.unit.format(DS.Range.max, includeSymbol: false)))
            }
            .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
        }
        .padding(.horizontal, t.gutter)
    }

    /// Values set large, the grammar between them set small, so it scans as
    /// data at a glance and reads as a sentence if you actually read it.
    private var sentence: some View {
        let small = t.body(19)
        let big = t.display(44, .semibold)
        let target = context.unit.format(viewModel.customTargetTempC, includeSymbol: false) + "°"
        let oven = viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) + "°" } ?? "—"
        let mode = viewModel.dynamicMode?.label ?? "—"

        return (
            Text("Holding at ").font(small).foregroundColor(t.muted)
            + Text(target).font(big).foregroundColor(t.accent)
            + Text(" on ").font(small).foregroundColor(t.muted)
            + Text(mode).font(t.body(19, .semibold)).foregroundColor(t.accent)
            + Text(", oven reads ").font(small).foregroundColor(t.muted)
            + Text(oven).font(big).foregroundColor(t.ink)
            + Text(".").font(small).foregroundColor(t.muted)
        )
        .lineSpacing(2)
        .padding(.horizontal, t.gutter)
    }
}

// MARK: - Object

/// The app shows you the thing. The vessel is deliberately generic: this app
/// ships no proprietary artwork, so it is a plain capsule rather than a
/// likeness of any product.
struct ObjectShell: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    private var fill: CGFloat {
        CGFloat(HeroSpan.fraction(of: viewModel.actualTempC ?? HeroSpan.floor))
    }

    private var target: CGFloat {
        CGFloat(HeroSpan.fraction(of: viewModel.customTargetTempC))
    }

    var body: some View {
        VStack(spacing: 0) {
            ThemedHeader(context: context, style: .object, showDeviceSheet: $showDeviceSheet)
            Spacer(minLength: 0)
            vessel.frame(width: 118, height: 340)
            Spacer(minLength: 0)
            ThemedReadout(context: context, size: t.heroSize).padding(.top, 8)
            Spacer(minLength: 0)
            ThemedTarget(context: context, style: t.theme.targetKind)
            ThemedPresets(context: context, style: t.theme.presetKind).padding(.top, 6)
            ThemedModes(context: context, style: t.theme.modeKind, showLabel: false)
                .padding(.top, 4)
                .padding(.bottom, 14)
        }
    }

    private var vessel: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: t.radius, style: .continuous)
                    .fill(t.plate)
                    .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous)
                        .strokeBorder(t.hairline, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.16), radius: 22, y: 16)

                // The oven, seen through the body.
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: t.metric(.scaleStroke), style: .continuous)
                        .fill(t.track)
                    LinearGradient(colors: [t.color(.heroFill), t.color(.heroFillEnd)],
                                   startPoint: .bottom, endPoint: .top)
                        .frame(height: (height - 48) * fill)
                        .animation(.easeOut(duration: 0.5), value: fill)
                }
                .frame(width: 84, height: height - 48)
                .clipShape(RoundedRectangle(cornerRadius: t.metric(.scaleStroke), style: .continuous))

                // A seam, so it reads as an object rather than a shape.
                Rectangle().fill(t.hairline)
                    .frame(height: 1)
                    .offset(y: -height * 0.16)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Text(context.unit.format(viewModel.customTargetTempC, includeSymbol: false))
                        .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.ink)
                    Rectangle().fill(t.ink).frame(width: 10, height: 2)
                }
                .fixedSize()
                .offset(x: -44, y: -((height - 48) * target) - 24)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard context.active, height > 0 else { return }
                        let f = min(1, max(0, 1 - value.location.y / height))
                        let celsius = HeroSpan.floor + Double(f) * (HeroSpan.ceiling - HeroSpan.floor)
                        viewModel.customTargetTempC =
                            min(DS.Range.max, max(DS.Range.min, celsius.rounded()))
                    }
                    .onEnded { _ in
                        guard context.active else { return }
                        viewModel.setCustomTemperature(viewModel.customTargetTempC)
                    }
            )
        }
    }
}

// MARK: - Countdown

/// One layout that re-ranks itself: whatever the state makes urgent takes the
/// top third, and temperature drops to a table until it matters again.
struct CountdownShell: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @StateObject private var recorder = SessionRecorder()
    let context: ThemeContext
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private var stateColor: Color {
        t.stateColor(viewModel.heatingState,
                     charging: viewModel.isCharging == true,
                     connected: viewModel.connectionState.isConnected)
    }

    /// The label above the big number, and the number itself. Nil means there
    /// is nothing honest to count, and the readout falls back to temperature.
    private var headline: (String, String, String)? {
        if viewModel.isCharging == true, let battery = viewModel.batteryLevel {
            return ("Charging", "\(battery)", "%")
        }
        switch viewModel.heatingState {
        case .heating:
            if let seconds = recorder.secondsToTarget(viewModel.customTargetTempC) {
                return ("Ready in about", "\(seconds)", "sec")
            }
            return nil
        case .ready, .boosting:
            if let since = recorder.readySince {
                return ("Ready for", SessionRecorder.clock(now.timeIntervalSince(since)), "")
            }
            return nil
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedHeader(context: context, style: .countdown, showDeviceSheet: $showDeviceSheet)

            hero.padding(.horizontal, t.gutter).padding(.top, 22)
            climb.padding(.top, 26)
            table.padding(.top, 30)

            Spacer(minLength: 0)

            ThemedTarget(context: context, style: t.theme.targetKind)
            ThemedPresets(context: context, style: t.theme.presetKind).padding(.top, 10)
            ThemedModes(context: context, style: t.theme.modeKind, showLabel: false)
                .padding(.top, 2)
                .padding(.bottom, 14)
        }
        .onReceive(tick) { date in
            now = date
            recorder.record(viewModel.actualTempC, now: date)
        }
        .onChange(of: viewModel.heatingState) { state in recorder.note(state: state) }
        .onAppear { recorder.note(state: viewModel.heatingState) }
    }

    @ViewBuilder
    private var hero: some View {
        let parts = headline
        VStack(alignment: .leading, spacing: 2) {
            Text(t.labelText(parts?.0 ?? "Oven"))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parts?.1
                     ?? (viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--"))
                    .font(t.display(t.heroSize))
                    .tracking(t.heroTracking)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(t.ink)
                Text(parts?.2 ?? context.unit.symbol)
                    .font(t.body(30, .medium))
                    .foregroundStyle(t.muted)
            }
        }
    }

    /// The whole climb as one bar: where it started, where it is, where it stops.
    private var climb: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let width = geo.size.width
                let progress = CGFloat(HeroSpan.fraction(of: viewModel.actualTempC ?? HeroSpan.floor))
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(t.track).frame(width: width, height: 12)
                    Rectangle().fill(stateColor).frame(width: width * progress, height: 12)
                        .animation(.easeOut(duration: 0.5), value: progress)
                    Rectangle().fill(t.ink).frame(width: 2, height: 22)
                        .offset(x: width * progress - 1, y: -5)
                }
            }
            .frame(height: 12)
            HStack {
                Text(t.labelText("cold"))
                Spacer()
                Text(t.labelText("ready at " + context.unit.format(viewModel.customTargetTempC, includeSymbol: false) + "°"))
            }
            .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
        }
        .padding(.horizontal, t.gutter)
    }

    private var table: some View {
        VStack(spacing: 0) {
            Rectangle().fill(t.hairline).frame(height: 1)
            HStack(spacing: 0) {
                cell("Oven now", viewModel.actualTempC.map { context.format($0, decimals: 1) } ?? "—")
                Rectangle().fill(t.hairline).frame(width: 1)
                cell("Target", context.format(viewModel.customTargetTempC))
            }
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(t.hairline).frame(height: 1)
            HStack(spacing: 0) {
                cell("Mode", viewModel.dynamicMode?.label ?? "—")
                Rectangle().fill(t.hairline).frame(width: 1)
                cell("Session", SessionRecorder.clock(recorder.sessionLength))
            }
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(t.hairline).frame(height: 1)
        }
        .padding(.horizontal, t.gutter)
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t.labelText(label))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
            Text(value)
                .font(t.body(19, .medium)).monospacedDigit().foregroundStyle(t.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.trailing, 14)
    }
}
