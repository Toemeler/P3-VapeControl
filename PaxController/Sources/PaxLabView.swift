#if PAX_LAB
import SwiftUI
import UIKit

/// The lab build's own screen. Reads are free and run in bulk; snapshots are
/// how an undecoded attribute is pinned down by comparing the device in two
/// states; writes are deliberately awkward to reach, because a guessed payload
/// is what took this device offline the first time.
struct PaxLabView: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @StateObject private var lab = PaxLab.shared

    @State private var snapshotLabel = ""
    @State private var writeAttribute = ""
    @State private var writePayload = ""
    @State private var showWriteConfirm = false
    @State private var copied = false
    @State private var shareText = ""

    private var connected: Bool { viewModel.connectionState.isConnected }

    var body: some View {
        List {
            safetySection
            sweepSection
            attributesSection
            snapshotSection
            writeSection
            writeLogSection
            reportSection
        }
        .background(writeConfirmation)
        .navigationTitle("Lab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { shareText = report() }
        .onChange(of: lab.samples.count) { _ in shareText = report() }
        .onChange(of: lab.snapshots.count) { _ in shareText = report() }
        .onChange(of: lab.writes.count) { _ in shareText = report() }
    }

    private var safetySection: some View {
        Section {
            Label("Reading is safe. Writing is not.", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            Text("The sweep and the snapshots only ask the PAX for values — the same request the app already makes every three seconds — and cannot change anything on it. Writes can, and one that the firmware mishandles can take the device offline until it is power-cycled. Keep it in sight and off the charger while you experiment.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sweep

    private var sweepSection: some View {
        Section {
            Button {
                viewModel.labSweep()
            } label: {
                HStack {
                    Text("Read every attribute")
                    if lab.sweepInProgress {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!connected || lab.sweepInProgress)

            Button("Forget what was read", role: .destructive) { lab.forgetSamples() }
                .disabled(lab.samples.isEmpty)
        } header: {
            Text("Sweep")
        } footer: {
            Text("Asks for all 63 addressable attributes, three times over, in batches. Only the ones this firmware implements answer — silence is an answer too. Three reads separate the payload from the uninitialised bytes behind it.")
        }
    }

    // MARK: - What answered

    @ViewBuilder
    private var attributesSection: some View {
        if !lab.answeredAttributes.isEmpty {
            Section("Answered (\(lab.answeredAttributes.count))") {
                ForEach(lab.answeredAttributes, id: \.self) { attribute in
                    attributeRow(attribute)
                }
            }
        }
    }

    private func attributeRow(_ attribute: UInt8) -> some View {
        let payload = lab.stable(attribute) ?? Data()
        let name = PaxMessageType(rawValue: attribute).map { "\($0)" } ?? "unnamed"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(format: "0x%02X", attribute))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(payload.count) B")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(payload.isEmpty ? "—" : PaxLab.hex(payload))
                .font(.system(.caption, design: .monospaced))
            let notes = PaxDeviceViewModel.interpretation(of: payload, id: attribute)
            if !notes.isEmpty {
                Text(notes.trimmingCharacters(in: CharacterSet(charactersIn: " —")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.labRead(attribute: attribute) }
    }

    // MARK: - Snapshots

    private var snapshotSection: some View {
        Section {
            HStack {
                TextField("heating, charging, lid off…", text: $snapshotLabel)
                    .autocorrectionDisabled()
                Button("Capture") {
                    lab.takeSnapshot(label: snapshotLabel)
                    snapshotLabel = ""
                }
                .disabled(lab.answeredAttributes.isEmpty)
            }

            ForEach(lab.snapshots) { snapshot in
                HStack {
                    Text(snapshot.label)
                    Spacer()
                    Text("\(snapshot.values.count) attributes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if lab.snapshots.count >= 2 {
                let a = lab.snapshots[lab.snapshots.count - 2]
                let b = lab.snapshots[lab.snapshots.count - 1]
                let diffs = lab.differences(a, b)
                DisclosureGroup("\(a.label) → \(b.label): \(diffs.count) changed") {
                    if diffs.isEmpty {
                        Text("Nothing moved.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(diffs) { diff in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "0x%02X %@", diff.attribute,
                                        PaxMessageType(rawValue: diff.attribute).map { "\($0)" } ?? "unnamed"))
                                .font(.caption.weight(.semibold))
                            Text("\(diff.before)  →  \(diff.after)")
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }

            if !lab.snapshots.isEmpty {
                Button("Delete snapshots", role: .destructive) { lab.deleteSnapshots() }
            }
        } header: {
            Text("Snapshots")
        } footer: {
            Text("Sweep, then capture with the PAX in one state; change the state and do it again. The attributes that differ are the ones that mean something about that state — this is how HeatingParams gives up which byte is which.")
        }
    }

    // MARK: - Writes

    private var writeSection: some View {
        Section {
            TextField("Attribute, e.g. 19", text: $writeAttribute)
                .autocorrectionDisabled()
            TextField("Payload bytes, e.g. 01 or 00 0A", text: $writePayload)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            if let warning = writeWarning {
                Label(warning, systemImage: writeRefused ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(writeRefused ? Color.red : Color.orange)
            }
            Button("Write") { showWriteConfirm = true }
                .disabled(!connected || parsedWrite == nil || writeRefused)
                .foregroundStyle(writeRefused ? Color.secondary : Color.red)
        } header: {
            Text("Write")
        } footer: {
            Text("""
                 A payload the firmware does not expect can take the device offline: a three-byte write to ColorTheme once made a PAX read a mode count of 255 and walk two kilobytes off a fifteen-byte buffer. It came back on a power cycle, and everything seen so far does — but treat that as luck, not as a rule.

                 Sweep first so the device has told you how long the attribute is, match that length, and change one byte at a time. The value each attribute held before a write is kept, so any experiment can be put back.

                 The set point and the encryption attributes cannot be written from here at all: one aims a heating element, the others could leave a session that no power cycle re-establishes.
                 """)
        }
    }

    private var writeConfirmation: some View {
        EmptyView()
            .confirmationDialog("Write to the device?",
                                isPresented: $showWriteConfirm, titleVisibility: .visible) {
                Button("Write it", role: .destructive) {
                    if let write = parsedWrite {
                        viewModel.labWrite(attribute: write.attribute, payload: write.payload)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let write = parsedWrite {
                    Text(String(format: "0x%02X ← %@%@\n\nKeep the PAX in sight while you do this. If it goes quiet, power-cycle it; the write and the value it had before stay in the log.",
                                write.attribute,
                                PaxLab.hex(write.payload),
                                writeWarning.map { "\n\n\($0)" } ?? ""))
                }
            }
    }

    /// What the device itself last reported for the attribute being written,
    /// which is the length a write should match.
    private var knownLength: Int? {
        guard let write = parsedWrite else { return nil }
        return lab.stable(write.attribute)?.count
    }

    private var writeWarning: String? {
        guard let write = parsedWrite else { return nil }
        if let reason = PaxDeviceViewModel.labUnwritableAttributes[write.attribute] {
            return reason
        }
        guard let known = knownLength else {
            return "This attribute has not been read yet, so there is nothing to match the length against. Sweep first."
        }
        if known != write.payload.count {
            return "The device reports \(known) bytes for this attribute and you have typed \(write.payload.count). A length the firmware does not expect is what took a PAX offline over ColorTheme."
        }
        return nil
    }

    private var writeRefused: Bool {
        guard let write = parsedWrite else { return true }
        return PaxDeviceViewModel.labUnwritableAttributes[write.attribute] != nil
    }

    private var parsedWrite: (attribute: UInt8, payload: Data)? {
        guard let attributeByte = PaxLab.bytes(fromHex: writeAttribute)?.first,
              let payload = PaxLab.bytes(fromHex: writePayload), !payload.isEmpty else { return nil }
        return (attributeByte, payload)
    }

    @ViewBuilder
    private var writeLogSection: some View {
        if !lab.writes.isEmpty {
            Section {
                if let fatal = lab.lastFatalWrite {
                    Label(String(format: "0x%02X ← %@ was in flight when the device last went away",
                                 fatal.attribute, fatal.payloadHex),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(lab.writes.reversed()) { write in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "0x%02X ← %@", write.attribute, write.payloadHex))
                            .font(.system(.caption, design: .monospaced))
                        Text(outcomeText(write.outcome))
                            .font(.caption2)
                            .foregroundStyle(outcomeColor(write.outcome))
                        if let previous = write.previousHex,
                           let bytes = PaxLab.bytes(fromHex: previous) {
                            Button("Put back \(previous)") {
                                viewModel.labWrite(attribute: write.attribute, payload: bytes)
                            }
                            .font(.caption2)
                            .disabled(!connected)
                        }
                    }
                }
                Button("Clear the write log", role: .destructive) { lab.clearWrites() }
            } header: {
                Text("Write log")
            } footer: {
                Text("Kept across launches, so a write that took the device down is still here when you come back.")
            }
        }
    }

    private func outcomeText(_ outcome: PaxLab.WriteRecord.Outcome) -> String {
        switch outcome {
        case .pending:       return "waiting to see what happens"
        case .survived:      return "device still connected five seconds later"
        case .deviceDropped: return "device dropped the link after this"
        case .reportedBack:  return "device reported the value back — it took"
        }
    }

    private func outcomeColor(_ outcome: PaxLab.WriteRecord.Outcome) -> Color {
        switch outcome {
        case .pending:       return .secondary
        case .survived:      return .secondary
        case .deviceDropped: return .red
        case .reportedBack:  return .green
        }
    }

    // MARK: - Report

    private var reportSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = report()
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy the whole report", systemImage: "doc.on.doc")
            }
            // The text is built when the screen appears and after anything that
            // changes it, never inside the body: `ShareLink` wants a value, and
            // producing one here meant touching published state mid-render.
            ShareLink(item: shareText) {
                Label("Share the report", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("Everything the device answered, the snapshot differences and every write, as text.")
        }
    }

    private func report() -> String {
        lab.report(deviceSummary: viewModel.labDeviceSummary)
    }
}
#endif
