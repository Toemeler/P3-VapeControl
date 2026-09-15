import SwiftUI

// MARK: - Shared geometry

/// The span a hero that shows the whole climb draws over: cold enough to be
/// honest about a warm-up, hot enough to reach the top of the dial.
enum HeroSpan {
    static let floor: Double = DS.WarmUp.floor
    static let ceiling: Double = DS.Range.max

    static func fraction(of celsius: Double) -> Double {
        let span = ceiling - floor
        guard span > 0 else { return 0 }
        return min(1, max(0, (celsius - floor) / span))
    }
}

/// A slender tapered pointer with a counterweight, drawn pointing up so the
/// caller only has to rotate it.
struct NeedleShape: Shape {
    var reach: CGFloat = 0.78
    var tail: CGFloat = 0.16

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let tip = centre.y - radius * reach
        let base = centre.y + radius * tail
        path.move(to: CGPoint(x: centre.x, y: tip))
        path.addLine(to: CGPoint(x: centre.x + 2.6, y: centre.y - radius * 0.1))
        path.addLine(to: CGPoint(x: centre.x + 4.2, y: base))
        path.addLine(to: CGPoint(x: centre.x - 4.2, y: base))
        path.addLine(to: CGPoint(x: centre.x - 2.6, y: centre.y - radius * 0.1))
        path.closeSubpath()
        return path
    }
}

/// A run of samples drawn as a trace. Points are normalised 0...1, x left to
/// right and y bottom to top.
struct TraceShape: Shape {
    var points: [CGPoint]
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width,
                    y: rect.maxY - p.y * rect.height)
        }
        path.move(to: place(points[0]))
        for point in points.dropFirst() { path.addLine(to: place(point)) }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Arc

/// The shipped dial, unchanged: this is the one hero that was already drawn.
struct ArcHero: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    var body: some View {
        TemperatureDial(
            current: viewModel.actualTempC,
            target: viewModel.customTargetTempC,
            accent: t.accent,
            cadence: viewModel.temperatureCadence,
            batteryLevel: viewModel.batteryLevel,
            isCharging: viewModel.isCharging == true,
            heatingState: viewModel.heatingState,
            onScrub: { viewModel.customTargetTempC = $0 },
            onCommit: { celsius in
                guard context.active else { return }
                viewModel.setCustomTemperature(celsius)
            }
        ) {
            ThemedReadout(context: context)
        }
        .allowsHitTesting(context.active)
        .overlay(alignment: .bottomLeading) {
            rangeLabel(DS.Range.min).padding(.leading, 46).padding(.bottom, 30)
        }
        .overlay(alignment: .bottomTrailing) {
            rangeLabel(DS.Range.max).padding(.trailing, 46).padding(.bottom, 30)
        }
    }

    private func rangeLabel(_ celsius: Double) -> some View {
        Text(context.degrees(celsius))
            .font(t.body(12))
            .monospacedDigit()
            .foregroundStyle(t.muted)
    }
}

// MARK: - Linear scale

