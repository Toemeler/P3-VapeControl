import Charts
import SwiftUI

/// The session record, drawn.
///
/// One series per chart throughout, which is what the data is: this is not
/// several things being told apart, it is one measure over time. So there is no
/// legend anywhere here — the title says what is plotted — and the marks wear
/// the app's accent while every piece of text stays in a text colour.
///
/// That accent is whatever the user picked for the LEDs, so its contrast
/// against the surface cannot be guaranteed. Every chart below is therefore
/// backed by something readable without colour: axis values, a label on the
/// one bar worth naming, and the session list underneath, which is the same
/// data as a table.
enum SessionChartMeasure: String, CaseIterable, Identifiable {
    case sessions, draws, minutes
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .draws:    return "Draws"
        case .minutes:  return "Minutes"
        }
    }
}

/// One day's totals.
struct SessionDay: Identifiable {
    let date: Date
    var sessions: Int
    var draws: Int
    var minutes: Double
    var id: Date { date }

    func value(_ measure: SessionChartMeasure) -> Double {
        switch measure {
        case .sessions: return Double(sessions)
        case .draws:    return Double(draws)
        case .minutes:  return minutes
        }
    }
}

extension PaxSessionStore {
    /// The last `days` days, including the empty ones — a gap in use is part of
    /// the shape, and dropping empty days would draw a busier week than there
    /// was.
    func dailyTotals(days: Int, calendar: Calendar = .current) -> [SessionDay] {
        let today = calendar.startOfDay(for: Date())
        var buckets: [Date: SessionDay] = [:]
        for offset in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            buckets[date] = SessionDay(date: date, sessions: 0, draws: 0, minutes: 0)
        }
        for session in finished {
            let day = calendar.startOfDay(for: session.startedAt)
            guard buckets[day] != nil else { continue }
            buckets[day]?.sessions += 1
            buckets[day]?.draws += session.draws
            buckets[day]?.minutes += session.duration / 60
        }
        return buckets.values.sorted { $0.date < $1.date }
    }

    /// Sessions by hour of the day, in three-hour bands: twenty-four bars on a
    /// phone is a picket fence, eight is a shape.
    func hourBands(calendar: Calendar = .current) -> [(band: Int, sessions: Int)] {
        var counts = Array(repeating: 0, count: 8)
        for session in finished {
            let hour = calendar.component(.hour, from: session.startedAt)
            counts[min(7, hour / 3)] += 1
        }
        return counts.enumerated().map { (band: $0.offset, sessions: $0.element) }
    }
}

// MARK: - Daily totals

struct DailyTotalsChart: View {
    let days: [SessionDay]
    let measure: SessionChartMeasure
    let accent: Color

    private var peak: SessionDay? {
        days.max { $0.value(measure) < $1.value(measure) }
    }

