import Combine
import Foundation
import SwiftUI

enum ThemeImportError: LocalizedError {
    case unreadable
    case notJSON
    case malformed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That file could not be opened."
        case .notJSON:
            return "That does not look like a theme. A theme is a JSON file."
        case .malformed(let detail):
            return "That theme could not be read: \(detail)"
        case .empty:
            return "That file was empty."
        }
    }
}

/// Which theme is in use, plus whatever themes have been imported.
///
/// Imported themes live as individual JSON files in Application Support, one
/// per theme, so they can be added and removed without rewriting a blob and so
/// a broken one can be deleted by hand.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    private enum Key {
        static let selected = "selectedThemeID"
    }

    /// The theme the screen is drawn with. Falls back to `classic` if the
    /// selected one has been deleted since.
    @Published var selectedID: String {
        didSet { defaults.set(selectedID, forKey: Key.selected) }
    }

    @Published private(set) var imported: [AppTheme] = []

    /// Set when an import fails, so the picker can say why.
    @Published var lastImportError: String?

    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedID = defaults.string(forKey: Key.selected) ?? ThemeCatalog.defaultThemeID
        imported = loadImported()
    }

    // MARK: - Reading

    var builtIn: [AppTheme] { ThemeCatalog.all }

    var all: [AppTheme] { ThemeCatalog.all + imported }

    var active: AppTheme {
        all.first { $0.id == selectedID } ?? ThemeCatalog.classic
    }

    func isImported(_ theme: AppTheme) -> Bool {
        imported.contains { $0.id == theme.id }
    }

    /// The active theme resolved for an appearance. `ledAccent` is threaded in
    /// rather than read here so this type stays independent of AppSettings —
    /// only themes that ask for it get the LED colour.
    func tokens(scheme: ColorScheme, ledAccent: Color?) -> ThemeTokens {
        let theme = active
        return ThemeTokens(theme: theme,
                           scheme: scheme,
                           accentOverride: theme.followsLed ? ledAccent : nil)
    }

    // MARK: - Selecting

    func select(_ theme: AppTheme) {
        guard selectedID != theme.id else { return }
        selectedID = theme.id
    }

    // MARK: - Importing

    /// Reads a theme from a file the user picked. Security-scoped because the
    /// document picker hands back a URL the app has no standing access to.
    func importTheme(from url: URL) throws -> AppTheme {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ThemeImportError.unreadable }
        return try importTheme(data: data, suggestedID: url.deletingPathExtension().lastPathComponent)
    }

    func importTheme(json: String) throws -> AppTheme {
        guard let data = json.data(using: .utf8) else { throw ThemeImportError.notJSON }
        return try importTheme(data: data, suggestedID: nil)
    }

    func importTheme(data: Data, suggestedID: String?) throws -> AppTheme {
        guard !data.isEmpty else { throw ThemeImportError.empty }
        let filled = try Self.fillIdentity(in: data, suggestedID: suggestedID)
        let theme: AppTheme
        do {
            theme = try JSONDecoder().decode(AppTheme.self, from: filled)
        } catch let error as DecodingError {
            throw ThemeImportError.malformed(Self.describe(error))
        } catch {
            throw ThemeImportError.notJSON
        }
        let stored = try save(theme)
        if let index = imported.firstIndex(where: { $0.id == stored.id }) {
            imported[index] = stored
        } else {
            imported.append(stored)
        }
        return stored
    }

    /// A theme file is allowed to omit its own name and id — a hand-written one
    /// usually does. The filename fills in for both rather than the import
    /// failing on bookkeeping.
    private static func fillIdentity(in data: Data, suggestedID: String?) throws -> Data {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              var object = raw as? [String: Any] else {
            throw ThemeImportError.notJSON
        }
        let fallback = (suggestedID?.isEmpty == false ? suggestedID! : "imported-theme")
        if (object["id"] as? String)?.isEmpty ?? true {
            object["id"] = slug(fallback)
        }
        if (object["name"] as? String)?.isEmpty ?? true {
            object["name"] = (object["id"] as? String) ?? fallback
        }
        guard let out = try? JSONSerialization.data(withJSONObject: object) else {
            throw ThemeImportError.notJSON
        }
        return out
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path) is the wrong type"
        case .keyNotFound(let key, _):
            return "\(key.stringValue) is missing"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "unrecognised format"
        }
    }

    static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let joined = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return joined.isEmpty ? "theme" : joined
    }

    // MARK: - Duplicating and deleting

    /// Copies a theme under a new id so it can be edited without touching the
    /// one it came from. This is how you start from a shipped theme.
    func duplicate(_ theme: AppTheme) throws -> AppTheme {
        var copy = theme
        copy.id = uniqueID(basedOn: theme.id)
        copy.name = theme.name + " copy"
        copy.author = nil
        let stored = try save(copy)
        imported.append(stored)
        return stored
    }

    func delete(_ theme: AppTheme) {
        guard isImported(theme) else { return }
        imported.removeAll { $0.id == theme.id }
        try? fileManager.removeItem(at: fileURL(for: theme.id))
        if selectedID == theme.id { selectedID = ThemeCatalog.defaultThemeID }
    }

    private func uniqueID(basedOn base: String) -> String {
        let root = Self.slug(base)
        var candidate = root + "-copy"
        var suffix = 2
        while all.contains(where: { $0.id == candidate }) {
            candidate = "\(root)-copy-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Exporting

    static let fileExtension = "paxtheme.json"

    func json(for theme: AppTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(theme)
    }

    /// Writes a theme to a temporary file so it can be handed to a share sheet.
    func exportURL(for theme: AppTheme) -> URL? {
        guard let data = try? json(for: theme) else { return nil }
        let name = Self.slug(theme.name) + "." + Self.fileExtension
        let url = fileManager.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Storage

    private var directory: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Themes", isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private func fileURL(for id: String) -> URL {
        let folder = directory ?? fileManager.temporaryDirectory
        return folder.appendingPathComponent(Self.slug(id) + ".json")
    }

    /// An imported theme may not take a shipped theme's id, or the picker would
    /// show two rows that cannot be told apart.
    private func save(_ theme: AppTheme) throws -> AppTheme {
        var stored = theme
        stored.id = Self.slug(theme.id)
        if ThemeCatalog.builtIn(stored.id) != nil {
            stored.id = uniqueID(basedOn: stored.id)
        }
        let data = try json(for: stored)
        try data.write(to: fileURL(for: stored.id), options: .atomic)
        return stored
    }

    private func loadImported() -> [AppTheme] {
        guard let directory,
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        let decoder = JSONDecoder()
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name -> AppTheme? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let theme = try? decoder.decode(AppTheme.self, from: data)
                else { return nil }
                return theme
            }
    }
}