/// A printed tuner: a solid bar for what the oven is, an accent index for what
/// you asked for, and the band past the vendor's own ceiling hatched rather
/// than glowing.
struct LinearScaleHero: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    private var actual: Double {
        DS.Range.fraction(of: viewModel.actualTempC ?? DS.Range.min)
    }

    private var target: Double {
        DS.Range.fraction(of: viewModel.customTargetTempC)
    }

    private var vendor: Double { DS.Range.fraction(of: DS.Range.vendorMax) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            plate
            scale.padding(.top, 22)
        }
        .padding(.horizontal, t.gutter)
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.labelText("Oven temperature"))
                    .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                Spacer()
                ThemedReadoutState(context: context)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                    .font(t.display(t.heroSize))
                    .tracking(t.heroTracking)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                Text(t.labelText(context.unit.symbol))
                    .font(t.display(t.heroSize * 0.23, .medium))
                    .foregroundStyle(t.muted)
            }
            .foregroundStyle(t.ink)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
            .fill(t.plate))
    }

    private var scale: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let stroke = t.metric(.scaleStroke)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(t.track)
                    .frame(width: width, height: stroke)
                    .offset(y: 18)
                Rectangle().fill(t.ink)
                    .frame(width: width * CGFloat(actual), height: stroke)
                    .offset(y: 18)
                // Past here the oven scorches rather than vaporises.
                HatchBand(spacing: 4)
                    .stroke(t.ink.opacity(0.34), lineWidth: 1)
                    .frame(width: width * CGFloat(1 - vendor), height: stroke)
                    .offset(x: width * CGFloat(vendor), y: 18)

                Rectangle().fill(t.hairline)
                    .frame(width: width, height: 1)
                    .offset(y: 30)
                TickRow(count: 45, height: 6, width: 1)
                    .stroke(t.ink.opacity(0.32), lineWidth: 1)
                    .frame(width: width, height: 6)
                    .offset(y: 31)
                TickRow(count: 9, height: 11, width: 1)
                    .stroke(t.ink.opacity(0.55), lineWidth: 1)
                    .frame(width: width, height: 11)
                    .offset(y: 31)

                HStack {
                    ForEach([DS.Range.min, 195.0, 210.0, DS.Range.max], id: \.self) { value in
                        Text(context.unit.format(value, includeSymbol: false))
                            .font(t.body(10))
                            .monospacedDigit()
                            .foregroundStyle(t.muted)
                        if value != DS.Range.max { Spacer(minLength: 0) }
                    }
                }
                .frame(width: width)
                .offset(y: 46)

                // The target index: the one place this theme spends its accent.
                ZStack(alignment: .top) {
                    Triangle().fill(t.accent).frame(width: 10, height: 8)
                    Rectangle().fill(t.accent)
                        .frame(width: 2, height: 32)
                        .offset(y: 8)
                }
                .frame(width: 10, alignment: .top)
                .offset(x: width * CGFloat(target) - 5, y: 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard context.active, width > 0 else { return }
                        let f = min(1, max(0, value.location.x / width))
                        viewModel.customTargetTempC = DS.Range.celsius(atFraction: Double(f)).rounded()
                    }
                    .onEnded { _ in
                        guard context.active else { return }
                        viewModel.setCustomTemperature(viewModel.customTargetTempC)
                    }
            )
        }
        .frame(height: 62)
    }
}

/// Just the dot and the state word, for heroes that place it themselves.
struct ThemedReadoutState: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    var dotted: Bool = true

    private var t: ThemeTokens { context.tokens }

    var body: some View {
        let color = t.stateColor(viewModel.heatingState,
                                 charging: viewModel.isCharging == true,
                                 connected: viewModel.connectionState.isConnected)
        let label: String = {
            guard viewModel.connectionState.isConnected else { return "Offline" }
            if viewModel.isCharging == true { return "Charging" }
            return viewModel.heatingState?.description ?? "—"
        }()
        return HStack(spacing: 6) {
            if dotted {
                Rectangle().fill(color).frame(width: 6, height: 6)
            }
            Text(t.labelText(label))
                .font(t.label())
                .tracking(t.labelTracking)
                .foregroundStyle(color)
        }
    }
}

/// Evenly spaced vertical ticks across the full width.
struct TickRow: Shape {
    var count: Int
    var height: CGFloat
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0 else { return path }
        for index in 0...count {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(count)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY + height))
        }
        return path
    }
}

/// Diagonal hatching, for a band that means caution without meaning alarm.
struct HatchBand: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Rule

