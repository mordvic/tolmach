// Sources/TranslatorApp/FileQueuePane.swift
import SwiftUI
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
                        FileQueueRow(job: job).tag(job.id)
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
            if let result = job.result, job.state == .finished, result.hasWarnings {
                Text(RussianCopy.warningCount(result.warningCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = job.saveProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        // One announcement per row rather than four unlabelled fragments, so VoiceOver
        // reads «techdoc-en.md, перевожу часть 4 из 7» instead of spelling the layout.
        .accessibilityElement(children: .combine)
    }

    private var trailing: String {
        switch job.state {
        case .queued: RussianCopy.queuedFile(parts: job.partsTotal)
        case .running: RussianCopy.chunkCount(job.partsTotal)
        case .finished: job.result.map { RussianCopy.finishedIn(milliseconds: $0.elapsedMS) } ?? ""
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
