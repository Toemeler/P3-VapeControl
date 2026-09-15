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
            let state = context.state
            let accent = state.accent
            // The expanded island gets the same ring as the Lock Screen card,
            // for the same reason the three card states share a skeleton: the
            // two surfaces are one app, and a reading should not have to be
            // re-learned because it moved a few hundred points up the screen.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusRing(state: state)
                        .frame(width: 38, height: 38)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.leadNumber)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundColor(accent)
                            .contentTransition(.numericText())
                        Label(state.batteryText, systemImage: state.batteryIcon)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.deviceName)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(state.headline)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: state.statusIcon)
                    .foregroundColor(accent)
            } compactTrailing: {
                // The compact trailing slot is a few characters wide, so it
                // carries whichever number the state is actually about rather
                // than always the battery: the temperature while the oven is
                // doing something, the charge while it is on the charger.
                Text(state.compactNumber)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(accent)
                    .contentTransition(.numericText())
            } minimal: {
                Image(systemName: state.statusIcon)
                    .foregroundColor(accent)
            }
        }
    }
}

// MARK: - Lock Screen

/// One skeleton for all three states — heating, charging, waiting — because a
/// card that rearranges itself is a card that has to be read again every time.
/// The ring on the left, the name and what it is doing in the middle, the one
/// number worth a glance on the right. What changes between the states is what
/// the ring measures and which number leads, never where they sit.
private struct LockScreenCard: View {
    let attributes: PaxActivityAttributes
    let state: PaxActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            StatusRing(state: state)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(attributes.deviceName)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.headline)
                    .font(.subheadline)
                    .foregroundColor(state.isConnected ? state.accent : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(state.leadNumber)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundColor(state.isConnected ? .primary : .secondary)
                    .contentTransition(.numericText())
                subline
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The second line earns its place only when it says something the lead
    /// number does not: where the oven is going, or how long the PAX has been
    /// out of reach. The relative date keeps counting on its own, without the
    /// app having to spend an update on it.
    @ViewBuilder
    private var subline: some View {
        switch state.phase {
        case .waiting:
            if let seen = state.lastSeen {
                HStack(spacing: 3) {
                    Text("last seen")
                    Text(seen, style: .relative)
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            } else {
                Text("not seen yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .charging:
            Label("charging", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        default:
            HStack(spacing: 4) {
                if state.isOvenActive {
                    Text("to \(state.targetTempText)")
                }
                Image(systemName: state.batteryIcon)
                Text(state.batteryText)
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }
}

/// The app's dial, small enough to read at a glance: the outer arc is what the
/// state is about — how far up the scale the oven is, or how full the battery
/// is on the charger — and the hairline inside it is always the battery, thin
/// when there is plenty and thick and red when there is not. Same language as
/// the screen the card opens into.
private struct StatusRing: View {
    let state: PaxActivityAttributes.ContentState

    private var batteryFraction: Double {
        Double(state.batteryLevel ?? 0) / 100
    }

    /// Thin when full, thick when empty — thickness carries the reading, so a
    /// low battery is louder than a full one without needing a colour alone.
    private var batteryWidth: Double {
        let low = 1.5 + (1 - batteryFraction) * 2.5
        return state.phase == .charging ? 3.5 : low
    }

    private var batteryColor: Color {
        if state.phase == .charging { return .green }
        if batteryFraction <= 0.15 { return .red }
        return .secondary
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 4)

            Circle()
                .trim(from: 0, to: max(0.004, state.ringFraction))
                .stroke(state.ringColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(state.phase == .waiting ? 0.25 : 1)

            Circle()
                .trim(from: 0, to: max(0.004, batteryFraction))
                .stroke(batteryColor,
                        style: StrokeStyle(lineWidth: batteryWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(6)
                .opacity(state.isConnected ? 1 : 0.4)

            Image(systemName: state.statusIcon)
                .font(.caption2)
                .foregroundColor(state.accent)
        }
    }
}

// MARK: - Shared presentation helpers

// Members rather than free functions: a global `accentColor(for:)` is shadowed
// by SwiftUI's own `View.accentColor(_:)` inside any View body that calls it.
private extension PaxActivityAttributes.ContentState {
    var accent: Color {
        guard isConnected else { return .secondary }
        if phase == .charging { return .green }
        return LedColor.fromHex(ledColorHex)?.color ?? LedColor.orange.color
    }

    /// While the oven is climbing the ring follows the same green-through-orange
    /// gradient the PAX's own LEDs show, so the card and the device in your hand
    /// are saying the same thing. Once it is there, it is the accent.
    var ringColor: Color {
        switch phase {
        case .charging: return .green
        case .waiting:  return .secondary
        case .heating:  return LedColor.warmUp(progress: warmUpFraction).color
        default:        return accent
        }
    }

    var statusIcon: String {
        switch phase {
        case .waiting:  return "antenna.radiowaves.left.and.right"
        case .charging: return "bolt.fill"
        case .drawing:  return "wind"
        case .cooling:  return "arrow.down.right"
        case .standby:  return "moon.zzz.fill"
        case .ovenOff:  return "flame.slash"
        case .ready:    return "checkmark"
        case .heating:  return "flame.fill"
        }
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
