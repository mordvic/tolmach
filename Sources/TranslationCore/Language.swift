// Sources/TranslationCore/Language.swift
import Foundation
import NaturalLanguage

public enum Language: String, CaseIterable, Sendable {
    case ru, en, de, fr, es, pt, it, zh, ja

    public var englishName: String {
        switch self {
        case .ru: "Russian"; case .en: "English"; case .de: "German"
        case .fr: "French"; case .es: "Spanish"; case .pt: "Portuguese"
        case .it: "Italian"; case .zh: "Chinese (Simplified)"; case .ja: "Japanese"
        }
    }

    public var shortCode: String { rawValue.uppercased() }

    public var nlLanguage: NLLanguage {
        switch self {
        case .ru: .russian; case .en: .english; case .de: .german
        case .fr: .french; case .es: .spanish; case .pt: .portuguese
        case .it: .italian; case .zh: .simplifiedChinese; case .ja: .japanese
        }
    }

    static func from(_ nlCode: String) -> Language? {
        switch nlCode {
        case "ru": .ru; case "en": .en; case "de": .de; case "fr": .fr
        case "es": .es; case "pt": .pt; case "it": .it
        case "zh-Hans", "zh-Hant", "zh": .zh; case "ja": .ja
        default: nil
        }
    }
}

public enum LanguageDetector {
    public static func detect(_ text: String) -> Language? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        return Language.from(code)
    }
}
