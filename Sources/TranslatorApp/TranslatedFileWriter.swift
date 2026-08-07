// Sources/TranslatorApp/TranslatedFileWriter.swift
import Foundation
import TranslationCore

/// Putting a finished translation on disk.
///
/// **Whether this is allowed is not knowable from a test.** The app is not sandboxed —
/// `Scripts/make-app-bundle.sh` signs and does nothing else — but that removes only one of
/// the two barriers. On macOS 14 a non-sandboxed app still meets TCC for `~/Documents`,
/// `~/Desktop` and `~/Downloads`, and a drag grants the right to *read* what was dragged,
/// not to place a sibling beside it. Whether the first write prompts, succeeds, or fails
/// is an open probe — see the spec's §9.1 and `docs/OPEN-ITEMS.md`.
///
/// So this returns a problem instead of throwing, and the caller's recovery is a save
/// panel rather than a message: `NSSavePanel` confers the write right itself, which makes
/// it an actual way out of a refusal rather than an apology for one.
enum TranslatedFileWriter {
    /// Name it and write it, in one call.
    ///
    /// The two are inseparable on purpose. A caller that named the file, wrote it, and
    /// then asked `OutputNaming` again for its «показать в Finder» link would be asking
    /// *after* the write — the name is taken now, by that very write — and would be told
    /// the next number. Only whoever wrote the bytes knows where they went, so only this
    /// function answers.
    static func write(_ text: String, beside source: URL, target: Language) -> SaveOutcome {
        let destination = OutputNaming.destination(
            for: source, target: target,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            // `.withoutOverwriting` and not a plain write: `OutputNaming` checks for a
            // free name and this writes, and another process can create the file in
            // between. Losing that race must cost a numbered name, not a document.
            try Data(text.utf8).write(to: destination, options: [.withoutOverwriting])
            return .saved(destination)
        } catch {
            // The error's own `localizedDescription` is English and names
            // NSCocoaErrorDomain; neither belongs on a Russian screen. The description is
            // logged for diagnosis — `.public`, deliberately, because `<private>` in
            // `log show` would make the entry useless for the diagnosis it exists for —
            // and the sentence says what to do instead. The path is **not** logged: a
            // file name is user data.
            Log.files.error("could not write a translation: \(error.localizedDescription, privacy: .public)")
            return .refused("Не удалось сохранить перевод рядом с исходником. "
                + "Воспользуйтесь кнопкой «Сохранить как…» — это заодно выдаст приложению право на запись.")
        }
    }
}
