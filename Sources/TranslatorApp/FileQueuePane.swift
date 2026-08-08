// Sources/TranslatorApp/FileQueuePane.swift
import SwiftUI
import AppKit
import TranslationCore

/// Which of the two things the window's left half is showing.
enum SourceMode: String, CaseIterable, Identifiable {
    case text, files
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: "Текст"
        case .files: "Файлы"
        }
    }
}

/// The window's left half in «Файлы»: the queue.
struct FileQueuePane: View {
    @Bindable var queue: FileQueueModel
    /// Whether «Перевести» can actually be pressed — `PrimaryAction`'s answer, which
    /// includes Ollama's health. Without it the hint below pointed at a greyed-out button
    /// whenever the server was down: the same «instruction for a control that does nothing»
    /// it was moved here to stop being.
    let canStart: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queue.jobs.isEmpty {
                // No «Нажмите "Перевести"» here: with an empty queue that button is
                // disabled, so the instruction pointed at a control that does nothing. It
                // belongs below, where there is something to start.
                dropTarget
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $queue.selection) {
                    ForEach(queue.jobs) { job in
                        FileQueueRow(job: job,
                                     // The row is the third surface that could claim work
                                     // while the model sits idle. The panel and the status
                                     // bar were corrected; this one kept a filled bar and
                                     // «Перевожу часть 1 из 4» directly above a bar reading
                                     // «Жду ваших правок…».
                                     awaitingTerms: queue.isAwaitingTerms && job.id == queue.runningID,
                                     needsSaving: queue.needsSaving(job),
                                     canSaveElsewhere: queue.canSaveElsewhere(job),
                                     onSaveBeside: { Task { await queue.saveBesideSource(job.id) } },
                                     onSaveAs: { saveAs(job) },
                                     onReveal: { reveal(job) })
                            .tag(job.id)
                            // The drawing's gaps, and the two modifiers are one statement:
                            // the rows are cards with 6 pt of air between them, so the
                            // separator `List` draws between every pair would be a second
                            // divider in that air. 3 + 3 top and bottom makes the 6; 8 at the
                            // sides is the padding the drawing gives the white list area.
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            // The one way a row leaves the queue. The spec promises an
                            // unreadable file «can be removed», and until now nothing
                            // could remove anything — `remove(_:)` existed and no view
                            // called it. Refused mid-run by the model, so a задание cannot
                            // vanish from under the task translating it.
                            .contextMenu {
                                Button("Убрать из очереди") { queue.remove(job.id) }
                                    .disabled(!queue.canChangeMode)
                            }
                    }
                }
                .listStyle(.inset)
                if canStart, let hint = queue.startHint {
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
                dropTarget
            }
        }
        .frame(minWidth: 280)
        // Refusing returns `false`, which springs every item back — the same and only
        // error channel `SourceEditor` uses. It happens only when nothing in the drop was
        // plausible: a mixed drop is accepted and its refusals become visible rows, so the
        // user learns *which* file could not be taken instead of watching ten fly home with
        // no explanation. See `QueueDrop.acceptable`.
        .dropDestination(for: URL.self) { urls, _ in
            // `acceptable` reads no bytes — it asks the extension and the size, which the
            // filesystem answers from an attribute. Reading and planning are the model's,
            // off the main actor; this closure only decides *when*, exactly as
            // `SourceEditor`'s does.
            guard queue.canChangeMode, QueueDrop.acceptable(urls) else { return false }
            Task { await queue.add(droppedURLs: urls) }
            return true
        }
    }

    /// «Сохранить как…». The panel is the recovery path for a refused write, and not only
    /// a convenience: `NSSavePanel` confers the write right itself, which is what makes it
    /// an answer to a TCC refusal rather than an apology for one.
    private func saveAs(_ job: FileJob) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = queue.suggestedName(for: job.id)
        panel.directoryURL = job.url.deletingLastPathComponent()
        panel.prompt = "Сохранить"
        panel.message = "Куда сохранить перевод"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await queue.save(job.id, to: url) }
    }

    private func reveal(_ job: FileJob) {
        guard let url = job.result?.savedTo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var dropTarget: some View {
        VStack(spacing: 4) {
            Text("Перетащите .md, .txt или .markdown")
            Text("Файл читается целиком, код не делится между частями")
        }
        .font(.caption).foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(8)
    }
}

