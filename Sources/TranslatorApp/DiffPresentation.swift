// Sources/TranslatorApp/DiffPresentation.swift
import Foundation
import TranslationCore

enum DiffPresentation {
    static func label(for token: MarkupToken) -> String {
        switch token {
        case .heading(let level): "заголовок \(level)-го уровня"
        case .listItem(let depth): depth == 0 ? "пункт списка" : "пункт списка (уровень \(depth + 1))"
        case .blockquote: "цитата"
        // The hash is a per-process content fingerprint — meaningless to a reader and
        // different on every run. Only the language is worth showing.
        case .codeBlock(_, let lang): lang.isEmpty ? "блок кода" : "блок кода (\(lang))"
        case .inlineCode(let text): "код «\(text)»"
        case .url(let bare): bare ? "ссылка без разметки" : "ссылка в разметке"
        case .paragraphBreak: "граница абзаца"
        case .hardLineBreak: "жёсткий перенос строки"
        case .tableRow: "строка таблицы"
        case .emphasis(let strong): strong ? "жирное выделение" : "курсив"
        // The count is the whole point of this token — a row that came back with two of
        // its four cells reads here as «строка таблицы из 4 ячеек → строка таблицы из 2
        // ячеек», which is the sentence `.tableRow` alone could never say.
        case .tableCells(let count): "строка таблицы из \(count) \(cellsGenitive(count))"
        }
    }

    /// «из N ячеек» — «из» governs the genitive, and the numeral inside it governs the
    /// noun: one is «одной ячейки», everything else is «ячеек» («из двух ячеек», «из пяти
    /// ячеек»). Only the 1-shaped numerals take the singular, and 11 is not one of them.
    static func cellsGenitive(_ count: Int) -> String {
        let last = abs(count) % 10, lastTwo = abs(count) % 100
        return last == 1 && lastTwo != 11 ? "ячейки" : "ячеек"
    }

    static func describe(_ diff: MarkupDiff) -> String {
        switch (diff.expected, diff.actual) {
        case let (expected?, actual?): "\(label(for: expected)) → \(label(for: actual))"
        case let (expected?, nil): "потеряно: \(label(for: expected))"
        case let (nil, actual?): "добавлено: \(label(for: actual))"
        case (nil, nil): "неизвестное расхождение"
        }
    }

    /// Only `.missing` is actionable. `.satisfied` needs no words, and `.unverifiable`
    /// deliberately shows nothing — spec 4.6: a checker that cries wolf stops being read.
    static func describe(_ check: GlossaryCheck) -> String? {
        guard check.status == .missing else { return nil }
        return "«\(check.term)» ожидалось как «\(check.expected)»"
    }
}
