// Sources/TranslatorApp/FileJob.swift
import Foundation
import TranslationCore

/// One file in the queue, and everything the row rendering it needs.
struct FileJob: Identifiable {
    let id = UUID()
    let url: URL
    /// Read when the file was dropped, not when its turn comes.
    ///
    /// A queue can sit for minutes before it reaches a given file, and reading late would
    /// let an edit — or a deletion — between the drop and the turn change a задание the
    /// user believes they queued.
    let text: String
    /// `Chunker.plan`'s count, computed at drop time off the main actor, because the
    /// queued row promises «4 части» before anything has run and planning twenty 2 MB
    /// files is not main-actor work.
    ///
    /// An estimate the run supersedes: `chunkSize` can change between the drop and the
    /// turn, so the *running* row draws from `TranslationProgress.partsTotal`, which the
    /// engine computed for the run actually happening.
    let partsTotal: Int
    /// What the engine actually planned for this задание, kept after it stops running.
    ///
    /// The estimate above and this number can differ — `chunkSize` changes between the
    /// drop and the turn — and without somewhere to keep the real one the queue counter
    /// ran **backwards**: the running row contributed the engine's count while every
    /// finished row contributed its own estimate, so the moment a file finished, the total
    /// it had been counted into shrank. Measured on paper: two files estimated at 4 parts
    /// each and really 12, the bar reads «12 частей из 16» and then «4 частей из 16» one
    /// instant later.
    var actualPartsTotal: Int?
    /// The number to *show* — the engine's if this задание has run, the estimate if not.
    /// One accessor because every reader of the pair must answer the same way, and a counter
    /// built from two spellings of the same rule is exactly what went wrong — twice: the
    /// `statusLine` sums first, and then the run-start seed, which was the one site still
    /// taking the estimate and made the total fall on a retry.
    var parts: Int { actualPartsTotal ?? partsTotal }
    var state: State = .queued
    var result: JobResult?
    /// Set when the translation could not be written. Deliberately separate from `state`:
    /// the задание finished, and saying it failed would be a lie about the translation,
    /// which is in memory and copyable.
    var saveProblem: String?
    /// The user asked for the terms gate and it could not be prepared for this file.
    ///
    /// Per задание and **not** per queue: thirteen files can hit the failure on three of
    /// them, and one flag on `FileQueueModel` would report the last file's luck for all of
    /// them.
    var documentTermsUnavailable = false
    /// The language this задание was actually translated into — the toolbar's override if
    /// there was one, the settings rule otherwise.
    ///
    /// Stored for `TranslationViewModel.resolvedTarget`'s reason: the rule that produced it
    /// is not re-derivable later. «Сохранить как…» suggests a name from it, and a file
    /// translated into German must not be offered as `a.ru.md` because the settings say
    /// Russian.
    var resolvedTarget: Language?

    enum State: Equatable {
        case queued
        case running(TranslationProgress)
        case finished
        /// Cancelled mid-run. Whatever text arrived is kept, matching what the window and
        /// the panel already do with an interrupted run.
        case interrupted
        case failed(String)
        /// Dropped but not readable. Carried as a row rather than dropped on the floor,
        /// so a mixed drop can say *which* file it could not take. Never entered by a
        /// run: the queue skips these, it does not retry them.
        case unreadable
    }

    init(url: URL, text: String, partsTotal: Int) {
        self.url = url
        self.text = text
        self.partsTotal = partsTotal
    }
}

/// What became of a translation on its way to disk.
///
/// An enum of its own rather than `Result<URL, String>`, which does not compile: `Result`
/// requires its failure type to conform to `Error`, and this one is a Russian sentence for
/// a human, not something to be thrown. Making `String: Error` to satisfy a generic would
/// be a conformance on a standard type declared for the convenience of one call site.
///
/// It carries the URL because only the writer knows where the bytes went — recomputing the
/// destination after the write finds the name taken by that very write and answers with
/// the next number.
enum SaveOutcome {
    case saved(URL)
    /// A sentence to show the user, already in Russian. The underlying error is logged,
    /// not shown: an `NSCocoaErrorDomain` description is English and names a domain nobody
    /// outside this process has heard of.
    case refused(String)
}

/// What a finished задание keeps.
///
/// **Not the whole `TranslationOutcome`.** An outcome carries `chunks` and
/// `translatedChunks` on top of `final`, i.e. roughly three copies of the document;
/// retaining that for twenty finished 2 MB файлов is ~120 MB nobody will read. These five
/// values are everything the right pane and `WarningsView` need.
struct JobResult {
    let final: String
    let checks: [GlossaryCheck]
    let markupDiffs: [MarkupDiff]
    /// Kept, unlike `chunks` and `translatedChunks`: this is a list of terms — twelve
    /// entries, not three copies of the document — and `WarningsView` shows it under its
    /// own disclosure.
    let documentGlossary: [GlossaryEntry]
    let elapsedMS: Int
    var savedTo: URL?

    /// `.missing` only, not `.unverifiable`.
    ///
    /// `GlossaryStatus` has three cases and only one of them is a complaint:
    /// `.unverifiable` means `LemmaMatcher` could not decide for that language, which is a
    /// statement about the checker and not about the translation. Counting it would pause
    /// a `stopOnWarnings` queue on every Japanese file for no reason.
    var warningCount: Int {
        checks.filter { $0.status == .missing }.count + markupDiffs.count
    }
    var hasWarnings: Bool { warningCount > 0 }

    /// How many things the disclosure for this задание actually lists.
    ///
    /// One more than `warningCount` when there is a документный глоссарий, because
    /// `WarningsView` gives it a row of its own — and the status bar counts by asking that
    /// view. The two numbers answer different questions and both are needed: this one is
    /// «what is under the chevron», and `warningCount` above is «is something wrong with
    /// this file», which is what `stopOnWarnings` must not pause on for a term list.
    /// Showing `warningCount` in the row while the bar showed this one put two different
    /// counts for one file on screen at once.
    var disclosureCount: Int { warningCount + (documentGlossary.isEmpty ? 0 : 1) }
}
