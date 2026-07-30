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
        // The index tiebreaker makes the ordering total: the output is uniquely determined
        // by the input and does not depend on sort's unspecified handling of equal elements.
        // Without it, two rows with the same term could swap places between recomputations.
        // No black-box test catches the tiebreaker's absence on this toolchain — tested with
        // 3, 50, 200, and 5000 entries. Record this contract to prevent tidying it away.
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

    /// Which of a set of selected indices remain valid once `order` changes.
    ///
    /// Membership in the new `order` is only a safe test when the change that produced it
    /// could not have shifted or repurposed an index — a search or an append. A removal
    /// shifts every later index down by one, and a re-read of the file can replace what an
    /// index points at without ever removing that index from `order`; in both cases a
    /// selected index can still satisfy `order.contains(_:)` while denoting a different row
    /// than the one the user selected. `indicesMayHaveShifted` is the caller's declaration of
    /// which situation this is — see `SettingsGlossaryView.reorder(indicesMayHaveShifted:)`,
    /// whose call sites are the only place that knows which of the two just happened.
    static func selection(_ selection: Set<Int>, survivingIn order: [Int],
                          indicesMayHaveShifted: Bool) -> Set<Int> {
        indicesMayHaveShifted ? [] : selection.filter { order.contains($0) }
    }
}
