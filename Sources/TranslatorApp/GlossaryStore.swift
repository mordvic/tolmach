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
    /// The file on disk is no longer the one `load()` read. This app is `LSUIElement` and
    /// stays resident for days, and `glossary.json` is meant to be hand-edited and
    /// git-tracked (spec 9) — so "the user changed the file while the app was running" is
    /// the documented workflow, not an exotic race. Writing the launch-time snapshot then
    /// takes the *whole* file with it, `entries` included, to persist one muted term.
    /// Separate from `saveBeforeLoad` because the user has to be told something different:
    /// their file is fine, this process's copy is the stale one.
    case fileChangedOnDisk
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
    /// What the file looked like the last time this store read or wrote it. `nil` means
    /// "there was no file then", which is a stamp in its own right and not a missing one:
    /// a file that exists now did not exist at load, so it is somebody else's.
    private var stamp: FileStamp?

    /// Compared, never interpreted — any difference at all means the file is not the one
    /// we hold in memory.
    ///
    /// Size rides along with the date because both come out of a single `attributesOfItem`
    /// call, so it is free, and it makes the check survive a coarse timestamp: everything
    /// this app writes lands in Application Support on APFS, whose modification dates are
    /// nanosecond-granular, but a glossary kept on an HFS+ or SMB volume gets one-second
    /// dates, and a hand-edit in the same second as launch would otherwise slip through.
    private struct FileStamp: Equatable {
        var modified: Date
        var size: Int
    }

    /// `nil` for "no file" *and* for "attributes unreadable". Both collapse to the same
    /// meaning for the caller — no evidence about this file — and both fail safe: at load
    /// the store ends up with no stamp, so the first save sees a file it cannot account
    /// for and refuses.
    private static func fileStamp(of url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileStamp(modified: modified, size: size)
    }

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
            file = GlossaryFile(); stamp = nil; isLoaded = true; return
        }
        // Stamped *before* the read, not after. Stamping after would record the state the
        // file reached at the end of the read, so an edit landing between the two would be
        // attributed to us and silently overwritten later. Stamping first can only err the
        // other way — the same edit makes the stamp look stale and a later save refuses,
        // which costs the user a relaunch instead of their file.
        stamp = Self.fileStamp(of: url)
        let data = try Data(contentsOf: url)
        file = try JSONDecoder().decode(GlossaryFile.self, from: data)
        isLoaded = true
    }

    func save() throws {
        // Both guards go before anything touches the filesystem. A guard placed after the
        // write would still have destroyed the file it exists to protect.
        guard isLoaded else { throw GlossaryStoreError.saveBeforeLoad }
        // Deletion counts as a change too, and deliberately: a user who removed the file to
        // start over would otherwise get this process's launch-time copy written straight
        // back, undoing the reset without a word.
        guard Self.fileStamp(of: url) == stamp else { throw GlossaryStoreError.fileChangedOnDisk }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // The file is hand-editable and git-tracked (spec 9), so key order must be stable
        // or every save produces a spurious diff.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
        // Our own write moved the file on. Without this the second save of a session would
        // report the store's own previous save as an edit behind its back.
        stamp = Self.fileStamp(of: url)
    }

    func mute(_ term: String) {
        let normalized = term.lowercased()
        guard !file.mutedTerms.contains(where: { $0.lowercased() == normalized }) else { return }
        file.mutedTerms.append(normalized)
    }

    var glossary: Glossary { Glossary(entries: file.entries) }
    var mutedSet: Set<String> { Set(file.mutedTerms) }
}
