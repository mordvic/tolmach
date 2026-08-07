// Sources/TranslatorApp/FileQueuePane.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queue.jobs.isEmpty {
                VStack(spacing: 10) {
                    dropTarget
                    Text("Нажмите «Перевести», чтобы начать")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $queue.selection) {
                    ForEach(queue.jobs) { job in
                        FileQueueRow(job: job,
                                     needsSaving: queue.needsSaving(job),
                                     onSaveBeside: { queue.saveBesideSource(job.id) },
                                     onSaveAs: { saveAs(job) },
                                     onReveal: { reveal(job) })
                            .tag(job.id)
                    }
                }
                .listStyle(.inset)
                dropTarget
            }
        }
        .frame(minWidth: 280)
        // Refusing returns `false`, which springs every item back — the same and only
        // error channel `SourceEditor` uses. It happens only when nothing in the drop was
        // readable: a mixed drop is accepted and its refusals become visible rows, so the
        // user learns *which* file could not be taken instead of watching ten fly home
        // with no explanation. See `QueueDrop.accept`.
        .dropDestination(for: URL.self) { urls, _ in
            guard queue.canChangeMode, let items = QueueDrop.accept(urls) else { return false }
            // Reading and planning are the model's, off the main actor; this closure only
            // decides *when*, exactly as `SourceEditor`'s does.
            Task { await queue.add(dropped: items) }
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
        queue.save(job.id, to: url)
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
    let needsSaving: Bool
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
                ProgressView(value: Double(progress.partsDone),
                             total: Double(max(progress.partsTotal, 1)))
                    .progressViewStyle(.linear)
                if let detail = runningDetail(progress) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem = job.saveProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The drawing puts the warning count and the save action on one line, and they
            // belong together: both are «what is left to do about this file».
            if job.state == .finished {
                HStack(spacing: 6) {
                    if let result = job.result, result.hasWarnings {
                        Text(RussianCopy.warningCount(result.warningCount))
                            .foregroundStyle(.secondary)
                    }
                    if needsSaving {
                        if let result = job.result, result.hasWarnings { Text("·").foregroundStyle(.tertiary) }
                        Button("Сохранить рядом с исходником", action: onSaveBeside).buttonStyle(.link)
                        Text("·").foregroundStyle(.tertiary)
                        Button("Сохранить как…", action: onSaveAs).buttonStyle(.link)
                    } else if let saved = job.result?.savedTo {
                        // Names the file rather than saying «сохранено», because the name
                        // may not be the one the user expects: a taken name gets a number.
                        if let result = job.result, result.hasWarnings { Text("·").foregroundStyle(.tertiary) }
                        Button("сохранено как \(saved.lastPathComponent)", action: onReveal)
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
        // The running file is tinted, as the drawing has it. Not the *selected* one —
        // `List` draws its own selection, and two highlights competing for one row is how
        // a user loses track of which is which.
        .listRowBackground(isRunning ? Color.accentColor.opacity(0.08) : nil)
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
        case .running: RussianCopy.chunkCount(job.partsTotal)
        // The ✓ is the drawing's, and it earns its place: «готово за 3 140 мс» and
        // «прервано» are otherwise two greys of the same weight in the same corner.
        case .finished: job.result.map { "✓ " + RussianCopy.finishedIn(milliseconds: $0.elapsedMS) } ?? "✓"
        case .interrupted: "прервано"
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
