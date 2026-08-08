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
        // Written to a temporary sibling and moved into place, rather than straight to the
        // destination. Two things have to hold at once and a single `write` cannot give both:
        //
        // - **Never clobber.** `OutputNaming` picks a free name and this writes, and another
        //   process can create the file in between. Losing that race must cost a numbered
        //   name, not a document — `moveItem` refuses an occupied destination, which is what
        //   `aMoveIntoPlaceRefusesToClobberAnExistingFile` pins.
        // - **Never leave half a document.** A plain write killed partway through a 2 MB
        //   translation leaves a truncated file beside the source that looks finished and
        //   that `OutputNaming` will thereafter treat as taken.
        //
        // `[.withoutOverwriting, .atomic]` is the obvious answer and is **not available**:
        // measured — Foundation does not return an error for that pair, it traps with
        // «withoutOverwriting is not supported with atomic», so taking it would have shipped
        // a crash on every save. The temporary is a sibling so the move is a rename on the
        // same volume, and it is removed if anything below fails.
        // A fixed-length name, and deliberately not one built from the destination's.
        //
        // Embedding `lastPathComponent` added 46 bytes to a name that can already be near
        // the 255-byte filesystem limit: a source with a ~100-character Cyrillic name is
        // ~200 bytes, its destination ~211, and the temporary then overflowed — so the write
        // failed with ENAMETOOLONG and the user was told to use «Сохранить как…», a
        // TCC-flavoured answer to a failure the save panel does not fix, for a file a direct
        // write would have saved. A UUID is unique on its own; it needs no help from the
        // name it is standing in for.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".tolmach-\(UUID().uuidString).partial")
        do {
            try Data(text.utf8).write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return .saved(destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // The domain and the code, and **not** `localizedDescription`.
            //
            // That description names the document. Measured: a refused write to a path
            // called `техдок-секретный.ru.md` produces «The folder
            // "техдок-секретный.ru.md" doesn't exist.» — so logging it `.public` puts a
            // user's file name, and often its folder, into the unified log, which any
            // admin on the machine can read and which `sysdiagnose` collects. `Log`'s own
            // rule forbids exactly that, and this line carried a comment claiming it was
            // being obeyed.
            //
            // What remains is `.public` for the reason `Log` gives: `<private>` in
            // `log show` makes an entry useless for the diagnosis it exists for. It is
            // also the half that identifies the *failure* — 513 is «no permission», the
            // TCC refusal this whole fallback exists for — while the half that identified
            // the *user* is gone.
            let nsError = error as NSError
            Log.files.error("could not write a translation: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            return .refused("Не удалось сохранить перевод рядом с исходником. "
                + "Воспользуйтесь кнопкой «Сохранить как…» — это заодно выдаст приложению право на запись.")
        }
    }

    /// Write to a destination the user chose in an `NSSavePanel`.
    ///
    /// **Overwrites, unlike the function above, and that difference is the point.** There
    /// the name was picked by `OutputNaming` and an existing file is somebody else's
    /// document; here the panel has already shown the name, already asked about a
    /// collision, and already got an answer. Refusing at this stage would override a
    /// decision the user has just made — and the panel's own grant is what makes the write
    /// possible in the first place.
    static func write(_ text: String, to destination: URL) -> SaveOutcome {
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
            return .saved(destination)
        } catch {
            // Same reasoning as above: the description names the file the user chose.
            let nsError = error as NSError
            Log.files.error("could not write to a chosen destination: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            return .refused("Не удалось сохранить перевод в выбранное место.")
        }
    }
}
