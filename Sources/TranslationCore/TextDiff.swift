// Sources/TranslationCore/TextDiff.swift
import Foundation

/// What правка changed, as ranges of tokens rather than as prose.
///
/// `notCompared` is carried the way `TranslationOutcome.markupNotCompared` is, and for the same
/// reason: an empty `changes` means «the model changed nothing», and a surface that read the
/// same array for «this was never looked at» would be lying in the quietest way available to
/// it. Every consumer that renders «изменений нет» has to read this too.
public struct ChangeSet: Sendable, Equatable, Codable {
    public let changes: [TextChange]
    /// One entry per compared block pair, including the pairs that came back identical.
    ///
    /// Not needed to draw anything — it exists so that `densityThreshold` can be measured on
    /// the правка corpus instead of guessed (`Scripts/change-density.sh`, the spec's
    /// measurement protocol item 1). A census with the unchanged blocks left out could not
    /// answer «what share of an «только ошибки» run's blocks stays below the threshold».
    public let blocks: [BlockPair]
    /// Nil when the diff ran.
    public let notCompared: NotComparedReason?

    public var count: Int { changes.count }

    public enum NotComparedReason: Sendable, Equatable, Codable {
        /// The two texts together carry more tokens than the run was allowed to inspect.
        /// `tokens` is that sum, so a surface can say how far over it was.
        case tooLong(tokens: Int)
    }

    public init(changes: [TextChange], blocks: [BlockPair], notCompared: NotComparedReason?) {
        self.changes = changes
        self.blocks = blocks
        self.notCompared = notCompared
    }
}

/// One change: a run of result tokens that replaced a run of source tokens.
public struct TextChange: Sendable, Equatable, Codable {
    public enum Scope: String, Sendable, Equatable, Codable {
        /// A word-level edit inside a block.
        case words
        /// The whole block. Either it changed past `densityThreshold` — a rewritten paragraph
        /// is one change and not a shower of them — or it has no counterpart at all.
        case block
    }

    public let scope: Scope
    /// Index into the RESULT's block list (`MarkdownBlockScanner.blocks(of: final)`).
    ///
    /// For a block that was *removed* — nothing in the result corresponds to it — this is the
    /// index of the result block it sat in front of, which is the result block count when it
    /// sat at the end of the document. The same convention as `insertedTokens` one property
    /// down, one level up.
    public let block: Int
    /// Content-token indices in the result block's plain projection. Empty for a pure removal,
    /// whose `lowerBound` is then the token the removal sits before (== token count at block
    /// end).
    public let insertedTokens: Range<Int>
    /// Plain text of the removed run, "" for a pure insertion. The source's own bytes between
    /// its first and last removed token, so «, пожалуйста,» comes back spaced as it was.
    public let removed: String
    /// Plain text of the inserted run, "" for a pure removal.
    public let inserted: String

    public init(scope: Scope, block: Int, insertedTokens: Range<Int>,
                removed: String, inserted: String) {
        self.scope = scope
        self.block = block
        self.insertedTokens = insertedTokens
        self.removed = removed
        self.inserted = inserted
    }
}

/// One compared pair of blocks, with the numbers `densityThreshold` will be measured from.
public struct BlockPair: Sendable, Equatable, Codable {
    /// nil: the result block has no counterpart (an inserted block).
    public let source: Int?
    /// nil: the source block has no counterpart (a removed block).
    public let result: Int?
    public let sourceTokens: Int
    public let resultTokens: Int
    /// How many tokens the diff attributed to a change — removed plus inserted.
    ///
    /// `sourceTokens + resultTokens` when the pair collapsed without a token-level diff: the
    /// pre-check refused it as too different, or it was over `blockTokenLimit`. Both mean «the
    /// whole block was treated as changed», which is what the ratio then says.
    public let changedTokens: Int
    /// Dice over content-token multisets, 0…1.
    public let similarity: Double

    public init(source: Int?, result: Int?, sourceTokens: Int, resultTokens: Int,
                changedTokens: Int, similarity: Double) {
        self.source = source
        self.result = result
        self.sourceTokens = sourceTokens
        self.resultTokens = resultTokens
        self.changedTokens = changedTokens
        self.similarity = similarity
    }
}

