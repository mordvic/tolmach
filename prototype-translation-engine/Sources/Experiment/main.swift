import Foundation
import NaturalLanguage
import OllamaClient
import TranslationEngine

// PROTOTYPE — throwaway.
//
// Round 1 answered: a document glossary lifts cross-chunk term adherence from ~66% to 88%,
// and the corrector second pass is not worth its 2× cost. Both recorded in the README.
//
// Round 2 asks: translating the term list WITH the sentence each term came from — does it
// fix the one wrong entry we saw (`output => выход`, where the sense needs «вывод»)?
//
// Arm A = no glossary            Arm B = glossary built from bare terms
// Arm C = glossary built from terms plus their context sentence

let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
let green = "\u{1B}[32m", red = "\u{1B}[31m", yellow = "\u{1B}[33m", cyan = "\u{1B}[36m"

func header(_ text: String) {
    print("\n\(bold)\(cyan)\(text)\(reset)")
    print(String(repeating: "─", count: 76))
}

// The article that exposed the drift, verbatim from the prototype's Sample 4.
let article = """
Local language models have quietly crossed a threshold. Two years ago, running a \
capable multilingual model on a laptop meant accepting output that was obviously \
worse than what a cloud service would give you. That gap has narrowed to the point \
where, for many everyday tasks, it is no longer the deciding factor.

The shift has less to do with raw parameter counts than with training data curation. \
A model trained deliberately on balanced multilingual corpora will outperform a much \
larger model that saw English for ninety percent of its tokens. This is why an \
eight-billion-parameter model tuned for twenty-three languages can beat a thirty-billion \
generalist on translation into Portuguese or Turkish, while losing badly to it on \
mathematical reasoning.

Latency tells a similar story. The perceived speed of a local translator is dominated \
not by generation throughput but by whether the model is already resident in memory. \
A model that has been evicted costs several seconds to load from disk before it emits \
a single token, which is precisely the delay that makes a keyboard-shortcut workflow \
feel broken. Keeping the model warm turns the same hardware from unusable into instant.

The remaining honest weakness is consistency across long documents. A model translating \
a fifteen-page specification in pieces has no memory of how it rendered a term on page \
two by the time it reaches page eleven. Cloud services solve this with translation \
memories and enforced glossaries. Local tooling has to do the same work explicitly, \
carrying terminology forward between chunks rather than hoping the model remembers.

None of this makes local translation strictly better. It makes it different, with a \
trade that many people will take: slightly rougher output, in exchange for text that \
never leaves the machine.
"""

let model = "aya-expanse:8b"
let target = Language.ru
let tone = Tone.neutral
let chunkSize = 600
let termCap = 20

let client = OllamaClient()
let chunks = Chunker.chunk(article, maxCharacters: chunkSize)
let sourceChunks = chunks.map(\.text)

print("\(bold)TERM-CONTEXT EXPERIMENT\(reset)")
print("\(dim)model \(model) · EN → \(target.flag) · chunk \(chunkSize) → \(chunks.count) chunks · terms capped at \(termCap)\(reset)")

// ── 1. Extract repeated terms ─────────────────────────────────────────────────
header("1. EXTRACTED TERMS")
let terms = Terms.extract(from: article, language: .english, cap: termCap, minFrequency: 2)
print("  " + terms.joined(separator: ", "))
guard !terms.isEmpty else { print("\(red)no repeated terms\(reset)"); exit(1) }

// ── 2. Two glossaries ─────────────────────────────────────────────────────────
header("2. BUILDING GLOSSARIES")

let bareStart = Date()
let bareRaw = try await LLM.complete(DocGlossary.messages(terms: terms, target: target), model: model, client: client)
let bareGlossary = DocGlossary.parse(bareRaw, knownTerms: terms)
let bareMS = Date().timeIntervalSince(bareStart) * 1000
print("  bare terms      \(bareGlossary.count)/\(terms.count) parsed · \(Int(bareMS)) ms")

let withContext = terms.map { (term: $0, context: Sentences.first(containing: $0, in: article) ?? "") }
let missingContext = withContext.filter(\.context.isEmpty).count
let contextStart = Date()
let contextRaw = try await LLM.complete(DocGlossary.contextMessages(terms: withContext, target: target), model: model, client: client)
let contextGlossary = DocGlossary.parse(contextRaw, knownTerms: terms)
let contextMS = Date().timeIntervalSince(contextStart) * 1000
print("  with context    \(contextGlossary.count)/\(terms.count) parsed · \(Int(contextMS)) ms" +
      (missingContext > 0 ? " \(yellow)(\(missingContext) terms had no sentence)\(reset)" : ""))

