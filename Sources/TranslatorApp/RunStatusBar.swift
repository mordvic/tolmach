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
    /// Non-nil when the window is showing «Файлы». The bar then reports the queue rather
    /// than the text model — one row, two sources, chosen here so neither pane has to grow
    /// a status bar of its own.
    var queue: FileQueueModel?
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
                if canDisclose {
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
            // §6.6's other half. The engine goes on swallowing a failed term-list call —
            // right when nobody asked — but the user who turned the gate on is waiting for
            // something that will never appear, and the run's terminology quietly differs
            // from what they were promised.
            // The glossary's own trouble, which belongs to no файл: `promoteToGlossary`
            // writes its three save failures here, raised from the terms sheet the queue
            // opens, and they can land before any задание has finished. Always visible in
            // «Файлы» rather than folded into a count or hidden under a disclosure.
            if queue != nil, let problem = glossaryProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if queue == nil, model.documentTermsUnavailable, model.state == .finished {
                Label("Термины документа не удалось подготовить, перевод шёл без них",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            // Gated on `canDisclose`, the same property the chevron reads. `expanded` is
            // `@State` and survives across runs and across a change of selection, so a
            // branch with a weaker condition than the chevron's draws an empty
            // `WarningsView` plus this stack's own spacing with nothing left to collapse it.
            if expanded, canDisclose, let warnings = warningsView {
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
        if let queue {
            // The **file's** count, the same `disclosureCount` its row shows. Counting
            // through `WarningsView` instead folded `glossaryProblem` in, so the bar said
            // «N+1 предупреждение» beside a row saying «N» for one file — the very
            // two-counts-for-one-file failure `disclosureCount` exists to remove. The
            // glossary problem is the app's trouble and not the file's, so it gets a line of
            // its own below rather than a place in this number.
            guard let count = queue.selectedResult?.disclosureCount, count > 0 else { return nil }
            return RussianCopy.warningCount(count)
        }
        return Self.summary(outcome: model.outcome, problem: glossaryProblem)
    }

    /// Whether the disclosure is offered at all. In «Текст» that is a finished run; in
    /// «Файлы» it is a selected задание that finished, whatever the queue is doing now —
    /// the warnings belong to the file the user is looking at, not to the run in flight.
    /// Whether there is a disclosure at all — read by the chevron **and** by the body it
    /// opens, so the two cannot disagree.
    ///
    /// One property and not two conditions, and that is the whole point. The chevron asked
    /// `summary != nil` while the expanded branch asked something weaker, so a run that
    /// left the warnings expanded followed by a clean one drew an empty `WarningsView` and
    /// its 6 pt of spacing with **no chevron to collapse it** — `expanded` is `@State` and
    /// survives across runs and across a change of selection. That is precisely the failure
    /// the comment at the call site has always described, reintroduced by splitting the
    /// condition in two.
    private var canDisclose: Bool {
        guard summary != nil, warningsView != nil else { return false }
        // A glossary problem is worth disclosing whatever the run is doing — it is the app's
        // trouble, not the run's, and gating it on `.finished` hid it behind a state it has
        // nothing to do with.
        return queue != nil || model.state == .finished || glossaryProblem != nil
    }

    /// The warnings for whatever this bar is currently describing, or nil if there are none
    /// to describe. Built once here rather than twice in the body, so the disclosure and its
    /// contents cannot disagree about which run they belong to.
    private var warningsView: WarningsView? {
        if let queue {
            guard let result = queue.selectedResult else { return nil }
            // `problem` and `target` were both nil here, and neither was harmless.
            // `glossaryProblem` is exactly where `promoteToGlossary` writes its three save
            // failures — raised from the terms sheet, which the queue itself opens — so a
            // refused save explained itself to a property no visible surface read. And a nil
            // target makes the «Термины документа» disclosure render by lexicographic key
            // instead of by the language the задание was translated into.
            // `problem: nil` — it is rendered as its own row below instead, so it cannot be
            // hidden under a chevron that a file with nothing to report never draws.
            return WarningsView(checks: result.checks, markupDiffs: result.markupDiffs,
                                documentGlossary: result.documentGlossary,
                                target: queue.selectedTarget, problem: nil,
                                onMute: onMute)
        }
        guard let outcome = model.outcome, model.state == .finished else {
            // `promoteToGlossary` is a new writer of `glossaryProblem` and it can fire with
            // no outcome at all — the terms sheet is raised by the queue or the panel while
            // this window's own text model has never run. Without this the Russian
            // explanation of a refused save was written to a property nothing rendered.
            return glossaryProblem.map {
                WarningsView(checks: [], markupDiffs: [], documentGlossary: [],
                             target: nil, problem: $0, onMute: onMute)
            }
        }
        return WarningsView(outcome: outcome, target: model.resolvedTarget,
                            problem: glossaryProblem, onMute: onMute)
    }

    @ViewBuilder private var line: some View {
        // «Файлы» reports the queue: one row, and the text model behind it is not what the
        // user is looking at.
        if let queue {
            // Same correction as the panel's: the sheet is up over this very window and the
            // model is idle, so a spinner and «Перевожу…» would contradict it.
            if queue.isAwaitingTerms {
                Label("Жду ваших правок…", systemImage: "square.and.pencil")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let status = queue.statusLine {
                HStack(spacing: 6) {
                    if queue.isRunning { ProgressView().controlSize(.small) }
                    Text(status).font(.caption)
                        .foregroundStyle(queue.pausedAfterWarnings ? AnyShapeStyle(.orange)
                                                                   : AnyShapeStyle(.secondary))
                }
            } else {
                Text(self.status.label).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            textModeLine
        }
    }

    @ViewBuilder private var textModeLine: some View {
        switch model.state {
        case .idle:
            Text(status.label).font(.caption).foregroundStyle(.secondary)
        case .running:
            if model.isAwaitingTerms {
                Label("Жду ваших правок…", systemImage: "square.and.pencil")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Перевожу…").font(.caption)
                }
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
    /// `WarningsView.warningCount`, the same computed count `hasContent` is itself defined as
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
