import SwiftUI

/// One screen, because a watch is a glance and a tap.
///
/// The ring is the same idea as the phone's: the arc is where the oven sits on
/// the dial's range, the hairline inside it is the battery. Under it, the two
/// things worth doing from a wrist — move the temperature, and stop the oven.
struct WatchRootView: View {
    @EnvironmentObject private var link: WatchLink

    private var snapshot: PaxSnapshot? { link.snapshot }

    private var accent: Color {
        snapshot.flatMap { LedColor.fromHex($0.ledColorHex)?.color } ?? LedColor.orange.color
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ring
                status
                controls
                if !link.profileNames.isEmpty { profiles }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(snapshot?.deviceName ?? "PAX")
        .onAppear { link.refresh() }
    }

    // MARK: - Parts

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.gray.opacity(0.25), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.01, temperatureFraction))
                .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: max(0.01, Double(snapshot?.batteryLevel ?? 0) / 100))
                .stroke(batteryColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(10)
            VStack(spacing: 0) {
                Text(snapshot?.temperatureText ?? "--")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(snapshot?.batteryText ?? "--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 110)
        .padding(.top, 2)
    }

    private var temperatureFraction: Double {
        guard let celsius = snapshot?.actualTempC else { return 0 }
        let low = 180.0, high = 225.0
        return min(1, max(0, (celsius - low) / (high - low)))
    }

    private var batteryColor: Color {
        guard let level = snapshot?.batteryLevel else { return .secondary }
        if snapshot?.isCharging == true { return .green }
        return level <= 15 ? .red : .secondary
    }

    private var status: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(link.reachable ? Color.secondary : Color.orange)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }

    /// The watch is a window onto the phone, so when the phone is not there it
    /// says so rather than showing the last reading as though it were current.
    private var statusText: String {
        guard link.reachable else { return "iPhone out of reach" }
        guard let snapshot else { return "Waiting for the phone" }
        guard snapshot.isConnected else { return snapshot.headline }
        if snapshot.isStale { return "Last seen a while ago" }
        return snapshot.headline
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                stepButton("minus", delta: -1)
                Text(targetText)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                stepButton("plus", delta: 1)
            }

            Button {
                link.setOven(on: false)
            } label: {
                Label("Stop the oven", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(!link.reachable)
        }
    }

    private var targetText: String {
        guard let snapshot, let target = snapshot.targetTempC else { return "--" }
        let value = snapshot.useFahrenheit ? (target * 9 / 5) + 32 : target
        return String(format: "%.0f°", value)
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button {
            link.stepTemperature(delta)
        } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
        }
        .disabled(!link.reachable)
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(link.profileNames, id: \.self) { name in
                Button(name) { link.applyProfile(named: name) }
                    .disabled(!link.reachable)
            }
        }
        .padding(.top, 4)
    }
}
