import Foundation
import NaturalLanguage

public enum Language: String, CaseIterable, Sendable {
    case ru, en, de, fr, es, pt, it, zh, ja

    public var englishName: String {
        switch self {
        case .ru: return "Russian"
        case .en: return "English"
        case .de: return "German"
        case .fr: return "French"
        case .es: return "Spanish"
        case .pt: return "Portuguese"
        case .it: return "Italian"
        case .zh: return "Chinese (Simplified)"
        case .ja: return "Japanese"
        }
    }

    public var flag: String {
        switch self {
        case .ru: return "RU"
        case .en: return "EN"
        case .de: return "DE"
        case .fr: return "FR"
        case .es: return "ES"
        case .pt: return "PT"
        case .it: return "IT"
        case .zh: return "ZH"
        case .ja: return "JA"
        }
    }
}

public struct LanguageHypothesis: Sendable {
    public let code: String
    public let confidence: Double

    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }
}

/// Native language detection. Costs nothing and runs instantly — the LLM should
/// never be spent on figuring out what language the input is in.
public enum LanguageDetector {
    public static func detect(_ text: String) -> Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        return map(code)
    }

    public static func hypotheses(_ text: String, max count: Int = 3) -> [LanguageHypothesis] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: count)
            .map { LanguageHypothesis(code: $0.key.rawValue, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }
    }

    static func map(_ nlCode: String) -> Language? {
        switch nlCode {
        case "ru": return .ru
        case "en": return .en
        case "de": return .de
        case "fr": return .fr
        case "es": return .es
        case "pt": return .pt
        case "it": return .it
        case "zh-Hans", "zh-Hant": return .zh
        case "ja": return .ja
        default: return nil
        }
    }
}