/// The reading set as a page's headline, with the range as a measured rule
/// underneath. No fills anywhere.
struct RuleHero: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedReadoutState(context: context, dotted: false)

            HStack(alignment: .top, spacing: 8) {
                Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                    .font(t.display(t.heroSize))
                    .tracking(t.heroTracking)
                    .foregroundStyle(t.ink)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                Text(t.labelText(context.unit.symbol))
                    .font(t.label())
                    .tracking(t.labelTracking)
                    .foregroundStyle(t.muted)
                    .padding(.top, 10)
            }
            .padding(.top, 6)

            rule.padding(.top, 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, t.gutter)
    }

    private var rule: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let actual = CGFloat(DS.Range.fraction(of: viewModel.actualTempC ?? DS.Range.min))
            let target = CGFloat(DS.Range.fraction(of: viewModel.customTargetTempC))
            ZStack(alignment: .topLeading) {
                Text(t.labelText("Target " + context.unit.format(viewModel.customTargetTempC, includeSymbol: false)))
                    .font(t.label())
                    .tracking(t.labelTracking)
                    .foregroundStyle(t.accent)
                    .fixedSize()
                    .offset(x: max(0, min(width - 70, width * target)), y: 0)

                Rectangle().fill(t.hairline).frame(width: width, height: 1).offset(y: 22)
                Rectangle().fill(t.ink)
                    .frame(width: width * actual, height: t.metric(.scaleStroke))
                    .offset(y: 21)
                Rectangle().fill(t.accent)
                    .frame(width: 1, height: 15)
                    .offset(x: width * target, y: 15)

                HStack {
                    Text(context.unit.format(DS.Range.min, includeSymbol: false))
                    Spacer()
                    Text(context.unit.format(DS.Range.max, includeSymbol: false))
                }
                .font(t.label())
                .tracking(t.labelTracking)
                .foregroundStyle(t.muted)
                .frame(width: width)
                .offset(y: 32)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard context.active, width > 0 else { return }
                        let f = min(1, max(0, value.location.x / width))
                        viewModel.customTargetTempC = DS.Range.celsius(atFraction: Double(f)).rounded()
                    }
                    .onEnded { _ in
                        guard context.active else { return }
                        viewModel.setCustomTemperature(viewModel.customTargetTempC)
                    }
            )
        }
        .frame(height: 56)
    }
}

// MARK: - Card

/// The platform's own answer: the reading in a grouped card with a status pill.
struct CardHero: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    private var stateColor: Color {
        t.stateColor(viewModel.heatingState,
                     charging: viewModel.isCharging == true,
                     connected: viewModel.connectionState.isConnected)
    }

    private var stateLabel: String {
        guard viewModel.connectionState.isConnected else { return "Offline" }
        if viewModel.isCharging == true { return "Charging" }
        return viewModel.heatingState?.description ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(t.labelText("Temperature"))
                .font(t.label())
                .tracking(t.labelTracking)
                .foregroundStyle(t.muted)
                .padding(.leading, 16)

            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                        .font(t.display(t.heroSize))
                        .tracking(t.heroTracking)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                    Text(context.unit.symbol)
                        .font(t.body(20, .medium))
                        .foregroundStyle(t.muted)
                }
                .foregroundStyle(t.ink)
                Spacer()
                Text(stateLabel)
                    .font(t.body(13, .semibold))
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(stateColor.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(t.plate))
        }
        .padding(.horizontal, t.gutter)
    }
}

// MARK: - Column

