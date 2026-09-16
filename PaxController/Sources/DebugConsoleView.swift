import SwiftUI
import UIKit

struct DebugConsoleView: View {
    @EnvironmentObject var viewModel: PaxDeviceViewModel
    @State private var filter: DebugEntry.Level? = nil
    @State private var autoScroll = true
    @State private var shareText: String? = nil

    private var filteredLog: [DebugEntry] {
        guard let f = filter else { return viewModel.debugLog }
        return viewModel.debugLog.filter { $0.level == f }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                logList
            }
            .navigationTitle("Debug Log")
            .sheet(item: $shareText) { text in
                ShareSheet(items: [text])
                    .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Toggle(isOn: $autoScroll) {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .tint(DS.Palette.accent)
                    .help("Auto-scroll")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button {
                            shareText = viewModel.debugLog
                                .map { "\($0.formattedTime) \($0.level.rawValue) \($0.message)" }
                                .joined(separator: "\n")
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            viewModel.clearLog()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isActive: filter == nil) { filter = nil }
                FilterChip(label: "BLE 📡",   isActive: filter == .ble)   { filter = .ble }
                FilterChip(label: "TX ⬆️",    isActive: filter == .tx)    { filter = .tx }
                FilterChip(label: "RX ⬇️",    isActive: filter == .rx)    { filter = .rx }
                FilterChip(label: "Info ℹ️",  isActive: filter == .info)  { filter = .info }
                FilterChip(label: "Warn ⚠️",  isActive: filter == .warn)  { filter = .warn }
                FilterChip(label: "Error ❌",  isActive: filter == .error) { filter = .error }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredLog) { entry in
                LogRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .listRowSeparator(.hidden)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .font(.system(.caption2, design: .monospaced))
            .onChange(of: viewModel.debugLog.count) { _ in
                if autoScroll, let last = filteredLog.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Log Row

struct LogRow: View {
    let entry: DebugEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.formattedTime)
                .foregroundColor(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(entry.level.rawValue)
                .frame(width: 20)
            Text(entry.message)
                .foregroundColor(rowColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var rowColor: Color {
        switch entry.level {
        case .error:  return .red
        case .warn:   return .orange
        case .tx:     return .blue
        case .rx:     return .green
        case .ble:    return .purple
        case .info:   return .primary
        }
    }
}

// MARK: - Share Sheet

extension String: @retroactive Identifiable {
    public var id: String { self }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? DS.Palette.accent : Color(.tertiarySystemBackground))
                .foregroundColor(isActive ? DS.Palette.onAccent : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
