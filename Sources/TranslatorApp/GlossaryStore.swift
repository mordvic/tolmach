// Sources/TranslatorApp/GlossaryStore.swift
import Foundation
import Observation
import TranslationCore

struct GlossaryFile: Codable, Equatable {
    var entries: [GlossaryEntry] = []
    var mutedTerms: [String] = []
}

enum GlossaryStoreError: Error, Equatable {
    /// Saving a store that has never read the user's file would write this process's
    /// empty `GlossaryFile` over a hand-authored `glossary.json`. A dedicated case, not
    /// a generic one, so callers can tell "your glossary was never loaded" apart from
    /// "the disk is full" and say something true to the user about each.
    case saveBeforeLoad
}

@Observable
final class GlossaryStore {
    let url: URL
    var file = GlossaryFile()
    /// Gates `save()`. False until `load()` has actually returned successfully — a
    /// failed load leaves it false on purpose, so a malformed file cannot be overwritten
    /// by whatever the user does next.
    private(set) var isLoaded = false
    /// Set when a load or a save failed, for the UI to show. Nil means nothing is wrong.
    var lastProblem: String?

    init(url: URL = GlossaryStore.defaultURL) { self.url = url }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalTranslator", isDirectory: true)
            .appendingPathComponent("glossary.json")
    }

    /// A missing file is a first launch, not a failure. A malformed one IS a failure and
    /// must propagate: silently starting from empty would present the user with a blank
    /// glossary. It can no longer go on to overwrite their file — `isLoaded` stays false
    /// on the throwing path and `save()` refuses — but the caller still has to be told,
    /// or the user is left believing an unread glossary is an empty one.
    func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            file = GlossaryFile(); isLoaded = true; return
        }
        let data = try Data(contentsOf: url)
        file = try JSONDecoder().decode(GlossaryFile.self, from: data)
        isLoaded = true
    }

    func save() throws {
        // Before anything touches the filesystem. A guard placed after the write would
        // still have destroyed the file it exists to protect.
        guard isLoaded else { throw GlossaryStoreError.saveBeforeLoad }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // The file is hand-editable and git-tracked (spec 9), so key order must be stable
        // or every save produces a spurious diff.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    func mute(_ term: String) {
        let normalized = term.lowercased()
        guard !file.mutedTerms.contains(where: { $0.lowercased() == normalized }) else { return }
        file.mutedTerms.append(normalized)
    }

    var glossary: Glossary { Glossary(entries: file.entries) }
    var mutedSet: Set<String> { Set(file.mutedTerms) }
}
