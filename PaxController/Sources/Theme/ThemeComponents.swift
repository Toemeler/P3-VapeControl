import SwiftUI

// MARK: - Shared context

/// What every themed component needs to draw itself, gathered once by the shell
/// so the pieces do not each reach into the environment.
struct ThemeContext {
    var tokens: ThemeTokens
    var unit: TemperatureUnit
    /// False on the charger or while disconnected: the controls stay where they
    /// are and go quiet rather than disappearing.
    var active: Bool

    func format(_ celsius: Double, decimals: Int = 0, symbol: Bool = true) -> String {
        unit.format(celsius, decimals: decimals, includeSymbol: symbol)
    }

    /// A preset or scale label: the number and a degree sign, no unit.
    func degrees(_ celsius: Double) -> String {
        unit.format(celsius, includeSymbol: false) + "°"
    }
}

// MARK: - Header

struct ThemedHeader: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    let style: ThemeShell
    @Binding var showDeviceSheet: Bool

    private var t: ThemeTokens { context.tokens }

    private var connected: Bool { viewModel.connectionState.isConnected }

    private var name: String {
        connected ? (viewModel.displayName ?? "PAX") : viewModel.statusHeadline
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .ready:
            return t.color(.ready)
        case .scanning, .connecting, .waitingForDevice,
             .discoveringServices, .awaitingSerial:
            return t.color(.heating)
        case .error:
            return t.color(.low)
        case .idle, .disconnecting:
            return t.color(.offline)
        }
    }

    var body: some View {
        Group {
            switch style {
            case .stacked:
                if t.theme.heroKind == .card { largeTitle } else { capsules }
            default:
                plain
            }
        }
    }

    /// The shipped header: a name capsule, a battery capsule, a gear.
    private var capsules: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(name)
            }
            .font(t.body(15, .semibold))
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: t.metric(.capsuleHeight))
            .background(t.plate, in: Capsule())

            if let battery = viewModel.batteryLevel {
                HStack(spacing: 5) {
                    Text("\(battery)%")
                        .monospacedDigit()
                    if viewModel.isCharging == true {
                        Image(systemName: "bolt.fill").font(.system(size: 11))
                    }
                }
                .font(t.body(15, .semibold))
                .padding(.horizontal, 13)
                .frame(height: t.metric(.capsuleHeight))
                .background(t.plate, in: Capsule())
            }

            Spacer(minLength: 0)
            lockIndicator
            gearButton(inCircle: true)
        }
        .foregroundStyle(t.ink)
        .padding(.horizontal, t.gutter)
        .frame(height: t.metric(.headerHeight))
    }

    /// A line of record rather than a row of controls: used by every theme that
    /// does not draw chrome.
    private var plain: some View {
        HStack(spacing: 9) {
            Text(t.labelText(name))
                .font(t.label())
                .tracking(t.labelTracking)
                .foregroundStyle(t.ink)
            Rectangle()
                .fill(t.hairline)
                .frame(width: 1, height: 9)
            Text(t.labelText(connected ? "linked" : "searching"))
                .font(t.label())
                .tracking(t.labelTracking)
                .foregroundStyle(t.muted)

            Spacer(minLength: 0)

            if let battery = viewModel.batteryLevel {
                Text(t.labelText(viewModel.isCharging == true ? "\(battery)% charging" : "\(battery)%"))
                    .font(t.label())
                    .tracking(t.labelTracking)
                    .foregroundStyle(battery <= 10 ? t.color(.low) : t.muted)
            }
            lockIndicator
            gearButton(inCircle: false)
        }
        .padding(.horizontal, t.gutter)
        .frame(height: t.metric(.headerHeight))
    }

    /// The platform's own hierarchy, for the Native theme.
    private var largeTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                gearButton(inCircle: true)
            }
            .frame(height: 44)
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(t.display(34, .bold))
                    .foregroundStyle(t.ink)
                Spacer(minLength: 0)
                lockIndicator
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(connected
                     ? (viewModel.batteryLevel.map { "Connected · \($0)% battery" } ?? "Connected")
                     : viewModel.statusHeadline)
                    .font(t.body(15))
                    .foregroundStyle(t.muted)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, t.gutter)
    }

    @ViewBuilder
    private var lockIndicator: some View {
        // Read-only: the PAX reports its lock state but exposes no way to set
        // it, so this appears only when it has something to say.
        if viewModel.isLocked == true {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(t.accent)
                .accessibilityLabel("Device locked")
        }
    }

    private func gearButton(inCircle: Bool) -> some View {
        Button {
            showDeviceSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: inCircle ? 17 : 15, weight: .medium))
                .frame(width: inCircle ? 38 : 30, height: inCircle ? 38 : 30)
                .background(inCircle ? t.plate : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(t.ink)
        .accessibilityLabel("Device settings")
    }
}

