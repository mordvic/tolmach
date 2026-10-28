import Foundation

/// A corpus text's sidecar — `<name>.meta.json` beside `<name>.txt`.
///
/// **A sidecar and never a header inside the text**, for the reason
/// `docs/reference/OPEN-ITEMS.md` gives for `docs/proofreading-gate`: the file's bytes are the
/// model's input, so a header would itself be corrected, rewritten or translated.
public struct ItemMeta: Codable, Sendable, Equatable {
    public struct Fact: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// A number, a name, a date, a URL: something that survives as characters, so the
            /// mechanical layer can look for it.
            case literal
            /// Something that survives as *meaning* — «the delay was the supplier's fault». It
            /// goes to the judge's checklist and nowhere else; `MechanicalChecks` never reads it.
            case semantic
        }
        public let id: String
        public let kind: Kind
        /// What the fact is, in words — the judge's checklist line.
        public let note: String
        /// Every spelling that counts as the fact having survived, in any language a reply to
        /// this text can be written in. Empty for a `semantic` fact.
        public let anyOf: [String]

        public init(id: String, kind: Kind, note: String, anyOf: [String]) {
            self.id = id; self.kind = kind; self.note = note; self.anyOf = anyOf
        }
    }

    public struct Trap: Codable, Sendable, Equatable {
        /// Free-form on purpose — `question`, `instruction`, `unit` — it is a note to the judge
        /// about what this text was written to catch, not a switch the code reads.
        public let kind: String
        public let text: String
        public init(kind: String, text: String) { self.kind = kind; self.text = text }
    }

    public let genre: String
    /// A `Language` raw value. A string rather than the enum so that a sidecar naming a
    /// language outside the supported nine fails in `CorpusLoader` with the file's name, and
    /// not inside `JSONDecoder` with a coding path.
    public let language: String
    /// The register the text is *written in* — what a style is asked to move it away from.
    public let register: String
    /// The same text in the other language, by item name, when there is one.
    public let mirror: String?
    public let facts: [Fact]
    public let traps: [Trap]

    public init(genre: String, language: String, register: String, mirror: String?,
                facts: [Fact], traps: [Trap]) {
        self.genre = genre; self.language = language; self.register = register
        self.mirror = mirror; self.facts = facts; self.traps = traps
    }
}
