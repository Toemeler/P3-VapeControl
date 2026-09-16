import SwiftUI

/// How fast the link to the PAX is actually running, measured rather than
/// assumed.
///
/// This screen used to also host a battery decode: a sweep of all 63 attribute
/// addresses looking for a cell voltage finer than the quarters the device
/// reports. It ran, it worked, and it answered the question — there is no
/// voltage, and `SupportedAttributes` proves there is nothing undocumented
/// either. The findings are in `protocol-notes.md`. A tool whose question is
/// permanently answered does not belong in a shipping app, so the decode is
/// gone and what remains is the part that measures something still changing.
struct LinkSpeedView: View {
    @ObservedObject private var benchmark = LinkBenchmark.shared
    @EnvironmentObject private var viewModel: PaxDeviceViewModel
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                let link = BluetoothManager.linkStats.snapshot
                if link.isMeaningful {
                    LabeledContent("Readings a second",
                                   value: String(format: "%.1f", link.repliesPerSecond))
                    LabeledContent("Typical gap",
                                   value: String(format: "%.0f ms", link.medianGapMs))
                    LabeledContent("Best gap",
                                   value: String(format: "%.0f ms", link.fastestGapMs))
                    LabeledContent("Notify to bytes",
                                   value: String(format: "%.0f ms", link.medianTurnaroundMs))
                    LabeledContent("Asking", value: viewModel.fastLaneDescription)
                } else {
                    Text("Not enough traffic yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Right now")
            } footer: {
                Text("Every attribute costs a notification and then a read, so the gap between replies is what decides how fast the dial can move — and the poll runs at whatever that turns out to be rather than at a rate written into the app. Read the rate next to what it says under Asking: while the oven is working there are two requests in the air at once, and while it is idle there is deliberately one, so a round-trip-shaped number here is the loop behaving rather than failing. A benchmark run also fills this window with its own one-at-a-time traffic for two minutes afterwards.")
            }

            Section {
                if benchmark.running {
                    HStack {
                        ProgressView()
                        Text(benchmark.progress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .destructive) { benchmark.stop() }
                } else {
                    Button("Measure the fastest possible timing") { benchmark.start() }
                        .disabled(!viewModel.canSendCommands)
                }
                if let result = benchmark.result {
                    LabeledContent("Round trip",
                                   value: String(format: "%.0f ms · %.1f/s",
                                                 result.roundTripMedianMs,
                                                 1000 / max(1, result.roundTripMedianMs)))
                    LabeledContent("In a burst",
                                   value: String(format: "%.0f ms · %.1f/s",
                                                 result.burstMedianGapMs,
                                                 1000 / max(1, result.burstMedianGapMs)))
                    Text(result.recommendation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ShareLink(item: benchmark.report) {
                        Label("Share the benchmark", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("How fast can it go")
            } footer: {
                Text("Two ways of asking, timed against each other. One attribute at a time measures a round trip, which is what the app's fast lane does. Eight at once measures whether the device streams replies back to back. Reads only, about a minute.")
            }
        }
        .navigationTitle("Link speed")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
    }
}