// ── 3. Side-by-side, for the human half of the criterion ──────────────────────
header("3. GLOSSARY COMPARISON  \(dim)(differences marked; are the context ones better?)\(reset)")
let bareByTerm = Dictionary(uniqueKeysWithValues: bareGlossary.map { ($0.source.lowercased(), $0.translated) })
let contextByTerm = Dictionary(uniqueKeysWithValues: contextGlossary.map { ($0.source.lowercased(), $0.translated) })
var differing = 0
for term in terms {
    let key = term.lowercased()
    let bare = bareByTerm[key] ?? "\(dim)—\(reset)"
    let ctx = contextByTerm[key] ?? "\(dim)—\(reset)"
    let same = bareByTerm[key] == contextByTerm[key]
    if !same { differing += 1 }
    let marker = same ? "\(dim)  \(reset)" : "\(yellow)≠ \(reset)"
    let label = term.padding(toLength: 22, withPad: " ", startingAt: 0)
    let bareCol = bare.padding(toLength: 26, withPad: " ", startingAt: 0)
    print("  \(marker)\(label)\(bareCol)\(bold)\(ctx)\(reset)")
}
print("\n  \(dim)\(differing) of \(terms.count) terms differ between the two glossaries\(reset)")

// ── 4. Three arms ─────────────────────────────────────────────────────────────
func translate(using glossary: [DocTerm]) async throws -> ([String], Double) {
    let started = Date()
    let entries = glossary.map { GlossaryEntry(term: $0.source, translations: [target.rawValue: $0.translated]) }
    var out: [String] = []
    for chunk in chunks {
        // Every document term goes into every chunk — no occurrence filtering.
        let request = TranslationRequest(text: chunk.text, source: .en, target: target, tone: tone,
                                         glossaryEntries: entries, precedingContext: nil)
        let raw = try await LLM.complete(PromptBuilder.messages(for: request), model: model, client: client)
        out.append(ResponseCleaner.clean(raw).text)
    }
    return (out, Date().timeIntervalSince(started) * 1000)
}

header("4. TRANSLATING")
print("  arm A \(dim)no glossary\(reset)…")
let (armA, armAMS) = try await translate(using: [])
print("  arm B \(dim)bare-term glossary\(reset)…")
let (armB, armBMS) = try await translate(using: bareGlossary)
print("  arm C \(dim)context glossary\(reset)…")
let (armC, armCMS) = try await translate(using: contextGlossary)
print("  \(dim)A \(Int(armAMS)) ms · B \(Int(armBMS)) ms · C \(Int(armCMS)) ms\(reset)")

// ── 5. Adherence ──────────────────────────────────────────────────────────────
// Each arm is scored against the glossary that steered it; the no-glossary arm is
// scored against both, so each steered arm has its own honest baseline.
header("5. CONSISTENCY")

func score(_ translated: [String], against glossary: [DocTerm]) -> (Adherence, [String: [Bool]]) {
    Measure.adherence(sourceChunks: sourceChunks, translatedChunks: translated,
                      glossary: glossary, source: .english, target: .russian)
}
let (baseBare, _) = score(armA, against: bareGlossary)
let (steerBare, detailB) = score(armB, against: bareGlossary)
let (baseContext, detailABase) = score(armA, against: contextGlossary)
let (steerContext, detailC) = score(armC, against: contextGlossary)

func fmt(_ a: Adherence) -> String {
    let colour = a.percent >= 80 ? green : (a.percent >= 50 ? yellow : red)
    return "\(colour)\(String(format: "%5.1f%%", a.percent))\(reset) \(dim)(\(a.honoured)/\(a.applicable))\(reset)"
}
print("  bare glossary      baseline A \(fmt(baseBare))   steered B \(fmt(steerBare))   " +
      "\(bold)\(String(format: "%+.1f", steerBare.percent - baseBare.percent))\(reset)")
print("  context glossary   baseline A \(fmt(baseContext))   steered C \(fmt(steerContext))   " +
      "\(bold)\(String(format: "%+.1f", steerContext.percent - baseContext.percent))\(reset)")
_ = detailABase

// ── 6. Per-term detail ────────────────────────────────────────────────────────
header("6. PER-TERM  \(dim)(terms spanning 2+ chunks · ✓ agreed translation present)\(reset)")
print("  \(dim)\("term".padding(toLength: 22, withPad: " ", startingAt: 0))arm B          arm C\(reset)")
for term in terms {
    let b = detailB[term] ?? []
    let c = detailC[term] ?? []
    guard max(b.count, c.count) >= 2 else { continue }
    func render(_ flags: [Bool]) -> String {
        flags.map { $0 ? "\(green)✓\(reset)" : "\(red)✗\(reset)" }.joined()
    }
    let gap = String(repeating: " ", count: max(2, 15 - b.count))
    print("  \(term.padding(toLength: 22, withPad: " ", startingAt: 0))\(render(b))\(gap)\(render(c))")
}

// ── 7. Summary ────────────────────────────────────────────────────────────────
header("SUMMARY")
print("  glossaries differ on \(differing)/\(terms.count) terms · context cost +\(Int(contextMS)) ms once per document")
print("  bare      \(String(format: "%.1f%%", baseBare.percent)) → \(String(format: "%.1f%%", steerBare.percent))")
print("  context   \(String(format: "%.1f%%", baseContext.percent)) → \(String(format: "%.1f%%", steerContext.percent))")

header("ARM C OUTPUT  \(dim)(context glossary)\(reset)")
print(armC.joined(separator: "\n\n"))