/// The word-level diff between a правка's source and its result. Deterministic, local, and
/// nothing to do with the model — the marks a user is shown are computed from the two texts,
/// which is why правка can have them without waiting for a model that can explain itself.
///
/// Three properties are what the whole design rests on:
///
/// - **It diffs the plain projection, never the Markdown bytes.** Both texts are read with
///   `MarkdownBlockScanner` and each block projected with `MarkdownPlainText.plain(_:in:)` —
///   the same spelling the pane draws. So the count describes words a reader can see, and a
///   dropped `**`, which `WarningsView` already reports as «потеряно: жирное выделение», is
///   not counted a second time here.
/// - **Code is never diffed.** A fenced block goes through the pipeline as
///   `Chunk.passthrough` and the model never sees it, so a change inside one cannot exist and
///   must never be claimed. `.thematicBreak` likewise: it has no words.
/// - **A rewritten block is one change.** Word-level marks over a paragraph the model rebuilt
///   are noise, and «переписать» produces those by design (spec §«Solution», story 5). Two
///   gates catch it: a similarity pre-check before the quadratic diff runs, and a density
///   check after it — the second is not redundant, because a reordered sentence has similarity
///   1 and a dozen edits.
public enum TextDiff {
    /// - Parameters:
    ///   - source: the text as it went to the model.
    ///   - result: the assembled reply (`TranslationOutcome.final`).
    ///   - densityThreshold: below this similarity a block is one change instead of many, and
    ///     above this share of changed tokens a diffed block collapses to one.
    ///     **A start value, not a measurement**: the spec's measurement protocol item 1
    ///     (`Scripts/change-density.sh`, the правка corpus at all three степень) is what
    ///     replaces it, and this comment must then carry the figure.
    ///   - mergeGap: how many unchanged tokens may sit between two changes and still leave
    ///     them one change — what makes «посмотрите, пожалуйста,» one comma pair and not two.
    ///     **A start value**: the spec names no measurement of its own for it, and item 1's
    ///     corpus run is where over-merging would show.
    ///   - blockTokenLimit: past this many tokens on either side a block is compared by
    ///     equality alone, because the diff below is quadratic in the edit distance.
    ///     **A start value**: measurement protocol item 2 (`Scripts/text-diff-cost.swift`,
    ///     the 256 KB `DroppedDocument` ceiling) is what replaces it.
    ///   - inspectionLimit: past this many tokens in the two texts together nothing is
    ///     compared at all and `notCompared` says so. **A start value**, item 2 again.
    public static func changes(source: String, result: String,
                               densityThreshold: Double = 0.5,
                               mergeGap: Int = 1,
                               blockTokenLimit: Int = 4_000,
                               inspectionLimit: Int = 60_000) -> ChangeSet {
        let sourceBlocks = MarkdownBlockScanner.blocks(of: source)
        let resultBlocks = MarkdownBlockScanner.blocks(of: result)
        let sourceProjections = sourceBlocks.map { MarkdownPlainText.plain($0, in: source) }
        let resultProjections = resultBlocks.map { MarkdownPlainText.plain($0, in: result) }

        var prepared: [Prepared] = []
        var inspected = 0
        for pairing in pairings(source: sourceProjections, result: resultProjections) {
            switch pairing {
            case let .both(sourceIndex, resultIndex):
                guard isDiffable(sourceBlocks[sourceIndex]),
                      isDiffable(resultBlocks[resultIndex]) else { continue }
            case let .sourceOnly(index, _):
                guard isDiffable(sourceBlocks[index]) else { continue }
            case let .resultOnly(index):
                guard isDiffable(resultBlocks[index]) else { continue }
            }
            let item = Prepared(pairing: pairing,
                                source: pairing.sourceIndex.map { sourceProjections[$0] } ?? "",
                                result: pairing.resultIndex.map { resultProjections[$0] } ?? "")
            inspected += item.sourceTokens.count + item.resultTokens.count
            prepared.append(item)
        }
        // The bound is over the whole document rather than per block: the cost that has to
        // stay off the settle is the sum of every pair's, and a document of ten thousand
        // small blocks is as expensive as one of ten large ones.
        guard inspected <= inspectionLimit else {
            return ChangeSet(changes: [], blocks: [], notCompared: .tooLong(tokens: inspected))
        }

        var changes: [TextChange] = []
        var pairs: [BlockPair] = []
        for item in prepared {
            let similarity: Double
            let changedTokens: Int
            switch item.pairing {
            case .both:
                let compared = compare(item, densityThreshold: densityThreshold,
                                       mergeGap: mergeGap, blockTokenLimit: blockTokenLimit)
                changes.append(contentsOf: compared.changes)
                similarity = compared.similarity
                changedTokens = compared.changedTokens
            case .sourceOnly, .resultOnly:
                // A block with no counterpart: one change carrying the text that appeared or
                // disappeared. A block whose projection is empty produces no change — there is
                // nothing to show a reader — but is still counted in the census.
                if !item.source.isEmpty || !item.result.isEmpty {
                    changes.append(wholeBlock(item))
                }
                similarity = dice(item.sourceTokens, item.resultTokens)
                changedTokens = item.sourceTokens.count + item.resultTokens.count
            }
            pairs.append(BlockPair(source: item.pairing.sourceIndex,
                                   result: item.pairing.resultIndex,
                                   sourceTokens: item.sourceTokens.count,
                                   resultTokens: item.resultTokens.count,
                                   changedTokens: changedTokens, similarity: similarity))
        }
        return ChangeSet(changes: changes, blocks: pairs, notCompared: nil)
    }

