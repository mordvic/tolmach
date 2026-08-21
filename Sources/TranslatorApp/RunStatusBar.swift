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
    let status: EngineStatus
    /// The engine's name, so the status line needs nothing from this view about which
    /// server it is describing. See `RussianCopy.engineStatus`.
    let engineName: String
    /// Whether the selected engine has a model to translate with. False turns the idle line
    /// into the one instruction that unblocks the window — see `RussianCopy.idleLine`.
    let hasModel: Bool
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
            // The glossary's own trouble, which belongs to no файл and to no run:
            // `promoteToGlossary` writes its three save failures here, raised from the terms
            // sheet that the queue **or the ⌥⌘T panel** opens, and they can land before any
            // задание — or any text run — has finished. Always visible, and in both modes.
            //
            // «Файлы» only, it was invisible where it is least expected: the panel raises
            // the sheet, the save is refused, this window's own text model has never run, so
            // the only trace was a bare chevron over «1 предупреждение» that nothing invited
            // anyone to press. Shown here it needs no disclosure at all, which is why
            // nothing below folds it into a count any more.
            if let problem = glossaryProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(StatusColour.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if queue == nil, model.documentTermsUnavailable, model.state == .finished {
                Label("Термины документа не удалось подготовить, перевод шёл без них",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(StatusColour.warning)
            }
            // Gated on `canDisclose`, the same property the chevron reads. `expanded` is
            // `@State` and survives across runs and across a change of selection, so a
            // branch with a weaker condition than the chevron's draws an empty
            // `WarningsView` plus this stack's own spacing with nothing left to collapse it.
            if expanded, canDisclose, let warnings = warningsView {
                // 200 rather than the 140 this used to be. Why the block is bounded at all,
                // and why by `ViewThatFits` rather than a `ScrollView`, is `BoundedByHeight`'s
                // — this is only the number. The old number came out of the
                // window's minimum height because the warnings sat between the editors and
                // the bottom of the window whether or not anyone was reading them. Collapsed
                // by default, the region costs one row, so the ceiling can be set by what is
                // readable rather than by what the editors can spare.
                warnings.bounded(byHeight: 200)
                // The drawing indents the whole disclosure by 16 pt, which puts «Разметка
                // изменилась» under «Готово за 4 812 мс» rather than under the chevron that
                // opened it. Flush left, the bold group titles start at the same x as the
                // summary's own control and read as three peers of it instead of as its
                // contents — and this row is the one place in the window where a heading and
                // the thing it belongs to are stacked rather than side by side.
                .padding(.leading, 16)
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
        // Branched exactly as `warningsView` is, and that is the point. `TranslationViewModel`
        // drops the previous `outcome` only when the first real token of the next run
        // arrives, so during `.running` it is still the *last* run's, and a label reading it
        // on a different condition than the body produced «4 предупреждения» over a
        // disclosure containing one row. The label and the body answer from one condition.
        guard let outcome = model.outcome, model.state == .finished else { return nil }
        return Self.summary(outcome: outcome)
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
        // No `glossaryProblem` term any more: it is drawn as its own always-visible row
        // above, so a disclosure that opened only to show it would be a chevron over a
        // sentence already on screen.
        return queue != nil || model.state == .finished
    }

    /// The warnings for whatever this bar is currently describing, or nil if there are none
    /// to describe. Built once here rather than twice in the body, so the disclosure and its
    /// contents cannot disagree about which run they belong to.
    private var warningsView: WarningsView? {
        if let queue {
            guard let result = queue.selectedResult else { return nil }
            // `target` was nil here and that was not harmless: a nil target makes the
            // «Термины документа» disclosure render by lexicographic key instead of by the
            // language the задание was translated into.
            //
            // No glossary problem, though — it is rendered as its own row above, so it
            // cannot be hidden under a chevron that a file with nothing to report never
            // draws. This comment used to argue the opposite in its first half and the
            // present rule in its second, both at once: an intermediate fix passed
            // `problem` here, a later one moved it out to the row, and only the tail of the
            // paragraph was rewritten. Following the half that was left would put
            // «N+1 предупреждение» back beside a file row saying «N».
            return WarningsView(checks: result.checks, markupDiffs: result.markupDiffs,
                                documentGlossary: result.documentGlossary,
                                target: queue.selectedTarget, onMute: onMute)
        }
        guard let outcome = model.outcome, model.state == .finished else { return nil }
        return WarningsView(outcome: outcome, target: model.resolvedTarget, onMute: onMute)
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
                        .foregroundStyle(queue.pausedAfterWarnings ? AnyShapeStyle(StatusColour.warning)
                                                                   : AnyShapeStyle(.secondary))
                }
            } else if let summary {
                // Rendered, not merely computed. It was used only to gate `canDisclose`, so
                // the chevron in «Файлы» stood over a count nothing spelled out — while the
                // «Текст» branch has always spelled it.
                Text(summary).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(RussianCopy.idleLine(self.status, engineName: self.engineName, hasModel: self.hasModel)).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            textModeLine
        }
    }

    @ViewBuilder private var textModeLine: some View {
        switch model.state {
        case .idle:
            Text(RussianCopy.idleLine(status, engineName: engineName, hasModel: hasModel)).font(.caption).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(StatusColour.warning)
        case .failed(let message):
            // Spec 8 pairs both failure rows — a timed-out request and an empty model reply
            // — with a retry. Reachable: `translate()` opens with `guard state != .running`,
            // and `.failed` is not `.running`. The source text is still in the editor, so
            // retrying costs the user nothing but the wait.
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(StatusColour.failure)
                    .fixedSize(horizontal: false, vertical: true)
                // Small, not standard. The drawing gives this button 19 pt and an 11 pt
                // label against the 22 and 12 every other button in the app gets, because
                // it is the only one that sits *inside* a caption-sized line rather than in
                // a row of its own — a full-height bezel beside «Ollama не запущена…» makes
                // the sentence look like a caption under a control instead of the message
                // the control answers.
                //
                // `.font` alone was the whole of it and only ever addressed the label:
                // `controlSize` is what the bezel is measured from, and it is the modifier
                // this codebase already reaches for when a control has to be drawn smaller
                // (the mode switch, and the spinner three lines above). Both are set, so the
                // label does not depend on `.small` choosing the font as well as the height.
                Button("Повторить", action: onRetry).font(.caption).controlSize(.small)
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
    static func summary(outcome: TranslationOutcome?) -> String? {
        // No outcome, nothing to summarise. It used to answer «1 предупреждение» for a
        // glossary save failure with no run behind it; that sentence is drawn in full,
        // undisclosed, by the bar itself now.
        guard let outcome else { return nil }
        let count = WarningsView(outcome: outcome, target: nil).warningCount
        guard count > 0 else { return nil }
        return "\(count) " + RussianCopy.plural(count, "предупреждение", "предупреждения",
                                                "предупреждений")
    }
}
