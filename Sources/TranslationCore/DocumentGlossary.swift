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
    public static func merge(user: [GlossaryEntry], document: [GlossaryEntry]) -> [GlossaryEntry] {
        let userTerms = Set(user.map { $0.term.lowercased() })
        return user + document.filter { !userTerms.contains($0.term.lowercased()) }
    }
}