    var body: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value(measure.label, day.value(measure)),
                // Capped well under 24pt, and the leftover of each band is left
                // as air rather than filled.
                width: .ratio(0.6)
            )
            .cornerRadius(4)
            .foregroundStyle(accent)
            .annotation(position: .top, spacing: 2) {
                // One label, on the day worth naming. A number over every bar
                // is noise, and the axis carries the rest.
                if let peak, peak.id == day.id, peak.value(measure) > 0 {
                    Text(text(peak.value(measure)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(text(number)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { value in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
            }
        }
        .frame(height: 150)
        .accessibilityLabel("\(measure.label) per day")
        .accessibilityValue(days.map { "\(shortDay($0.date)) \(text($0.value(measure)))" }
            .joined(separator: ", "))
    }

    private func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.0f", value)
    }

    private func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: - Time of day

struct TimeOfDayChart: View {
    let bands: [(band: Int, sessions: Int)]
    let accent: Color

    private var busiest: Int? {
        bands.max { $0.sessions < $1.sessions }?.band
    }

    var body: some View {
        Chart(bands, id: \.band) { entry in
            BarMark(
                x: .value("Time", label(entry.band)),
                y: .value("Sessions", entry.sessions),
                width: .ratio(0.6)
            )
            .cornerRadius(4)
            .foregroundStyle(accent)
            .annotation(position: .top, spacing: 2) {
                if entry.band == busiest, entry.sessions > 0 {
                    Text("\(entry.sessions)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.caption2) }
        }
        .frame(height: 140)
        .accessibilityLabel("Sessions by time of day")
        .accessibilityValue(bands.map { "\(label($0.band)) \($0.sessions)" }.joined(separator: ", "))
    }

    private func label(_ band: Int) -> String {
        let hour = band * 3
        return hour == 0 ? "12a" : hour < 12 ? "\(hour)a" : hour == 12 ? "12p" : "\(hour - 12)p"
    }
}

// MARK: - One session

/// A session's temperature over its own length, with the draws marked on it.
///
/// The draws are not inferred from the curve: the PAX reports `boosting` while
/// it senses one, and those are the moments plotted. The set point is a plain
/// reference line rather than a second series — it is the same measure as the
/// curve, so it belongs on the same axis and needs no legend to explain it.
struct SessionCurveChart: View {
    let session: PaxSession
    let accent: Color
    let unit: TemperatureUnit
    var height: CGFloat = 180

    private var samples: [PaxSession.Sample] { session.samples }

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Minute", sample.at / 60),
                    y: .value("Temperature", display(sample.celsius))
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(accent)
            }

            if let set = session.setPointC {
                RuleMark(y: .value("Set point", display(set)))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.quaternary)
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text("set \(unit.format(set, decimals: 0))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            if let peak = samples.max(by: { $0.celsius < $1.celsius }) {
                PointMark(
                    x: .value("Minute", peak.at / 60),
                    y: .value("Temperature", display(peak.celsius))
                )
                .foregroundStyle(accent)
                // A ring in the surface colour, so the marker stays legible
                // where it sits on the line.
                .symbol {
                    ZStack {
                        Circle().fill(DS.Palette.canvas).frame(width: 13, height: 13)
                        Circle().fill(accent).frame(width: 9, height: 9)
                    }
                }
                .annotation(position: .top, spacing: 2) {
                    Text(unit.format(peak.celsius, decimals: 0))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text("\(Int(minutes))m").font(.caption2)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Temperature through the session")
        .accessibilityValue(curveDescription)
    }

    private func display(_ celsius: Double) -> Double {
        unit == .fahrenheit ? (celsius * 9 / 5) + 32 : celsius
    }

    private var curveDescription: String {
        guard let peak = samples.max(by: { $0.celsius < $1.celsius }) else { return "No readings" }
        return "\(session.draws) draws over \(session.durationText), peaking at \(unit.format(peak.celsius, decimals: 0))"
    }
}

// MARK: - Stat tiles

/// The headline numbers, which are not charts. A one-bar bar chart of "total
/// draws" would be a worse way to say a number than the number.
struct SessionStatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                // Proportional figures: equal-width digits make a large number
                // look loose.
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Charging

/// How the last few charges actually went: level against how long it took to
/// get there.
///
/// One line per charge, the most recent in front. The shape is the point — a
/// lithium cell drinks fast and then tapers, and a battery that has started to
/// go will show it here as a curve that leans over earlier than the ones
/// behind it. The marks are the ten-percent crossings the app watched, not
/// interpolation: where they bunch up the battery was filling quickly, where
/// they spread out it was not.
struct ChargeCurveChart: View {
    let charges: [PaxCharge]
    var height: CGFloat = 180

    private struct Point {
        let minute: Double
        let level: Int
    }

    private func points(of charge: PaxCharge) -> [Point] {
        var points = [Point(minute: 0, level: charge.startLevel)]
        points.append(contentsOf: charge.marks.map { Point(minute: $0.at / 60, level: $0.level) })
        return points
    }

    var body: some View {
        Chart {
            ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                ForEach(Array(points(of: charge).enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Minute", point.minute),
                        y: .value("Level", point.level),
                        series: .value("Charge", charge.id.uuidString)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: index == 0 ? 2.2 : 1.2,
                                           lineCap: .round, lineJoin: .round))
                    // The most recent charge is the one being asked about; the
                    // others are there to compare it against, so they recede.
                    .foregroundStyle(index == 0
                                     ? DS.Palette.charge
                                     : Color.secondary.opacity(0.3))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let level = value.as(Int.self) {
                        Text("\(level)%").font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text("\(Int(minutes))m").font(.caption2)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Charge curves")
        .accessibilityValue(description)
    }

    private var description: String {
        guard let latest = charges.first else { return "Nothing recorded" }
        return "Last charge: \(latest.startLevel) to \(latest.endLevel) percent in \(latest.durationText)"
    }
}
