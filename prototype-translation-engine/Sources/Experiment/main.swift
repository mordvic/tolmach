import Foundation
import NaturalLanguage
import OllamaClient
import TranslationEngine

// PROTOTYPE — throwaway.
//
// Question 1: does a document glossary fix cross-chunk terminology drift, and are
//             the terms it forces actually correct?
// Question 2: does a corrector-framed second pass (minimum edits, length guard)
//             earn its cost, where the earlier editor-framed one did not?
//
// Arm A = plain per-chunk translation (what we ship if the glossary fails)
// Arm B = same, with the document glossary injected into every chunk

let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
let green = "\u{1B}[32m", red = "\u{1B}[31m", yellow = "\u{1B}[33m", cyan = "\u{1B}[36m"

func header(_ text: String) {
    print("\n\(bold)\(cyan)\(text)\(reset)")
    print(String(repeating: "─", count: 72))
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

print("\(bold)DOCUMENT GLOSSARY + CORRECTOR EXPERIMENT\(reset)")
print("\(dim)model \(model) · EN → \(target.flag) · chunk \(chunkSize) → \(chunks.count) chunks · terms capped at \(termCap)\(reset)")

// ── Step 1: extract repeated terms ────────────────────────────────────────────
header("1. EXTRACTED TERMS")
let terms = Terms.extract(from: article, language: .english, cap: termCap, minFrequency: 2)
print(terms.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
guard !terms.isEmpty else {
    print("\(red)no repeated terms found — experiment cannot proceed\(reset)")
    exit(1)
}

// ── Step 2: translate the term list ───────────────────────────────────────────
header("2. DOCUMENT GLOSSARY  \(dim)(human check: are these translations correct?)\(reset)")
let glossaryStart = Date()
let rawGlossary = try await LLM.complete(DocGlossary.messages(terms: terms, target: target), model: model, client: client)
let glossary = DocGlossary.parse(rawGlossary, knownTerms: terms)
let glossaryMS = Date().timeIntervalSince(glossaryStart) * 1000

for term in glossary {
    print("  \(term.source)  \(dim)=>\(reset)  \(bold)\(term.translated)\(reset)")
}
let dropped = terms.count - glossary.count
print("\n  \(dim)parsed \(glossary.count)/\(terms.count) terms" + (dropped > 0 ? ", \(dropped) unparseable (dropped, not misaligned)" : "") + " · \(Int(glossaryMS)) ms\(reset)")

// ── Step 3: two arms ──────────────────────────────────────────────────────────
func translate(withGlossary: Bool) async throws -> ([String], Double) {
    let started = Date()
    var out: [String] = []
    let entries = withGlossary
        ? glossary.map { GlossaryEntry(term: $0.source, translations: [target.rawValue: $0.translated]) }
        : []
    for chunk in chunks {
        // Every document term goes into every chunk — no occurrence filtering.
        let request = TranslationRequest(text: chunk.text, source: .en, target: target, tone: tone,
                                         glossaryEntries: entries, precedingContext: nil)
        let raw = try await LLM.complete(PromptBuilder.messages(for: request), model: model, client: client)
        out.append(ResponseCleaner.clean(raw).text)
    }
    return (out, Date().timeIntervalSince(started) * 1000)
}

header("3. TRANSLATING")
print("  arm A \(dim)(no glossary)\(reset)…")
let (armA, armAMS) = try await translate(withGlossary: false)
print("  arm B \(dim)(document glossary)\(reset)…")
let (armB, armBMS) = try await translate(withGlossary: true)
print("  \(dim)A: \(Int(armAMS)) ms · B: \(Int(armBMS)) ms\(reset)")

// ── Step 4: adherence ─────────────────────────────────────────────────────────
header("4. CONSISTENCY  \(dim)(does each term render the same way in every chunk it appears in?)\(reset)")

let (scoreA, detailA) = Measure.adherence(sourceChunks: sourceChunks, translatedChunks: armA,
                                          glossary: glossary, source: .english, target: .russian)
let (scoreB, detailB) = Measure.adherence(sourceChunks: sourceChunks, translatedChunks: armB,
                                          glossary: glossary, source: .english, target: .russian)

func bar(_ score: Adherence) -> String {
    let colour = score.percent >= 80 ? green : (score.percent >= 50 ? yellow : red)
    return "\(colour)\(String(format: "%5.1f%%", score.percent))\(reset) \(dim)(\(score.honoured)/\(score.applicable))\(reset)"
}
print("  arm A, no glossary        \(bar(scoreA))")
print("  arm B, document glossary  \(bar(scoreB))")
let delta = scoreB.percent - scoreA.percent
print("\n  \(bold)delta: \(delta >= 0 ? "+" : "")\(String(format: "%.1f", delta)) points\(reset)")

// Per-term detail for terms that appear in more than one chunk — that is where drift lives.
header("5. PER-TERM DETAIL  \(dim)(only terms spanning 2+ chunks; ✓ = agreed translation present)\(reset)")
print("  \(dim)term".padding(toLength: 40, withPad: " ", startingAt: 0) + "arm A      arm B\(reset)")
for term in glossary {
    guard let a = detailA[term.source], a.count >= 2 else { continue }
    let b = detailB[term.source] ?? []
    func render(_ flags: [Bool]) -> String {
        flags.map { $0 ? "\(green)✓\(reset)" : "\(red)✗\(reset)" }.joined()
    }
    // Pad on VISIBLE width — render() carries ANSI escapes that must not be counted.
    let label = "  \(term.source)".padding(toLength: 40, withPad: " ", startingAt: 0)
    let gap = String(repeating: " ", count: max(2, 12 - a.count))
    print(label + render(a) + gap + render(b))
}

// ── Step 6: corrector ─────────────────────────────────────────────────────────
header("6. CORRECTOR PASS  \(dim)(minimum-edit prompt + 15% length guard, over arm B)\(reset)")
let pass1 = armB.joined(separator: "\n\n")
let correctorRequest = TranslationRequest(
    text: article, source: .en, target: target, tone: tone,
    glossaryEntries: glossary.map { GlossaryEntry(term: $0.source, translations: [target.rawValue: $0.translated]) },
    precedingContext: nil)

let correctorSystem = """
You are a translation corrector, not an editor. You are given a source text and its \
translation into \(target.englishName). Fix only outright errors: mistranslations, wrong \
grammar, dropped content, broken markup, terminology inconsistencies.

Rules:
- Output ONLY the corrected translation. No commentary.
- Make the MINIMUM changes needed. Do NOT paraphrase, shorten, merge sentences, or restructure.
- If a sentence is already correct, reproduce it unchanged.
- Preserve every paragraph break exactly as in the translation you are given.
"""
let correctorMessages = [
    ChatMessage(role: "system", content: correctorSystem),
    ChatMessage(role: "user", content: "<source>\n\(article)\n</source>\n\n<translation>\n\(pass1)\n</translation>"),
]
_ = correctorRequest

let correctorStart = Date()
let rawPass2 = try await LLM.complete(correctorMessages, model: model, client: client)
let pass2 = ResponseCleaner.clean(rawPass2).text
let correctorMS = Date().timeIntervalSince(correctorStart) * 1000

let lengthDelta = abs(Double(pass2.count) - Double(pass1.count)) / Double(pass1.count)
let accepted = lengthDelta <= 0.15
print("  pass 1: \(pass1.count) chars \(dim)(\(Int(armBMS)) ms)\(reset)")
print("  pass 2: \(pass2.count) chars \(dim)(+\(Int(correctorMS)) ms)\(reset)")
print("  length delta: \(String(format: "%.1f%%", lengthDelta * 100)) → " +
      (accepted ? "\(green)ACCEPTED\(reset)" : "\(red)REJECTED by guard\(reset)"))
print("  total cost of second pass: \(String(format: "%.2f×", (armBMS + correctorMS) / armBMS))")

// Paragraph-count check: the earlier editor prompt collapsed content.
let paras1 = pass1.components(separatedBy: "\n\n")
let paras2 = pass2.components(separatedBy: "\n\n")
print("  paragraphs: \(paras1.count) → \(paras2.count)" +
      (paras1.count == paras2.count ? " \(green)✓\(reset)" : " \(red)✗ structure changed\(reset)"))

// What did the corrector actually change? A pass that costs 2× and edits nothing
// is as much a failure as one that rewrites everything.
func words(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
}
var changedParagraphs = 0
var edits: [(String, String)] = []
for index in 0..<min(paras1.count, paras2.count) where paras1[index] != paras2[index] {
    changedParagraphs += 1
    let before = Set(words(paras1[index])), after = Set(words(paras2[index]))
    let removed = before.subtracting(after).sorted().prefix(6)
    let added = after.subtracting(before).sorted().prefix(6)
    edits.append((removed.joined(separator: " "), added.joined(separator: " ")))
}
print("  paragraphs edited: \(changedParagraphs)/\(paras1.count)" +
      (changedParagraphs == 0 ? "  \(yellow)corrector changed nothing\(reset)" : ""))
for (removed, added) in edits {
    print("    \(red)− \(removed)\(reset)")
    print("    \(green)+ \(added)\(reset)")
}

// ── Compact summary, for comparing across runs ────────────────────────────────
header("SUMMARY")
print("  adherence      A \(String(format: "%.1f%%", scoreA.percent))  →  B \(String(format: "%.1f%%", scoreB.percent))   delta \(delta >= 0 ? "+" : "")\(String(format: "%.1f", delta))")
print("  glossary       \(glossary.count)/\(terms.count) terms parsed, \(Int(glossaryMS)) ms")
print("  corrector      \(changedParagraphs)/\(paras1.count) paragraphs edited, \(String(format: "%.2f×", (armBMS + correctorMS) / armBMS)) cost, guard \(accepted ? "accepted" : "rejected")")

// ── Output for human reading ──────────────────────────────────────────────────
header("7. ARM A  \(dim)(no glossary)\(reset)")
print(armA.joined(separator: "\n\n"))
header("8. ARM B  \(dim)(document glossary)\(reset)")
print(pass1)
header("9. AFTER CORRECTOR")
print(pass2)
