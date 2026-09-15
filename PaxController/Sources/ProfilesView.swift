import SwiftUI

/// Saved ways of running the PAX.
///
/// A temperature, a mode and a colour settle together in practice — a
/// temperature for the material, a mode for how hard to push it, a colour so
/// the device says which is which from across the room — and setting them one
/// at a time from three parts of the app is three taps for one decision.
struct ProfilesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewModel: PaxDeviceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PaxProfile?

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        List {
            Section {
                ForEach(settings.profiles) { profile in
                    Button {
                        viewModel.apply(profile)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(profile.ledHex.flatMap(LedColor.fromHex)?.color ?? .secondary)
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .foregroundStyle(.primary)
                                Text(displaySummary(profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                editing = profile
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Edit \(profile.name)")
                        }
                    }
                    .disabled(!viewModel.canSendCommands)
                }
                .onDelete { settings.profiles.remove(atOffsets: $0) }
                .onMove { settings.profiles.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Profiles")
            } footer: {
                Text(viewModel.canSendCommands
                     ? "Tap one to apply it. Siri can too: \u{201C}Apply a profile in PAX Controller\u{201D}."
                     : "Connect to the PAX to apply one.")
            }

            Section {
                Button {
                    let new = PaxProfile(name: "New profile",
                                         temperatureC: viewModel.customTargetTempC,
                                         modeRaw: viewModel.dynamicMode?.rawValue,
                                         ledHex: settings.ledColorHex)
                    settings.profiles.append(new)
                    editing = new
                } label: {
                    Label("Add from what the PAX is set to now", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { EditButton() }
        }
        .sheet(item: $editing) { profile in
            NavigationStack {
                ProfileEditor(profile: profile)
            }
        }
    }

    private func displaySummary(_ profile: PaxProfile) -> String {
        var parts = [unit.format(profile.temperatureC, decimals: 0)]
        if let raw = profile.modeRaw, let label = PaxProfile.modeLabel(raw) { parts.append(label) }
        return parts.joined(separator: " · ")
    }
}

private struct ProfileEditor: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PaxProfile

    init(profile: PaxProfile) {
        _draft = State(initialValue: profile)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
            }

            Section {
                Stepper(value: $draft.temperatureC, in: DS.Range.min...DS.Range.max, step: 1) {
                    LabeledContent("Temperature",
                                   value: settings.temperatureUnit.format(draft.temperatureC, decimals: 0))
                }
            }

            Section {
                Picker("Mode", selection: Binding(
                    get: { draft.modeRaw.map(Int.init) ?? -1 },
                    set: { draft.modeRaw = $0 < 0 ? nil : UInt8($0) })) {
                    Text("Leave alone").tag(-1)
                    ForEach(0..<5, id: \.self) { raw in
                        Text(PaxProfile.modeLabel(UInt8(raw)) ?? "\(raw)").tag(raw)
                    }
                }
            } footer: {
                Text("A mode is a block of heating parameters, so applying one writes the temperatures that go with it.")
            }

            Section {
                Toggle("Set a colour", isOn: Binding(
                    get: { draft.ledHex != nil },
                    set: { draft.ledHex = $0 ? settings.ledColorHex : nil }))
                if draft.ledHex != nil {
                    LedColorGrid(selection: Binding(
                        get: { draft.ledHex.flatMap(LedColor.fromHex) ?? .orange },
                        set: { draft.ledHex = $0.hex }))
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "Profile" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let index = settings.profiles.firstIndex(where: { $0.id == draft.id }) {
                        settings.profiles[index] = draft
                    } else {
                        settings.profiles.append(draft)
                    }
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// The shipped colours as a grid of swatches. Small enough to sit inside a form
/// row rather than pushing a colour picker screen for one decision.
private struct LedColorGrid: View {
    @Binding var selection: LedColor

    private let columns = [GridItem(.adaptive(minimum: 38), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(LedColor.presets) { color in
                Circle()
                    .fill(color.color)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Circle()
                            .strokeBorder(.primary, lineWidth: selection.hex == color.hex ? 2 : 0)
                    }
                    .onTapGesture { selection = color }
                    .accessibilityLabel(color.name)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The session's temperature, changing as it goes.
///
/// The device has one of these — Efficiency ramps on a fixed curve — but it is
/// the firmware's curve, it costs you the set point, and it is measured in time
/// rather than in draws. This one counts draws, which is what a session is
/// actually made of, and writes the set point the ordinary way, so it works in
/// whichever mode you prefer.
struct ScheduleView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewModel: PaxDeviceViewModel

    private var unit: TemperatureUnit { settings.temperatureUnit }

    private var sorted: [PaxSchedule.Step] {
        settings.schedule.steps.sorted { $0.afterDraws < $1.afterDraws }
    }

    var body: some View {
        List {
            Section {
                Toggle("Step the temperature through a session", isOn: $settings.scheduleEnabled)
            } footer: {
                Text("Each step is written when the session reaches that many draws. The first step, at zero draws, is set when the oven starts heating.")
            }

            Section {
                ForEach($settings.schedule.steps) { $step in
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper(value: $step.afterDraws, in: 0...30) {
                            Text(step.afterDraws == 0
                                 ? "From the start"
                                 : "After \(step.afterDraws) draw\(step.afterDraws == 1 ? "" : "s")")
                        }
                        Stepper(value: $step.temperatureC, in: DS.Range.min...DS.Range.max, step: 1) {
                            LabeledContent("Temperature",
                                           value: unit.format(step.temperatureC, decimals: 0))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { settings.schedule.steps.remove(atOffsets: $0) }

                Button {
                    let nextDraw = (settings.schedule.steps.map(\.afterDraws).max() ?? -1) + 3
                    let nextTemp = min(DS.Range.max,
                                       (settings.schedule.steps.map(\.temperatureC).max() ?? 185) + 10)
                    settings.schedule.steps.append(
                        PaxSchedule.Step(afterDraws: nextDraw, temperatureC: nextTemp))
                } label: {
                    Label("Add a step", systemImage: "plus")
                }
            } header: {
                Text("Steps")
            } footer: {
                Text(settings.schedule.isUsable
                     ? settings.schedule.summary
                     : "With no steps, nothing is written and the set point stays where you put it.")
            }

            if let session = viewModel.runningSession, settings.scheduleEnabled {
                Section {
                    LabeledContent("Draws so far", value: "\(session.draws)")
                    if let now = settings.schedule.temperature(atDraws: session.draws) {
                        LabeledContent("In force now", value: unit.format(now, decimals: 0))
                    }
                } header: {
                    Text("This session")
                }
            }
        }
        .navigationTitle("Temperature schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { EditButton() }
        }
    }
}