// MARK: - Readout

/// The temperature, the unit and what the oven is doing. Every shell that shows
/// a number shows this one, so the type ramp stays consistent across themes.
struct ThemedReadout: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    var alignment: HorizontalAlignment = .center
    var showState: Bool = true
    var size: CGFloat?

    private var t: ThemeTokens { context.tokens }

    var stateColor: Color {
        t.stateColor(viewModel.heatingState,
                     charging: viewModel.isCharging == true,
                     connected: viewModel.connectionState.isConnected)
    }

    var stateLabel: String {
        guard viewModel.connectionState.isConnected else { return "Offline" }
        if viewModel.isCharging == true { return "Charging" }
        return viewModel.heatingState?.description ?? "—"
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            if showState {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(t.labelText(stateLabel))
                        .font(t.label())
                        .tracking(t.labelTracking)
                        .foregroundStyle(stateColor)
                }
                .padding(.bottom, 4)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(viewModel.actualTempC.map { context.format($0, decimals: 1, symbol: false) } ?? "--")
                    .font(t.display(size ?? t.heroSize))
                    .tracking(t.heroTracking)
                    .monospacedDigit()
                    // Readings arrive twice a second; snapping between them
                    // reads as a counter, rolling reads as an instrument.
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: viewModel.actualTempC)
                Text(context.unit.symbol)
                    .font(t.display((size ?? t.heroSize) * 0.32, .semibold))
                    .foregroundStyle(t.muted)
            }
            .foregroundStyle(t.ink)
        }
    }
}

// MARK: - Target

struct ThemedTarget: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    let style: ThemeTargetStyle

    private var t: ThemeTokens { context.tokens }

    var body: some View {
        switch style {
        case .stepperRound:    stepper(shape: .round)
        case .stepperPlate:    stepper(shape: .plate)
        case .stepperHairline: stepper(shape: .hairline)
        case .slider:          slider
        case .detents:         ThemedDetentScale(context: context)
        case .none:            EmptyView()
        }
    }

    private enum StepShape { case round, plate, hairline }

    private func stepper(shape: StepShape) -> some View {
        HStack(spacing: shape == .round ? 26 : 12) {
            if shape != .round {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.labelText("Target"))
                        .font(t.label())
                        .tracking(t.labelTracking)
                        .foregroundStyle(t.muted)
                    targetValue(size: 30)
                }
                Spacer(minLength: 0)
            } else {
                stepButton("minus", delta: -1, shape: shape)
                VStack(spacing: 1) {
                    targetValue(size: 25)
                    Text(t.labelText("Target"))
                        .font(t.body(12))
                        .foregroundStyle(t.muted)
                }
                .frame(width: 120)
            }
            if shape != .round {
                stepButton("minus", delta: -1, shape: shape)
            }
            stepButton("plus", delta: 1, shape: shape)
        }
        .padding(.horizontal, shape == .round ? 0 : t.gutter)
        .frame(maxWidth: .infinity)
    }

    private func targetValue(size: CGFloat) -> some View {
        Text(context.format(viewModel.customTargetTempC))
            .font(t.display(size))
            .monospacedDigit()
            .tracking(-0.5)
            .foregroundStyle(t.ink)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: viewModel.customTargetTempC)
    }

    private func stepButton(_ symbol: String, delta: Double, shape: StepShape) -> some View {
        Button {
            commit(delta: delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: shape == .round ? 20 : 16, weight: .semibold))
                .frame(width: t.metric(.stepSize),
                       height: shape == .round ? t.metric(.stepSize) : t.metric(.presetHeight))
                .background(background(for: shape))
                .foregroundStyle(t.ink)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .disabled(!context.active)
        .opacity(context.active ? 1 : 0.32)
        .accessibilityLabel(delta > 0 ? "Increase target" : "Decrease target")
    }

    @ViewBuilder
    private func background(for shape: StepShape) -> some View {
        switch shape {
        case .round:
            Circle().fill(t.plate)
        case .plate:
            RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous).fill(t.plate)
        case .hairline:
            RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
                .strokeBorder(t.hairline, lineWidth: t.hairlineWidth)
        }
    }

    /// The Native theme's stock slider, min and max labelled at the ends.
    private var slider: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Target").font(t.body(17)).foregroundStyle(t.ink)
                Spacer()
                Text(context.format(viewModel.customTargetTempC))
                    .font(t.body(17))
                    .monospacedDigit()
                    .foregroundStyle(t.muted)
            }
            HStack(spacing: 10) {
                Text(context.degrees(DS.Range.min))
                    .font(t.body(13)).foregroundStyle(t.muted).monospacedDigit()
                Slider(value: Binding(
                    get: { viewModel.customTargetTempC },
                    set: { viewModel.customTargetTempC = $0.rounded() }
                ), in: DS.Range.min...DS.Range.max, step: 1) { editing in
                    guard !editing, context.active else { return }
                    viewModel.setCustomTemperature(viewModel.customTargetTempC)
                }
                .tint(t.accent)
                Text(context.degrees(DS.Range.max))
                    .font(t.body(13)).foregroundStyle(t.muted).monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(t.plate))
        .padding(.horizontal, t.gutter)
        .disabled(!context.active)
        .opacity(context.active ? 1 : 0.32)
    }

    private func commit(delta: Double) {
        let next = (viewModel.customTargetTempC + delta).rounded()
        let clamped = min(DS.Range.max, max(DS.Range.min, next))
        guard clamped != viewModel.customTargetTempC else { return }
        viewModel.customTargetTempC = clamped
        viewModel.setCustomTemperature(clamped)
    }
}