/// The oven as a vessel filling from cold, with the target machined into the
/// outside edge so it never collides with the reading.
struct ColumnHero: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    private var fill: CGFloat {
        CGFloat(HeroSpan.fraction(of: viewModel.actualTempC ?? HeroSpan.floor))
    }

    private var target: CGFloat {
        CGFloat(HeroSpan.fraction(of: viewModel.customTargetTempC))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            vessel
            ticks
            readout
        }
        .padding(.horizontal, t.gutter)
    }

    private var vessel: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
                    .fill(t.track)
                    .overlay(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
                        .strokeBorder(t.hairline, lineWidth: 1))
                LinearGradient(colors: [t.color(.heroFill), t.color(.heroFillEnd)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: height * fill)
                    .overlay(alignment: .top) {
                        Rectangle().fill(t.color(.heroFillEnd).opacity(0.85)).frame(height: 1.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous))
                    .animation(.easeOut(duration: 0.5), value: fill)
            }
            .overlay(alignment: .bottomLeading) {
                Triangle()
                    .rotation(.degrees(-90))
                    .fill(t.ink)
                    .frame(width: 8, height: 8)
                    .offset(x: -9, y: -(height * target) + 4)
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
        .frame(width: t.metric(.scaleStroke))
    }

    private var ticks: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach([DS.Range.max, DS.Range.vendorMax, DS.Range.min], id: \.self) { value in
                    let y = height * (1 - CGFloat(HeroSpan.fraction(of: value)))
                    HStack(spacing: 5) {
                        Rectangle().fill(t.hairline).frame(width: 7, height: 1)
                        Text(context.unit.format(value, includeSymbol: false))
                            .font(t.label()).tracking(0.8).foregroundStyle(t.muted)
                            .fixedSize()
                    }
                    .offset(y: y - 5)
                }
                HStack(spacing: 5) {
                    Rectangle().fill(t.hairline).frame(width: 7, height: 1)
                    Text(t.labelText("cold"))
                        .font(t.label()).tracking(0.8).foregroundStyle(t.muted)
                        .fixedSize()
                }
                .offset(y: height - 5)
            }
        }
        .frame(width: 42)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t.labelText("Oven"))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
            Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                .font(t.display(t.heroSize))
                .tracking(t.heroTracking)
                .monospacedDigit()
                .foregroundStyle(t.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                .padding(.top, 4)
            Text(t.labelText("degrees " + (context.unit == .celsius ? "celsius" : "fahrenheit")))
                .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                .padding(.top, 4)
            Rectangle().fill(t.hairline).frame(height: 1).padding(.vertical, 14)
            ThemedReadoutState(context: context)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Gauge

/// A printed face: every degree marked, a needle for the oven, and a bezel
/// index for the target, which is how a real gauge separates is from set.
struct GaugeHero: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    private static let sweep: Double = 270
    private static let start: Double = -135

    private func angle(for celsius: Double) -> Double {
        Self.start + Self.sweep * DS.Range.fraction(of: celsius)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            ZStack {
                Circle()
                    .strokeBorder(t.track, lineWidth: 10)
                    .frame(width: size, height: size)
                Circle()
                    .fill(t.plate)
                    .frame(width: size - 20, height: size - 20)
                    .overlay(Circle().strokeBorder(t.hairline, lineWidth: 1)
                        .frame(width: size - 20, height: size - 20))

                ForEach(0...45, id: \.self) { index in
                    let major = index % 5 == 0
                    Rectangle()
                        .fill(t.ink.opacity(major ? 0.9 : 0.45))
                        .frame(width: major ? 1.6 : 0.9, height: major ? 11 : 5.5)
                        .offset(y: -(radius - 22))
                        .rotationEffect(.degrees(Self.start + Self.sweep * Double(index) / 45))
                }

                ForEach([DS.Range.min, 190.0, 200.0, 210.0, 220.0, DS.Range.max], id: \.self) { value in
                    Text(context.unit.format(value, includeSymbol: false))
                        .font(t.body(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(t.ink)
                        .offset(y: -(radius - 48))
                        .rotationEffect(.degrees(angle(for: value)))
                }

                // The band past the vendor's own ceiling, printed on the face.
                Circle()
                    .trim(from: CGFloat(DS.Range.fraction(of: DS.Range.vendorMax) * (Self.sweep / 360)),
                          to: CGFloat(Self.sweep / 360))
                    .stroke(t.accent.opacity(0.7), lineWidth: 2.4)
                    .frame(width: (radius - 18) * 2, height: (radius - 18) * 2)
                    .rotationEffect(.degrees(Self.start - 90))

                // The target, as an index on the bezel.
                Rectangle()
                    .fill(t.accent)
                    .frame(width: 2.4, height: 15)
                    .offset(y: -(radius - 7))
                    .rotationEffect(.degrees(angle(for: viewModel.customTargetTempC)))
                    .animation(.easeOut(duration: 0.25), value: viewModel.customTargetTempC)

                centreStack(size: size)

                NeedleShape()
                    .fill(t.accent)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(angle(for: viewModel.actualTempC ?? DS.Range.min)))
                    .animation(.easeOut(duration: 0.45), value: viewModel.actualTempC)

                Circle().fill(t.track).frame(width: 17, height: 17)
                    .overlay(Circle().strokeBorder(t.hairline, lineWidth: 1))
                Circle().fill(t.ink).frame(width: 5, height: 5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, t.gutter)
    }

    private func centreStack(size: CGFloat) -> some View {
        VStack(spacing: 2) {
            ThemedReadoutState(context: context, dotted: false)
                .padding(.bottom, size * 0.12)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                    .font(t.display(t.heroSize))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                Text(context.unit.symbol)
                    .font(t.body(17, .medium))
                    .foregroundStyle(t.muted)
            }
            .foregroundStyle(t.ink)
            if let battery = viewModel.batteryLevel {
                Text(t.labelText("batt \(battery)%"))
                    .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                    .padding(.top, 4)
            }
        }
    }
}
