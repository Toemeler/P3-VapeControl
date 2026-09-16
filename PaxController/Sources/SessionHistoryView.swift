import SwiftUI

/// What the PAX has been doing, which nothing else can tell you.
///
/// A PAX 3 keeps no session log — the log service the official app reads is an
/// Era feature, and a full GATT enumeration of this device does not have it. So
/// this is the app's own record, written while it was connected, and honest
/// about the fact: a session is what the phone saw, and a gap in the curve is a
/// gap in the connection.
struct SessionHistoryView: View {
    @ObservedObject private var store = PaxSessionStore.shared
    @ObservedObject private var chargeStore = PaxChargeStore.shared
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var confirmingChargeClear = false
    @State private var measure: SessionChartMeasure = .sessions

    private var accent: Color { DS.Palette.accent }

    private var unit: TemperatureUnit { settings.temperatureUnit }

    private var averageDraws: String {
        let sessions = store.finished
        guard !sessions.isEmpty else { return "0" }
        return String(format: "%.1f", Double(store.totalDraws) / Double(sessions.count))
    }

    var body: some View {
        List {
            if store.sessions.isEmpty {
                Section {
                    Text(settings.sessionHistoryEnabled
                         ? "Nothing yet. A session is recorded from the moment the oven starts heating until it goes cold."
                         : "Session history is switched off, so nothing is being recorded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        SessionStatTile(value: "\(store.finished.count)", label: "sessions")
                        SessionStatTile(value: "\(store.totalDraws)", label: "draws")
                        SessionStatTile(value: "\(store.totalHeatingMinutes)m", label: "heating")
                        SessionStatTile(value: averageDraws, label: "draws each")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("All time")
                }

                Section {
                    Picker("Measure", selection: $measure) {
                        ForEach(SessionChartMeasure.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    DailyTotalsChart(days: store.dailyTotals(days: 14),
                                     measure: measure,
                                     accent: accent)
                        .padding(.top, 4)
                } header: {
                    Text("Last 14 days")
                } footer: {
                    Text("One measure at a time, on one axis. Days with nothing on them are kept, because a quiet week is part of the shape.")
                }

                Section {
                    TimeOfDayChart(bands: store.hourBands(), accent: accent)
                } header: {
                    Text("When")
                }
            }

            chargingSection

            ForEach(store.sessions) { session in
                Section {
                    NavigationLink {
                        SessionDetailView(session: session, unit: unit)
                    } label: {
                        SessionRow(session: session, unit: unit)
                    }
                } header: {
                    HStack {
                        Text(session.startedAt, format: .dateTime.weekday().hour().minute())
                        if session.isRunning {
                            Text("· running")
                                .foregroundStyle(DS.Palette.accent)
                        }
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { store.sessions[$0] }.forEach(store.delete)
            }

            if !store.sessions.isEmpty {
                Section {
                    Button("Delete all sessions", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Delete every recorded session?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone. Nothing is stored anywhere but on this phone, so there is no copy to fall back on.")
        }
        .confirmationDialog("Delete every recorded charge?",
                            isPresented: $confirmingChargeClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { chargeStore.deleteAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// What the charger has been doing. The device never says how long it has
    /// been filling or how fast, so this is the app's own record of it — the
    /// same bargain as the sessions above, and the only way to know whether a
    /// charge is taking longer than it used to.
    @ViewBuilder
    private var chargingSection: some View {
        let finished = chargeStore.finished
        if !finished.isEmpty {
            Section {
                HStack(spacing: 12) {
                    SessionStatTile(value: "\(finished.count)", label: "charges")
                    SessionStatTile(value: averageTo(100), label: "to full")
                    SessionStatTile(value: averageTo(80), label: "to 80%")
                    SessionStatTile(value: lastCharge, label: "last")
                }
                .padding(.vertical, 4)
                ChargeCurveChart(charges: chargeStore.recentCurves())
                    .padding(.top, 4)
                Button("Delete all charges", role: .destructive) { confirmingChargeClear = true }
            } header: {
                Text("Charging")
            } footer: {
                Text("The newest charge is drawn in front. An average only counts charges that actually reached the level, since one unplugged early says nothing about how long it would have taken.")
            }
        }
    }

    private func averageTo(_ level: Int) -> String {
        guard let seconds = chargeStore.averageSeconds(to: level) else { return "—" }
        return PaxCharge.text(for: seconds)
    }

    private var lastCharge: String {
        guard let latest = chargeStore.finished.first else { return "—" }
        return latest.durationText
    }
}

private struct SessionRow: View {
    let session: PaxSession
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                stat(session.durationText, "length")
                stat("\(session.draws)", session.draws == 1 ? "draw" : "draws")
                if let peak = session.peakTempC {
                    stat(unit.format(peak, decimals: 0), "peak")
                }
                if let set = session.setPointC {
                    stat(unit.format(set, decimals: 0), "set to")
                }
            }

            if session.samples.count >= 2 {
                SessionCurve(samples: session.samples)
                    .frame(height: 44)
            }

            if let mode = session.modeRaw, let label = PaxProfile.modeLabel(mode) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let ending = session.ending {
                Text(ending.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The session's temperature over time, drawn against its own range rather than
/// the dial's: a stealth session at 180 and a full one at 215 should both fill
/// the height, because the shape is the point, not the absolute level — which
/// the numbers above already give.
private struct SessionCurve: View {
    let samples: [PaxSession.Sample]

    var body: some View {
        GeometryReader { geometry in
            let values = samples.map(\.celsius)
            let low = (values.min() ?? 0) - 1
            let high = (values.max() ?? 1) + 1
            let span = max(1, high - low)
            let duration = max(1, samples.last?.at ?? 1)

            Path { path in
                for (index, sample) in samples.enumerated() {
                    let x = geometry.size.width * (sample.at / duration)
                    let y = geometry.size.height * (1 - (sample.celsius - low) / span)
                    let point = CGPoint(x: x, y: y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(DS.Palette.accent,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// One session on its own, where there is room for the curve to be read rather
/// than glanced at.
private struct SessionDetailView: View {
    let session: PaxSession
    let unit: TemperatureUnit

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    SessionStatTile(value: session.durationText, label: "length")
                    SessionStatTile(value: "\(session.draws)", label: session.draws == 1 ? "draw" : "draws")
                    if let peak = session.peakTempC {
                        SessionStatTile(value: unit.format(peak, decimals: 0), label: "peak")
                    }
                }
                .padding(.vertical, 4)
            }

            if session.samples.count >= 2 {
                Section {
                    SessionCurveChart(session: session,
                                      accent: DS.Palette.accent,
                                      unit: unit)
                } header: {
                    Text("Temperature")
                } footer: {
                    Text("Recorded by this app while it was connected, a reading every few seconds. A flat stretch is a gap in the connection, not a gap in the heating.")
                }
            }

            Section {
                LabeledContent("Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let ended = session.endedAt {
                    LabeledContent("Ended", value: ended.formatted(date: .omitted, time: .shortened))
                }
                if let set = session.setPointC {
                    LabeledContent("Set to", value: unit.format(set, decimals: 0))
                }
                if let raw = session.modeRaw, let label = PaxProfile.modeLabel(raw) {
                    LabeledContent("Mode", value: label)
                }
                if let ending = session.ending {
                    LabeledContent("Ended by", value: ending.label)
                }
            } header: {
                Text("Details")
            }
        }
        .navigationTitle(session.startedAt.formatted(.dateTime.weekday().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
