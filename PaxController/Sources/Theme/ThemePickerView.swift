import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Choosing a theme, and getting themes in and out of the app.
struct ThemePickerView: View {
    @EnvironmentObject var themes: ThemeStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingImporter = false
    @State private var showingPaste = false
    @State private var pasted = ""
    @State private var message: String?
    @State private var shareTheme: AppTheme?

    var body: some View {
        List {
            Section {
                ForEach(themes.builtIn) { theme in
                    row(theme)
                }
            } header: {
                Text("Themes")
            } footer: {
                Text("A theme sets the whole screen: which layout it uses, how the temperature is drawn, and every colour, corner and typeface. Changing one takes effect immediately.")
            }

            if !themes.imported.isEmpty {
                Section("Imported") {
                    ForEach(themes.imported) { theme in
                        row(theme)
                    }
                    .onDelete { offsets in
                        for index in offsets where themes.imported.indices.contains(index) {
                            themes.delete(themes.imported[index])
                        }
                    }
                }
            }

            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import from a file", systemImage: "square.and.arrow.down")
                }
                Button {
                    pasted = UIPasteboard.general.string ?? ""
                    showingPaste = true
                } label: {
                    Label("Paste a theme", systemImage: "doc.on.clipboard")
                }
                Button {
                    duplicateActive()
                } label: {
                    Label("Duplicate “\(themes.active.name)”", systemImage: "plus.square.on.square")
                }
            } header: {
                Text("Add")
            } footer: {
                Text("A theme is a JSON file. Duplicate one to get a copy you can export, edit in any text editor, and import back. Anything it leaves out falls back to the shipped values, so a theme can be three lines long.")
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.hasPrefix("Imported") ? Color.green : Color.red)
                }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.json, .plainText, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                apply { try themes.importTheme(from: url) }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingPaste) { pasteSheet }
        .sheet(item: $shareTheme) { theme in
            ThemeShareSheet(theme: theme)
                .environmentObject(themes)
        }
    }

    // MARK: - Rows

    private func row(_ theme: AppTheme) -> some View {
        let selected = themes.selectedID == theme.id
        return Button {
            themes.select(theme)
        } label: {
            HStack(spacing: 13) {
                ThemeSwatch(theme: theme, scheme: colorScheme)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(theme.name).font(.system(size: 17, weight: .semibold))
                        Text(shapeLabel(theme))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if let summary = theme.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                shareTheme = theme
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
    }

    /// What the theme does to the screen, not just to its colours.
    private func shapeLabel(_ theme: AppTheme) -> String {
        switch theme.shellKind {
        case .stacked:
            switch theme.heroKind {
            case .arc:         return "dial"
            case .linearScale: return "scale"
            case .rule:        return "rule"
            case .card:        return "cards"
            case .column:      return "column"
            case .gauge:       return "gauge"
            case .none:        return "plain"
            }
        case .chart:     return "chart"
        case .field:     return "field"
        case .prose:     return "sentence"
        case .object:    return "object"
        case .countdown: return "clock"
        }
    }

    // MARK: - Paste

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste the contents of a theme file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $pasted)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(16)
            .navigationTitle("Paste a theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        apply { try themes.importTheme(json: pasted) }
                        showingPaste = false
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func duplicateActive() {
        apply { try themes.duplicate(themes.active) }
    }

    /// Runs an import or duplicate, selects what came back, and says what
    /// happened either way rather than failing silently.
    private func apply(_ work: () throws -> AppTheme) {
        do {
            let theme = try work()
            themes.select(theme)
            message = "Imported “\(theme.name)”."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A theme at a glance: its canvas, a plate on it, and where the accent lands.
struct ThemeSwatch: View {
    let theme: AppTheme
    let scheme: ColorScheme

    var body: some View {
        let tokens = ThemeTokens(theme: theme, scheme: scheme)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tokens.canvas)
            .frame(width: 42, height: 52)
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: max(1, tokens.radius / 3), style: .continuous)
                        .fill(tokens.accent)
                        .frame(width: 22, height: 6)
                    RoundedRectangle(cornerRadius: max(1, tokens.radius / 3), style: .continuous)
                        .fill(tokens.plate)
                        .frame(width: 26, height: 5)
                    RoundedRectangle(cornerRadius: max(1, tokens.radius / 3), style: .continuous)
                        .fill(tokens.ink.opacity(0.5))
                        .frame(width: 18, height: 3)
                }
                .padding(.top, 11)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

/// Hands a theme to the share sheet as a file, and shows the JSON so it can be
/// copied straight out.
struct ThemeShareSheet: View {
    @EnvironmentObject var themes: ThemeStore
    @Environment(\.dismiss) private var dismiss
    let theme: AppTheme

    private var text: String {
        guard let data = try? themes.json(for: theme),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .navigationTitle(theme.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        if let url = themes.exportURL(for: theme) {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
    }
}
