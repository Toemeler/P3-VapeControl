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
            let accent = accentColor(for: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.batteryText, systemImage: batteryIcon(for: context.state))
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
                Image(systemName: statusIcon(for: context.state))
                    .foregroundColor(accent)
            } compactTrailing: {
                Text(context.state.isConnected ? context.state.batteryText : "--")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(accent)
            } minimal: {
                Image(systemName: statusIcon(for: context.state))
                    .foregroundColor(accent)
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenCard: View {
    let attributes: PaxActivityAttributes
    let state: PaxActivityAttributes.ContentState

    private var accent: Color { accentColor(for: state) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: statusIcon(for: state))
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
                    Image(systemName: batteryIcon(for: state))
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

private func accentColor(for state: PaxActivityAttributes.ContentState) -> Color {
    guard state.isConnected else { return .secondary }
    return LedColor.fromHex(state.ledColorHex)?.color ?? LedColor.orange.color
}

private func statusIcon(for state: PaxActivityAttributes.ContentState) -> String {
    if !state.isConnected { return "bolt.horizontal.circle" }
    if state.isCharging { return "bolt.fill" }
    return "flame.fill"
}

private func batteryIcon(for state: PaxActivityAttributes.ContentState) -> String {
    guard let level = state.batteryLevel else { return "battery.0" }
    switch level {
    case 76...:   return "battery.100"
    case 51..<76: return "battery.75"
    case 26..<51: return "battery.50"
    case 11..<26: return "battery.25"
    default:      return "battery.0"
    }
}
