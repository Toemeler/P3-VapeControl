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
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

    private var unit: TemperatureUnit { settings.temperatureUnit }

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
                    LabeledContent("Sessions", value: "\(store.finished.count)")
                    LabeledContent("Draws", value: "\(store.totalDraws)")
                    LabeledContent("Time heating", value: "\(store.totalHeatingMinutes) min")
                } header: {
                    Text("All time")
                }
            }

            ForEach(store.sessions) { session in
                Section {
                    SessionRow(session: session, unit: unit)
                } header: {
                    HStack {
                        Text(session.startedAt, format: .dateTime.weekday().hour().minute())
                        if session.isRunning {
                            Text("· running")
                                .foregroundStyle(.orange)
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
