// Sources/TranslatorApp/GlossaryOrder.swift
import Foundation
import TranslationCore

/// Which glossary rows to show, and in what order — as indices into `entries`.
///
/// Indices and not values, because rows are identified by position and that is deliberate:
/// `term` is the only other candidate and nothing uniques it. The file is hand-edited and
/// «Добавить термин» appends a blank one, so keying by term collapses two real rows into one
/// and silently drops the other's translation.
///
/// **The caller must not call this on every keystroke.** The pane recomputes the order only
/// when the set of rows or the query changes — adding, removing, searching, re-reading the
/// file — and never while a term is being typed. Live re-sorting would move the row out from
/// under the caret the moment its first letter changed, and live re-filtering would make it
/// vanish the moment it stopped matching the search.
enum GlossaryOrder {
    static func visibleOrder(entries: [GlossaryEntry], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = entries.indices.filter { index in
            needle.isEmpty || matches(entries[index], needle)
        }
        // `enumerated` and the index tiebreaker make this a stable sort. Swift's `sort` is
        // not guaranteed stable, and two rows with the same term swapping places between
        // recomputations would leave the user unable to tell which one they were editing.
        let indexed = matching.map { (index: $0, term: entries[$0].term.lowercased()) }
        let sorted = indexed.sorted { left, right in
            left.term == right.term ? left.index < right.index : left.term < right.term
        }
        return sorted.map(\.index)
    }

    private static func matches(_ entry: GlossaryEntry, _ needle: String) -> Bool {
        if entry.term.lowercased().contains(needle) { return true }
        return entry.translations.values.contains { $0.lowercased().contains(needle) }
    }
}
