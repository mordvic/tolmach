import Foundation

public enum Tone: String, CaseIterable, Sendable {
    case neutral
    case formal
    case casual
    case technical
    case literal

    public var instruction: String {
        switch self {
        case .neutral:
            return "Use a neutral register that matches the source."
        case .formal:
            return "Use a formal, polite business register. Prefer the formal form of address where the target language distinguishes it."
        case .casual:
            return "Use a relaxed, conversational register, as a colleague would write to a teammate."
        case .technical:
            return "Use precise technical language. Prefer established industry terminology over everyday synonyms."
        case .literal:
            return "Stay as close to the source wording and sentence structure as the target language allows, even if the result reads stiffly."
        }
    }
}
