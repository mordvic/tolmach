// Sources/TranslatorApp/GlossaryStore.swift
import Foundation
import Observation
import TranslationCore

struct GlossaryFile: Codable, Equatable {
    var entries: [GlossaryEntry] = []
    var mutedTerms: [String] = []
}

@Observable
final class GlossaryStore {
    let url: URL
    var file = GlossaryFile()

    init(url: URL = GlossaryStore.defaultURL) { self.url = url }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalTranslator", isDirectory: true)
            .appendingPathComponent("glossary.json")
    }

    /// A missing file is a first launch, not a failure. A malformed one IS a failure and
    /// must propagate: silently starting from empty would present the user with a blank
    /// glossary and then overwrite their file on the next save.
    func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { file = GlossaryFile(); return }
        let data = try Data(contentsOf: url)
        file = try JSONDecoder().decode(GlossaryFile.self, from: data)
    }

    func save() throws {
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
