// Sources/TranslationCore/DocumentGlossary.swift
import Foundation

public enum DocumentGlossary {
    public static func parse(_ raw: String, knownTerms: [String], target: Language) -> [GlossaryEntry] {
        // Canonical spelling comes from knownTerms, so the model's echo may differ in case.
        let canonical = Dictionary(knownTerms.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [GlossaryEntry] = []

        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let translated = parts[1].trimmingCharacters(in: .whitespaces)
            guard let term = canonical[key], !translated.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(GlossaryEntry(term: term, translations: [target.rawValue: translated]))
        }
        return out
    }
}

public enum GlossaryMerge {
    /// The user's entries first, then the document's that do not collide with them (compared
    /// case-insensitively; a collision keeps the user's). This is the *precedence* order, and
    /// it is what `GlossaryVerifier` — and through it the warnings list — follows.
    public static func merge(user: [GlossaryEntry], document: [GlossaryEntry]) -> [GlossaryEntry] {
        user + documentOnly(user: user, document: document)
    }

    /// The same set, document entries first — the order the per-часть system prompt wants,
    /// and nothing else reads. The document glossary is identical for every часть of a run
    /// (ADR 0001: injected whole, never filtered), while the user's entries are filtered by
    /// occurrence and so differ from часть to часть; Ollama reuses its KV cache by common
    /// prefix across requests while the model stays resident, so the block that never
    /// changes should precede the one that does. Measured 2026-08-18, two consecutive
    /// часть requests with twenty identical document terms and two differing user terms,
    /// prefill of the second, 3/3 each: aya-expanse:8b 379 ms user-first → 101 ms
    /// document-first; translategemma:12b 672 → 672 ms — no gain, because on that model
    /// the cache is all-or-nothing (a request whose system prompt matches but whose text
    /// differs re-prefills in full, 474 ms against 477 cold; only a byte-identical prompt
    /// hits it, 90 ms — `docs/reference/PLATFORM-TRAPS.md`, «Prefill is a real cost above
    /// 8b»). So this is worth ~280 ms per часть after the first on the pinned interactive
    /// model, and nothing on TranslateGemma. No semantic change: the set is the same,
    /// collisions are already resolved, so no term appears twice with two renderings.
    /// Byte-identical to `merge` when the user glossary is empty — which is why the
    /// acceptance harness (`userGlossary: nil`) cannot see this change and was not re-run
    /// for it; the offline tests pin the order instead.
    public static func forPrompt(user: [GlossaryEntry], document: [GlossaryEntry]) -> [GlossaryEntry] {
        documentOnly(user: user, document: document) + user
    }

    private static func documentOnly(user: [GlossaryEntry], document: [GlossaryEntry]) -> [GlossaryEntry] {
        let userTerms = Set(user.map { $0.term.lowercased() })
        return document.filter { !userTerms.contains($0.term.lowercased()) }
    }
}
