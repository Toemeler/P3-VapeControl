import ActivityKit
import SwiftUI
import WidgetKit

/// The always-on Lock Screen card and Dynamic Island presentation for the
/// connected PAX. The app keeps this alive across disconnects — showing
/// "Waiting for PAX…" rather than ending it — because iOS only allows an app
/// to *start* a Live Activity from the foreground, while background BLE
/// callbacks may only *update* one.
struct PaxStatusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PaxActivityAttributes.self) { context in
            LockScreenCard(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let accent = context.state.accent
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.batteryText, systemImage: context.state.batteryIcon)
                        .font(.caption)
                        .foregroundColor(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.actualTempText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(accent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.deviceName)
                            .font(.headline)
                        Spacer()
                        Text(context.state.headline)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.statusIcon)
                    .foregroundColor(accent)
            } compactTrailing: {
                Text(context.state.isConnected ? context.state.batteryText : "--")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(accent)
            } minimal: {
                Image(systemName: context.state.statusIcon)
                    .foregroundColor(accent)
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenCard: View {
    let attributes: PaxActivityAttributes
    let state: PaxActivityAttributes.ContentState

    private var accent: Color { state.accent }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: state.statusIcon)
                    .font(.title3)
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(attributes.deviceName)
                    .font(.headline)
                Text(state.headline)
                    .font(.subheadline)
                    .foregroundColor(state.isConnected ? accent : .secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    if state.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                    Image(systemName: state.batteryIcon)
                        .font(.caption)
                    Text(state.batteryText)
                        .font(.subheadline.monospacedDigit())
                }
                if state.isConnected {
                    Text("\(state.actualTempText) → \(state.targetTempText)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Shared presentation helpers

// Members rather than free functions: a global `accentColor(for:)` is shadowed
// by SwiftUI's own `View.accentColor(_:)` inside any View body that calls it.
private extension PaxActivityAttributes.ContentState {
    var accent: Color {
        guard isConnected else { return .secondary }
        return LedColor.fromHex(ledColorHex)?.color ?? LedColor.orange.color
    }

    var statusIcon: String {
        if !isConnected { return "bolt.horizontal.circle" }
        if isCharging { return "bolt.fill" }
        return "flame.fill"
    }

    var batteryIcon: String {
        guard let level = batteryLevel else { return "battery.0" }
        switch level {
        case 76...:   return "battery.100"
        case 51..<76: return "battery.75"
        case 26..<51: return "battery.50"
        case 11..<26: return "battery.25"
        default:      return "battery.0"
        }
    }
}
