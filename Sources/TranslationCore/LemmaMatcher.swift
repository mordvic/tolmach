// Sources/TranslationCore/LemmaMatcher.swift
import Foundation
import NaturalLanguage

public enum LemmaMatcher {
    /// One entry per word: its lemma where `NLTagger` produced one, its surface form where it
    /// did not — plus whether any lemma came back at all.
    ///
    /// **That flag is the whole point of this returning a pair.** The fallback on the line
    /// that builds `out` is what makes the array never empty for non-empty input, and it hides
    /// the difference between «this text lemmatises to these words» and «this machine cannot
    /// lemmatise this language, so here are the words unchanged». `matches` needs to tell those
    /// apart; before it could, its own documented `nil` case was unreachable and a machine with
    /// no lemma data for the language reported every inflected term as **missing**.
    ///
    /// Found by CI on its first run, and it is a defect rather than a test artefact: on a
    /// runner without Russian lemma data, «руководства по реализации» failed to match
    /// «руководство по реализации», `Glossary.occurs` failed on the same surface difference,
    /// and `GlossaryVerifier` therefore reported `.missing` — a false «term lost» warning on a
    /// correct translation, which is exactly the crying wolf spec §4.6 forbids.
    static func tagged(_ text: String, language: Language) -> (words: [String], lemmatised: Bool) {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language.nlLanguage, range: text.startIndex..<text.endIndex)
        var out: [String] = []
        var sawLemma = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            let lemma = tag?.rawValue
            let surface = String(text[range])
            if lemma?.isEmpty == false { sawLemma = true }
            out.append((lemma?.isEmpty == false ? lemma! : surface).lowercased())
            return true
        }
        return (out, sawLemma)
    }

    public static func lemmas(of text: String, language: Language) -> [String] {
        tagged(text, language: language).words
    }

    /// The decision, separated from the tagging so that it can be checked without depending on
    /// what the machine running the tests happens to be able to lemmatise.
    ///
    /// That separation is not tidiness: the two tests this defect broke were
    /// `matchesAcrossRussianCase` and `satisfiedWhenExpectedFormPresentAcrossInflection`, both
    /// of which pass on a machine with Russian lemma data and fail on one without — so neither
    /// could ever have pinned the rule itself. This can.
    ///
    /// - Returns: `true` when the expected words occur contiguously; `false` when they
    ///   demonstrably do not; `nil` when this cannot be decided.
    ///
    /// **Both sides carry the flag, and the first version of this fix read only the needle's —
    /// which broke `aCoincidentalSubstringDoesNotForgiveARealViolation`.** A term can legitimately
    /// have no lemma on a perfectly equipped machine: «ID» is an acronym, and `NLTagger` returns
    /// nothing for it whatever data is installed. Reading the needle alone confused that with
    /// «this machine cannot lemmatise», turned a real violation into `.unverifiable`, and
    /// silently switched off the check that test exists to keep.
    ///
    /// The haystack is the witness that separates them. It is running prose, so if the tagger
    /// can lemmatise this language at all, the haystack shows it — and a miss against a
    /// normalised haystack is a real miss even when the needle itself has no lemma of its own.
    /// Only when **neither** side produced a single lemma was the comparison pure surface
    /// forms, and only then is a miss undecidable.
    static func decide(needle: (words: [String], lemmatised: Bool),
                       haystack: (words: [String], lemmatised: Bool)) -> Bool? {
        guard !needle.words.isEmpty else { return nil }
        if haystack.words.count >= needle.words.count {
            for start in 0...(haystack.words.count - needle.words.count)
            where Array(haystack.words[start..<(start + needle.words.count)]) == needle.words {
                return true
            }
        }
        // A *positive* match above stays trustworthy either way: identical words really do
        // occur, however they were produced. It is only the negative that needs the witness.
        return needle.lemmatised || haystack.lemmatised ? false : nil
    }

    /// nil  → cannot verify (no words to look for, or nothing could be lemmatised)
    /// true → expected lemma sequence occurs contiguously in the translation
    /// false→ it does not
    public static func matches(expected: String, in translation: String, language: Language) -> Bool? {
        matches(expected: expected, in: TaggedText(translation, language: language))
    }

    /// The same decision against a haystack that has **already** been tagged.
    ///
    /// `tagged` builds an `NLTagger` and walks the whole text, so asking «does this term
    /// occur» once per glossary entry re-tagged the entire translation once per entry:
    /// O(entries × document), paid after the last token has streamed while the job still reads
    /// `.running`. A 2 MB file with twenty terms took twenty full passes over two megabytes to
    /// answer twenty questions about one text.
    ///
    /// The needle is still tagged per call, and that is right — it is a term, not a document.
    public static func matches(expected: String, in haystack: TaggedText) -> Bool? {
        let needle = tagged(expected, language: haystack.language)
        guard !needle.words.isEmpty else { return nil }
        return decide(needle: needle, haystack: (haystack.words, haystack.lemmatised))
    }
}

/// One text, tagged once, so that many questions can be asked of it without re-reading it.
///
/// A value rather than a cache: nothing has to decide when it is stale, and the caller that
/// knows the text is not going to change is the one that holds it.
public struct TaggedText: Sendable {
    let words: [String]
    let lemmatised: Bool
    let language: Language

    public init(_ text: String, language: Language) {
        let tagged = LemmaMatcher.tagged(text, language: language)
        self.words = tagged.words
        self.lemmatised = tagged.lemmatised
        self.language = language
    }
}