// MARK: - One scale that is also the presets

/// The Chart theme's single control: a target scale whose detents are the four
/// presets, so jumping to one and dragging past it are the same gesture.
struct ThemedDetentScale: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    private var fraction: CGFloat {
        CGFloat(DS.Range.fraction(of: viewModel.customTargetTempC))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.labelText("Target"))
                    .font(t.label()).tracking(t.labelTracking).foregroundStyle(t.muted)
                Spacer()
                Text(context.format(viewModel.customTargetTempC))
                    .font(t.display(26, .medium))
                    .monospacedDigit()
                    .foregroundStyle(t.ink)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: viewModel.customTargetTempC)
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(t.track)
                        .frame(height: 2)
                        .offset(y: 11)

                    ForEach(PaxPresetTemp.allCases) { preset in
                        let x = width * CGFloat(DS.Range.fraction(of: Double(preset.rawValue)))
                        VStack(spacing: 6) {
                            Rectangle()
                                .fill(t.hairline)
                                .frame(width: 1, height: 14)
                            Text(context.degrees(Double(preset.rawValue)))
                                .font(t.label())
                                .tracking(t.labelTracking)
                                .foregroundStyle(viewModel.selectedPreset == preset ? t.accent : t.muted)
                                .fixedSize()
                        }
                        .frame(width: 44)
                        .offset(x: x - 22, y: 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard context.active else { return }
                            viewModel.setTemperature(preset)
                        }
                    }

                    // The handle rides the same scale the detents sit on.
                    Capsule()
                        .fill(t.accent)
                        .frame(width: 4, height: 24)
                        .offset(x: width * fraction - 2, y: 0)
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
            .frame(height: 40)
        }
        .padding(.horizontal, t.gutter)
        .opacity(context.active ? 1 : 0.32)
    }
}

// MARK: - Presets