private struct FileQueueRow: View {
    let job: FileJob
    let awaitingTerms: Bool
    let needsSaving: Bool
    let canSaveElsewhere: Bool
    let onSaveBeside: () -> Void
    let onSaveAs: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.url.lastPathComponent).font(.body)
                Spacer(minLength: 8)
                Text(trailing).font(.caption).foregroundStyle(trailingStyle)
            }
            if case let .running(progress) = job.state {
                if awaitingTerms {
                    // No bar: nothing is moving. Same words the panel and the status bar use.
                    Text("Жду ваших правок…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: Double(progress.partsDone),
                                 total: Double(max(progress.partsTotal, 1)))
                        .progressViewStyle(.linear)
                    if let detail = runningDetail(progress) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if job.documentTermsUnavailable {
                // §6.6: the user asked for the gate and it never opened. Silence here lets
                // the run's terminology differ from what they were promised with nothing on
                // screen to say why.
                Text("термины документа не удалось подготовить")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let problem = job.saveProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // An interrupted задание keeps its partial text, and «Сохранить как…» is the
            // only way it reaches disk: the canonical name is reserved for a translation
            // that finished, because half a document under it looks like a whole one.
            if job.state == .interrupted, canSaveElsewhere {
                Button("Сохранить как…", action: onSaveAs).buttonStyle(.link).font(.caption)
            }
            // Saving is the one outcome that had no feedback: a refusal renders
            // `saveProblem` outside every state gate, while a success made the button
            // disappear and said nothing — and for an interrupted задание the «сохранено
            // как …» row below was gated on `.finished`, so it never appeared at all.
            if job.state == .interrupted, let saved = job.result?.savedTo {
                Button("сохранено как \(saved.lastPathComponent)", action: onReveal)
                    .buttonStyle(.link).font(.caption)
            }
            // The drawing puts the warning count and the save action on one line, and they
            // belong together: both are «what is left to do about this file».
            if job.state == .finished {
                HStack(spacing: 6) {
                    if let result = job.result, result.disclosureCount > 0 {
                        Text(RussianCopy.warningCount(result.disclosureCount))
                            .foregroundStyle(.secondary)
                    }
                    if needsSaving {
                        if let result = job.result, result.disclosureCount > 0 { Text("·").foregroundStyle(.tertiary) }
                        Button("Сохранить рядом с исходником", action: onSaveBeside).buttonStyle(.link)
                        Text("·").foregroundStyle(.tertiary)
                        Button("Сохранить как…", action: onSaveAs).buttonStyle(.link)
                    } else if let saved = job.result?.savedTo {
                        // Names the file rather than saying «сохранено», because the name
                        // may not be the one the user expects: a taken name gets a number.
                        if let result = job.result, result.disclosureCount > 0 { Text("·").foregroundStyle(.tertiary) }
                        Button("сохранено как \(saved.lastPathComponent)", action: onReveal)
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        // The drawing draws every задание as a card — 1 pt border, radius 6, 9 × 8 inside —
        // rather than as a line in a list. It is worth the chrome here and nowhere else in
        // this window: a row is four to six stacked fragments (name, счётчик, полоса,
        // «Перевожу часть 4 из 7», предупреждения, «Сохранить рядом с исходником»), and with
        // nothing enclosing them the fragments of two neighbouring файлы read as one column.
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        // The running file is tinted, as the drawing has it. Not the *selected* one — `List`
        // draws its own selection, and two highlights competing for one row is how a user
        // loses track of which is which.
        //
        // The tint moved **into** the card and out of `.listRowBackground`, and that is what
        // keeps the sentence above true. `.listRowBackground` replaces the row's background,
        // which is where `List` draws that selection: tinting the running row through it hid
        // the selection whenever the two coincided — and the selection is what decides whose
        // translation the right-hand pane is showing. A fill inside the card leaves the row's
        // own background to `List`, so both are visible at once.
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isRunning ? Color.accentColor.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isRunning ? AnyShapeStyle(Color.accentColor.opacity(0.35))
                                    : AnyShapeStyle(.quaternary)))
        // One announcement per row rather than four unlabelled fragments, so VoiceOver
        // reads «techdoc-en.md, перевожу часть 4 из 7» instead of spelling the layout.
        .accessibilityElement(children: .combine)
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    private var trailing: String {
        switch job.state {
        case .queued: RussianCopy.queuedFile(parts: job.partsTotal)
        // The engine's number, not the drop-time estimate: `chunkSize` can change between
        // the drop and the turn, and `FileJob.partsTotal`'s own doc comment says the running
        // row must draw from the run. Reading the stored one put «7 частей» next to
        // «Перевожу часть 2 из 4».
        case .running(let progress): RussianCopy.chunkCount(progress.partsTotal)
        // The ✓ is the drawing's, and it earns its place: «готово за 3 140 мс» and
        // «прервано» are otherwise two greys of the same weight in the same corner.
        case .finished: job.result.map { "✓ " + RussianCopy.finishedIn(milliseconds: $0.elapsedMS) } ?? "✓"
        case .interrupted:
            job.result.map { RussianCopy.interruptedAfter(milliseconds: $0.elapsedMS) } ?? "прервано"
        case .failed(let message): message
        case .unreadable: "не удалось прочитать"
        }
    }

    /// Only the two states that are a complaint are tinted. An earlier draft branched and
    /// returned `.secondary` from both arms — a switch that pretended to distinguish cases
    /// it did not.
    private var trailingStyle: Color {
        switch job.state {
        case .failed, .unreadable: .orange
        default: .secondary
        }
    }

    /// Nil once every часть is done — `partProgress` returns nil there rather than
    /// claiming «часть 7 из 7» under a file with no work left.
    private func runningDetail(_ progress: TranslationProgress) -> String? {
        guard let part = RussianCopy.partProgress(done: progress.partsDone,
                                                  total: progress.partsTotal) else { return nil }
        guard progress.documentTermCount > 0 else { return part }
        return "\(part) · \(RussianCopy.documentTermCount(progress.documentTermCount))"
    }
}
