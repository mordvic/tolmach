// Sources/TranslatorApp/RunStatusBar.swift
import SwiftUI
import TranslationCore

/// The window's bottom row: one line that says what the run is doing, and a disclosure that
/// opens the warnings underneath it.
///
/// It replaces a single caption that carried four unrelated meanings in turn — Ollama's
/// state, «Перевожу…», the elapsed time, and the failure message — and it is what lets the
/// warnings stop competing with the editors for the window's minimum height. Collapsed, the
/// whole region costs one row; the old inline panel claimed 140pt of a 460pt window whether
/// or not it was being read.
struct RunStatusBar: View {
    let model: TranslationViewModel
    let status: OllamaStatus
    var glossaryProblem: String?
    var onMute: (String) -> Void = { _ in }
    var onRetry: () -> Void = {}

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Not `if let summary`: the label never reads the string, only whether
                // there is one, and binding a name for a value nobody uses is what the
                // compiler's `#no-usage` warning is for.
                if summary != nil, model.state == .finished {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Свернуть предупреждения" : "Показать предупреждения")
                }
                line
                Spacer(minLength: 0)
            }
            // `summary != nil` gates this branch too, not just `expanded`: `expanded` is
            // `@State` and survives across runs, so without this a run that leaves
            // warnings expanded, followed by a second, quiet run, would show no triangle
            // to press — `summary` would be nil — while still drawing an empty
            // `WarningsView` plus this stack's own spacing underneath. That is the exact
            // failure `summary`'s own doc comment exists to prevent, reached through
            // stale `@State` rather than through a disagreeing count.
            if expanded, summary != nil, let outcome = model.outcome, model.state == .finished {
                let warnings = WarningsView(outcome: outcome, target: model.resolvedTarget,
                                            problem: glossaryProblem, onMute: onMute)
                // `ViewThatFits` and not a bare `ScrollView`, because a `ScrollView` is
                // greedy in its scroll axis: it would sit at the full 200 under a two-line
                // warning and leave the rest blank. This takes the plain stack's own height
                // while that fits, and only falls back to scrolling once it does not.
                //
                // 200 rather than the 140 this used to be. The old number came out of the
                // window's minimum height because the warnings sat between the editors and
                // the bottom of the window whether or not anyone was reading them. Collapsed
                // by default, the region costs one row, so the ceiling can be set by what is
                // readable rather than by what the editors can spare.
                ViewThatFits(in: .vertical) {
                    warnings
                    ScrollView { warnings }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
    }

    private var summary: String? {
        Self.summary(outcome: model.outcome, problem: glossaryProblem)
    }

    @ViewBuilder private var line: some View {
        switch model.state {
        case .idle:
            Text(status.label).font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Перевожу…").font(.caption)
            }
        case .finished:
            if let outcome = model.outcome {
                Text(summary.map { "Готово за \(Int(outcome.totalMS)) мс · \($0)" }
                     ?? "Готово за \(Int(outcome.totalMS)) мс")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .interrupted:
            Text("Перевод прерван — показана та часть, что успела прийти")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            // Spec 8 pairs both failure rows — a timed-out request and an empty model reply
            // — with a retry. Reachable: `translate()` opens with `guard state != .running`,
            // and `.failed` is not `.running`. The source text is still in the editor, so
            // retrying costs the user nothing but the wait.
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить", action: onRetry).font(.caption)
            }
        }
    }

    /// How many warnings are hiding under the triangle, or nil if there are none.
    ///
    /// A static function rather than a computed property, because it is the one decision in
    /// this view that can be checked: it must agree with `WarningsView.hasContent` exactly.
    /// A summary that disagreed would offer a disclosure that expands to nothing, or hide a
    /// warning behind a triangle nobody is told to press.
    ///
    /// The agreement is structural, not two formulas kept in sync by hand: this reads
    /// `WarningsView.warningCount`, the same stored count `hasContent` is itself defined as
    /// `> 0` of. There is one count in the program that says how many warnings an outcome
    /// carries, and both the disclosure's visibility and its label are read from it, so they
    /// cannot drift apart the way two independently-written conditions could.
    static func summary(outcome: TranslationOutcome?, problem: String?) -> String? {
        guard let outcome else { return problem.map { _ in "1 предупреждение" } }
        let count = WarningsView(outcome: outcome, target: nil, problem: problem).warningCount
        guard count > 0 else { return nil }
        return "\(count) " + RussianCopy.plural(count, "предупреждение", "предупреждения",
                                                "предупреждений")
    }
}