    // MARK: - Pairing blocks

    private enum Pairing {
        case both(source: Int, result: Int)
        /// A source block nothing in the result corresponds to. `before` is the index of the
        /// result block it sat in front of — see `TextChange.block`.
        case sourceOnly(index: Int, before: Int)
        case resultOnly(index: Int)

        var sourceIndex: Int? {
            switch self {
            case let .both(source, _): return source
            case let .sourceOnly(index, _): return index
            case .resultOnly: return nil
            }
        }

        var resultIndex: Int? {
            switch self {
            case let .both(_, result): return result
            case .sourceOnly: return nil
            case let .resultOnly(index): return index
            }
        }

        /// Where a change in this pairing is reported: always an index into the *result's*
        /// block list, which is the document the marks are drawn over. For a removed block
        /// that is the block it sat in front of — see `TextChange.block`.
        var anchor: Int {
            switch self {
            case let .both(_, result): return result
            case let .sourceOnly(_, before): return before
            case let .resultOnly(index): return index
            }
        }
    }

    /// Equal block counts pair by index — правка demands structure preservation and this is the
    /// shipped case, so it costs nothing and cannot be confused by two rewritten paragraphs
    /// that happen to look alike.
    ///
    /// Unequal counts fall back to `difference(from:)` over the projections: the blocks that
    /// came through untouched are the anchors, and between two anchors the changed runs are
    /// paired by index up to the shorter one. A naive index pairing would misalign every block
    /// after an inserted paragraph and report the whole tail as rewritten.
    private static func pairings(source: [String], result: [String]) -> [Pairing] {
        if source.count == result.count {
            return (0..<source.count).map { .both(source: $0, result: $0) }
        }
        let difference = result.difference(from: source)
        var removed = [Bool](repeating: false, count: source.count)
        var inserted = [Bool](repeating: false, count: result.count)
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed[offset] = true
            case let .insert(offset, _, _): inserted[offset] = true
            }
        }
        var pairings: [Pairing] = []
        var i = 0, j = 0
        while i < source.count || j < result.count {
            let runStart = (source: i, result: j)
            while i < source.count, removed[i] { i += 1 }
            while j < result.count, inserted[j] { j += 1 }
            let shared = Swift.min(i - runStart.source, j - runStart.result)
            for k in 0..<shared {
                pairings.append(.both(source: runStart.source + k, result: runStart.result + k))
            }
            for k in (runStart.source + shared)..<i {
                pairings.append(.sourceOnly(index: k, before: j))
            }
            for k in (runStart.result + shared)..<j {
                pairings.append(.resultOnly(index: k))
            }
            // Both are now at an anchor, or both are exhausted: the difference removes and
            // inserts in equal measure everywhere else, so one running out alone cannot happen.
            guard i < source.count, j < result.count else { break }
            pairings.append(.both(source: i, result: j))
            i += 1
            j += 1
        }
        return pairings
    }

    /// The blocks a change may be reported in. A fenced block is `Chunk.passthrough` — the
    /// model never saw its bytes — and a thematic break has no words, so neither can have
    /// changed and neither may be claimed to have. Exhaustive with no `default:`: a new
    /// `MarkdownBlock` case has to be decided here rather than defaulting into the diff.
    private static func isDiffable(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .codeBlock, .thematicBreak: return false
        case .heading, .paragraph, .listItem, .blockquote, .table: return true
        }
    }

    // MARK: - One pair

    private struct Prepared {
        let pairing: Pairing
        let source: String
        let result: String
        let sourceTokens: [TextToken]
        let resultTokens: [TextToken]

        init(pairing: Pairing, source: String, result: String) {
            self.pairing = pairing
            self.source = source
            self.result = result
            self.sourceTokens = TextTokenizer.tokens(of: source)
            self.resultTokens = TextTokenizer.tokens(of: result)
        }
    }

    private static func compare(_ item: Prepared, densityThreshold: Double,
                                mergeGap: Int, blockTokenLimit: Int)
        -> (changes: [TextChange], changedTokens: Int, similarity: Double) {
        let block = item.pairing.anchor
        let s = item.sourceTokens, r = item.resultTokens
        // Computed for every pair, including the ones the two gates below refuse: it is what
        // the density measurement plots, and it is linear where the diff is quadratic.
        let similarity = dice(s, r)
        if item.source == item.result { return ([], 0, similarity) }
        let whole = wholeBlock(item)
        // Equality only past the limit, because `difference(from:)` costs O(n·d) and a
        // thousands-token block that was genuinely rewritten is the worst case for `d`.
        guard s.count <= blockTokenLimit, r.count <= blockTokenLimit else {
            return ([whole], s.count + r.count, similarity)
        }
        guard similarity >= densityThreshold else {
            return ([whole], s.count + r.count, similarity)
        }
        let folded = edits(source: s.map(\.text), result: r.map(\.text), mergeGap: mergeGap)
        let total = s.count + r.count
        // The second gate. A sentence whose words were reordered has similarity 1 and passes
        // the pre-check, and comes out of the diff as a dozen separate marks.
        if total > 0, Double(folded.changedTokens) / Double(total) > densityThreshold {
            return ([whole], folded.changedTokens, similarity)
        }
        let changes = folded.edits.map { edit in
            TextChange(scope: .words, block: block, insertedTokens: edit.result,
                       removed: text(of: edit.source, tokens: s, in: item.source),
                       inserted: text(of: edit.result, tokens: r, in: item.result))
        }
        return (changes, folded.changedTokens, similarity)
    }

    private static func wholeBlock(_ item: Prepared) -> TextChange {
        TextChange(scope: .block, block: item.pairing.anchor,
                   insertedTokens: 0..<item.resultTokens.count,
                   removed: item.source, inserted: item.result)
    }

    /// Dice over the token multisets: `2·|s ∩ r| / (|s| + |r|)`. Order-blind on purpose — it
    /// is the *pre*-check, and its job is to tell «these two blocks are about the same words»
    /// from «this paragraph was rewritten» before anything quadratic runs.
    static func dice(_ s: [TextToken], _ r: [TextToken]) -> Double {
        guard !s.isEmpty || !r.isEmpty else { return 1 }
        var counts: [String: Int] = [:]
        for token in s { counts[token.text, default: 0] += 1 }
        var shared = 0
        for token in r where (counts[token.text] ?? 0) > 0 {
            counts[token.text]! -= 1
            shared += 1
        }
        return 2 * Double(shared) / Double(s.count + r.count)
    }

    private struct Edit {
        var source: Range<Int>
        var result: Range<Int>
    }

    /// Myers through `difference(from:)`, folded into edits and then merged across short gaps.
    ///
    /// `changedTokens` counts what the difference itself removed and inserted, before the
    /// merge — merging swallows unchanged tokens into a span, and counting those would make
    /// the density check a function of `mergeGap`.
    private static func edits(source: [String], result: [String], mergeGap: Int)
        -> (edits: [Edit], changedTokens: Int) {
        let difference = result.difference(from: source)
        var removed = [Bool](repeating: false, count: source.count)
        var inserted = [Bool](repeating: false, count: result.count)
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed[offset] = true
            case let .insert(offset, _, _): inserted[offset] = true
            }
        }
        var folded: [Edit] = []
        var i = 0, j = 0
        while i < source.count || j < result.count {
            let start = (source: i, result: j)
            while i < source.count, removed[i] { i += 1 }
            while j < result.count, inserted[j] { j += 1 }
            if i > start.source || j > start.result {
                folded.append(Edit(source: start.source..<i, result: start.result..<j))
            }
            guard i < source.count, j < result.count else { break }
            i += 1
            j += 1
        }
        var merged: [Edit] = []
        for edit in folded {
            // The gap counted in result tokens only: the tokens between two edits are matched
            // pairs, so the source gap is the same number by construction.
            if var last = merged.last, edit.result.lowerBound - last.result.upperBound <= mergeGap {
                last.source = last.source.lowerBound..<edit.source.upperBound
                last.result = last.result.lowerBound..<edit.result.upperBound
                merged[merged.count - 1] = last
            } else {
                merged.append(edit)
            }
        }
        return (merged, removed.lazy.filter { $0 }.count + inserted.lazy.filter { $0 }.count)
    }

    /// The projection's own bytes from the first token of the run to the last — not the tokens
    /// joined by spaces, which would re-space a quotation the user is about to read.
    private static func text(of range: Range<Int>, tokens: [TextToken], in projection: String)
        -> String {
        guard !range.isEmpty else { return "" }
        return String(projection[tokens[range.lowerBound].range.lowerBound
                                 ..< tokens[range.upperBound - 1].range.upperBound])
    }
}
