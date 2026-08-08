// Sources/TranslatorApp/OutputNaming.swift
import Foundation
import TranslationCore

/// What a translated file is called and where it goes.
///
/// A type of its own, and pure, for the same reason as `DroppedDocument`: the rule that
/// **an existing file is never overwritten** has to be provable, and a rule written
/// inside a save routine can only be read. Losing someone's document to a name
/// collision is the one failure in this feature that cannot be undone.
enum OutputNaming {
    /// Where the translation of `source` belongs.
    ///
    /// The target language's code goes in before the extension, so `techdoc-en.md`
    /// becomes `techdoc-en.ru.md` and sorts next to its original in Finder.
    ///
    /// - Parameter exists: whether a URL is already taken. Injected so the naming rule
    ///   is testable without a filesystem; production passes `FileManager`. It is only a
    ///   politeness — the actual write goes to a temporary sibling and is moved into place,
    ///   and `moveItem` refuses an occupied destination, so a file created by another
    ///   process between this check and the move loses the race safely rather than being
    ///   destroyed.
    /// - Parameter draft: whether this is a partial translation.
    ///
    ///   A cancelled задание keeps whatever arrived, and `FileQueueModel.canSaveElsewhere`
    ///   lets the user save it — but **not** under the canonical name, because half a
    ///   document called `techdoc-en.ru.md` is indistinguishable from a whole one. That rule
    ///   was written and then undone by the save panel, which pre-filled exactly that name:
    ///   pressing Return dropped a truncated file over a complete earlier translation.
    static func destination(for source: URL, target: Language, draft: Bool = false,
                            exists: (URL) -> Bool) -> URL {
        let directory = source.deletingLastPathComponent()
        let extensionPart = source.pathExtension
        // `deletingPathExtension` and not a split on ".": «v1.2.notes.md» is one file
        // whose stem contains dots, and splitting on the first would rename it.
        let stem = source.deletingPathExtension().lastPathComponent
        let code = target.rawValue

        let mark = draft ? " — черновик" : ""
        func url(_ suffix: String) -> URL {
            let name = extensionPart.isEmpty ? "\(stem).\(code)\(mark)\(suffix)"
                                             : "\(stem).\(code)\(mark)\(suffix).\(extensionPart)"
            return directory.appendingPathComponent(name)
        }

        let first = url("")
        guard exists(first) else { return first }
        // Starts at 2 because the unnumbered name is the first. An upper bound rather
        // than `while true`: a directory that answers "taken" a thousand times running
        // is a bug or a hostile filesystem, and looping forever there would hang the
        // queue with no way for the user to see why.
        for number in 2...1000 {
            let candidate = url(" \(number)")
            if !exists(candidate) { return candidate }
        }
        return url(" \(UUID().uuidString)")
    }
}