struct ThemedPresets: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    let style: ThemePresetStyle

    private var t: ThemeTokens { context.tokens }

    var body: some View {
        Group {
            switch style {
            case .capsules:  row { capsule($0) }
            case .plates:    row { plate($0) }
            case .segmented: segmented
            case .words:     words
            case .table:     table
            case .detents, .none: EmptyView()
            }
        }
        .disabled(!context.active)
        .opacity(context.active ? 1 : 0.32)
    }

    private func row<Content: View>(@ViewBuilder _ cell: @escaping (PaxPresetTemp) -> Content) -> some View {
        HStack(spacing: 9) {
            ForEach(PaxPresetTemp.allCases) { preset in
                Button { viewModel.setTemperature(preset) } label: { cell(preset) }
                    .buttonStyle(PressableButtonStyle())
                    .animation(.spring(response: 0.32, dampingFraction: 0.72),
                               value: viewModel.selectedPreset)
            }
        }
        .padding(.horizontal, t.gutter)
    }

    private func isActive(_ preset: PaxPresetTemp) -> Bool { viewModel.selectedPreset == preset }

    private func capsule(_ preset: PaxPresetTemp) -> some View {
        Text(context.degrees(Double(preset.rawValue)))
            .font(t.body(15, isActive(preset) ? .semibold : .medium))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: t.metric(.presetHeight))
            .background(isActive(preset) ? t.accentWash : t.plate, in: Capsule())
            .foregroundStyle(isActive(preset) ? t.accent : t.ink)
    }

    private func plate(_ preset: PaxPresetTemp) -> some View {
        Text(context.degrees(Double(preset.rawValue)))
            .font(t.body(14, isActive(preset) ? .semibold : .regular))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: t.metric(.presetHeight))
            .background(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
                .fill(isActive(preset) ? t.accent : t.plate))
            .foregroundStyle(isActive(preset) ? t.onAccent : t.ink)
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(PaxPresetTemp.allCases) { preset in
                Button { viewModel.setTemperature(preset) } label: {
                    Text(context.degrees(Double(preset.rawValue)))
                        .font(t.body(15, isActive(preset) ? .semibold : .regular))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .frame(height: t.metric(.presetHeight) - 4)
                        .background(
                            RoundedRectangle(cornerRadius: max(0, t.radius - 2), style: .continuous)
                                .fill(isActive(preset) ? t.plate : Color.clear)
                                .shadow(color: isActive(preset) ? Color.black.opacity(0.12) : .clear,
                                        radius: 2, y: 1)
                        )
                        .foregroundStyle(t.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(t.track))
        .padding(.horizontal, t.gutter)
    }

    /// A run of numbers, sized as type rather than drawn as chrome.
    private var words: some View {
        HStack(alignment: .center, spacing: 22) {
            ForEach(PaxPresetTemp.allCases) { preset in
                Button { viewModel.setTemperature(preset) } label: {
                    Text(context.degrees(Double(preset.rawValue)))
                        .font(t.display(25, isActive(preset) ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isActive(preset) ? t.accent : t.muted)
                        .frame(height: t.metric(.presetHeight))
                        .overlay(alignment: .bottom) {
                            if isActive(preset) {
                                Rectangle().fill(t.accent.opacity(0.45)).frame(height: 2)
                                    .padding(.bottom, 10)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, t.gutter)
    }

    /// Four columns divided by rules, the live one marked underneath.
    private var table: some View {
        HStack(spacing: 0) {
            ForEach(Array(PaxPresetTemp.allCases.enumerated()), id: \.element.id) { index, preset in
                if index > 0 {
                    Rectangle().fill(t.hairline).frame(width: t.hairlineWidth)
                }
                Button { viewModel.setTemperature(preset) } label: {
                    VStack(spacing: 4) {
                        Text(context.degrees(Double(preset.rawValue)))
                            .font(t.display(25, .regular))
                            .foregroundStyle(isActive(preset) ? t.accent : t.ink)
                        Rectangle()
                            .fill(isActive(preset) ? t.accent : Color.clear)
                            .frame(width: 16, height: 1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: t.metric(.presetHeight))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(t.hairline).frame(height: t.hairlineWidth) }
        .overlay(alignment: .bottom) { Rectangle().fill(t.hairline).frame(height: t.hairlineWidth) }
        .padding(.horizontal, t.gutter)
    }
}

// MARK: - Modes

struct ThemedModes: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext
    let style: ThemeModeStyle
    var showLabel: Bool = true

    private var t: ThemeTokens { context.tokens }

    private func isActive(_ mode: PaxDynamicMode) -> Bool { viewModel.dynamicMode == mode }

    var body: some View {
        Group {
            if style == .none {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if showLabel && style != .dots {
                        Text(t.labelText("Heating mode"))
                            .font(t.label())
                            .tracking(t.labelTracking)
                            .foregroundStyle(t.muted)
                            .padding(.horizontal, t.gutter + 4)
                            .padding(.bottom, 10)
                    }
                    content
                }
            }
        }
        .disabled(!context.active)
        .opacity(context.active ? 1 : 0.32)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .tiles:     tiles
        case .switchBar: switchBar
        case .keys:      keys
        case .list:      list
        case .words:     words
        case .selector:  selector
        case .dots:      dots
        case .none:      EmptyView()
        }
    }

    private func button<Content: View>(_ mode: PaxDynamicMode,
                                       @ViewBuilder _ label: () -> Content) -> some View {
        Button { viewModel.setDynamicMode(mode) } label: { label() }
            .buttonStyle(PressableButtonStyle(scale: 0.95))
            .animation(.spring(response: 0.34, dampingFraction: 0.7), value: viewModel.dynamicMode)
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            ForEach(PaxDynamicMode.allCases) { mode in
                button(mode) {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon).font(.system(size: 21))
                        Text(mode.label)
                            .font(t.body(10.5, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: t.metric(.modeHeight))
                    .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous)
                        .fill(isActive(mode) ? t.accent : t.plate))
                    .foregroundStyle(isActive(mode) ? t.onAccent : t.muted)
                }
            }
        }
        .padding(.horizontal, t.gutter)
    }

    /// One plate divided into five positions, the live one filled.
    private var switchBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(PaxDynamicMode.allCases.enumerated()), id: \.element.id) { index, mode in
                if index > 0 {
                    Rectangle().fill(t.hairline).frame(width: t.hairlineWidth)
                }
                button(mode) {
                    Text(t.labelText(mode.label))
                        .font(t.body(11, isActive(mode) ? .medium : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .frame(height: t.metric(.modeHeight))
                        .background(isActive(mode) ? t.ink : Color.clear)
                        .foregroundStyle(isActive(mode) ? t.canvas : t.muted)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous).fill(t.plate))
        .clipShape(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous))
        .padding(.horizontal, t.gutter)
    }

    /// Flat keys, the live one lit along its top edge.
    private var keys: some View {
        HStack(spacing: 7) {
            ForEach(PaxDynamicMode.allCases) { mode in
                button(mode) {
                    VStack(spacing: 7) {
                        Image(systemName: mode.icon).font(.system(size: 18))
                        Text(t.labelText(mode.label))
                            .font(t.body(9.5, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: t.metric(.modeHeight))
                    .background(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
                        .fill(t.plate))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(isActive(mode) ? t.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous))
                    .foregroundStyle(isActive(mode) ? t.ink : t.muted)
                }
            }
        }
        .padding(.horizontal, t.gutter)
    }

    /// A checkmark list, native-style, or a contents list when the theme draws
    /// no fills — the same rows either way.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(PaxDynamicMode.allCases.enumerated()), id: \.element.id) { index, mode in
                if index > 0 {
                    Rectangle().fill(t.hairline)
                        .frame(height: t.hairlineWidth)
                        .padding(.leading, t.radius > 4 ? 49 : 0)
                }
                button(mode) {
                    HStack(spacing: 12) {
                        if t.radius > 4 {
                            Image(systemName: mode.icon)
                                .font(.system(size: 21))
                                .foregroundStyle(isActive(mode) ? t.accent : t.muted)
                                .frame(width: 21)
                        } else if isActive(mode) {
                            Rectangle().fill(t.accent).frame(width: 14, height: 1)
                        } else {
                            Color.clear.frame(width: 14, height: 1)
                        }
                        Text(mode.label)
                            .font(t.display(t.radius > 4 ? 17 : 19, .regular))
                            .foregroundStyle(isActive(mode) ? (t.radius > 4 ? t.ink : t.accent) : t.muted)
                        Spacer(minLength: 0)
                        if isActive(mode) && t.radius > 4 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(t.accent)
                        }
                    }
                    .padding(.horizontal, t.radius > 4 ? 16 : 0)
                    .frame(height: t.metric(.modeHeight))
                    .contentShape(Rectangle())
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous)
            .fill(t.radius > 4 ? t.plate : Color.clear))
        .padding(.horizontal, t.gutter)
    }

    /// A run of words, the live one underscored.
    private var words: some View {
        HStack(spacing: 14) {
            ForEach(PaxDynamicMode.allCases) { mode in
                button(mode) {
                    Text(t.labelText(mode.label))
                        .font(t.body(13, isActive(mode) ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isActive(mode) ? t.accent : t.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: t.metric(.modeHeight))
                        .overlay(alignment: .bottom) {
                            if isActive(mode) {
                                Rectangle().fill(t.accent).frame(height: 2).padding(.bottom, 8)
                            }
                        }
                }
            }
        }
        .padding(.horizontal, t.gutter)
    }

    /// A five-position selector, the live position raised out of its track.
    private var selector: some View {
        HStack(spacing: 3) {
            ForEach(PaxDynamicMode.allCases) { mode in
                button(mode) {
                    Text(t.labelText(mode.label))
                        .font(t.body(10.5, isActive(mode) ? .bold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: t.metric(.modeHeight) - 6)
                        .background(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(isActive(mode) ? t.plate : Color.clear)
                        )
                        .overlay(alignment: .bottom) {
                            if isActive(mode) {
                                Rectangle().fill(t.accent).frame(height: 2)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .foregroundStyle(isActive(mode) ? t.ink : t.muted)
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: t.metric(.plateRadius), style: .continuous)
            .fill(t.track))
        .padding(.horizontal, t.gutter)
    }

    /// The name, and five dots under it: swipe the object to change.
    private var dots: some View {
        VStack(spacing: 9) {
            HStack(spacing: 14) {
                chevron("chevron.left", to: -1)
                Text(t.labelText(viewModel.dynamicMode?.label ?? "—"))
                    .font(t.body(13, .bold))
                    .tracking(t.labelTracking)
                    .foregroundStyle(t.ink)
                    .frame(minWidth: 120)
                chevron("chevron.right", to: 1)
            }
            HStack(spacing: 7) {
                ForEach(PaxDynamicMode.allCases) { mode in
                    Circle()
                        .fill(isActive(mode) ? t.ink : t.track)
                        .frame(width: 7, height: 7)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chevron(_ symbol: String, to step: Int) -> some View {
        Button {
            let modes = PaxDynamicMode.allCases
            guard let current = viewModel.dynamicMode,
                  let index = modes.firstIndex(of: current) else { return }
            let next = (index + step + modes.count) % modes.count
            viewModel.setDynamicMode(modes[next])
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(t.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Not connected

/// The discovery screen, themed. Kept in one place so every shell gets the same
/// behaviour when there is no device to draw.
struct ThemedDiscovery: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    let context: ThemeContext

    private var t: ThemeTokens { context.tokens }

    private var detail: String {
        if case .error(let message) = viewModel.connectionState { return message }
        if viewModel.automationPaused {
            return "Disconnected. Tap Connect to look for your PAX again."
        }
        return "Make sure your PAX is awake and within a few metres. It connects on its own."
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.scannedDevices.isEmpty {
                Spacer()
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(t.muted)
                    .frame(width: 84, height: 84)
                    .background(t.plate, in: Circle())
                Text(viewModel.statusHeadline)
                    .font(t.display(22, .bold))
                    .foregroundStyle(t.ink)
                    .padding(.top, 20)
                Text(detail)
                    .font(t.body(15))
                    .foregroundStyle(t.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 7)
                    .padding(.horizontal, 40)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.labelText("Available devices"))
                        .font(t.label())
                        .tracking(t.labelTracking)
                        .foregroundStyle(t.muted)
                        .padding(.horizontal, t.gutter + 4)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                    VStack(spacing: 8) {
                        ForEach(viewModel.scannedDevices) { device in
                            Button { viewModel.connect(to: device) } label: { row(device) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, t.gutter)
                }
                Spacer(minLength: 0)
            }

            if viewModel.automationPaused {
                Button { viewModel.resumeAutomation() } label: {
                    Text("Connect")
                        .font(t.body(16, .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(t.accent, in: Capsule())
                        .foregroundStyle(t.onAccent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, t.gutter)
                .padding(.vertical, 18)
            }
        }
        .onAppear { viewModel.resumeDiscoveryIfIdle() }
    }

    private func row(_ device: ScannedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 19))
                .foregroundStyle(t.accent)
                .frame(width: 42, height: 42)
                .background(t.accentWash, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(t.body(17, .semibold)).foregroundStyle(t.ink)
                Text("\(device.rssi) dBm")
                    .font(t.body(12)).monospacedDigit().foregroundStyle(t.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.muted)
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(t.plate))
        .contentShape(Rectangle())
    }
}
