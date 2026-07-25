// Sources/TranslationCore/Tone.swift
import Foundation

public enum Tone: String, CaseIterable, Sendable {
    case neutral, formal, casual, technical, literal

    public var instruction: String {
        switch self {
        case .neutral:
            "Use a neutral register that matches the source."
        case .formal:
            "Use a formal, polite business register. Prefer the formal form of address where the target language distinguishes it."
        case .casual:
            "Use a relaxed, conversational register, as a colleague would write to a teammate."
        case .technical:
            "Use precise technical language. Prefer established industry terminology over everyday synonyms."
        case .literal:
            "Stay as close to the source wording and sentence structure as the target language allows, even if the result reads stiffly."
        }
    }
}
