// Sources/TranslatorApp/DocumentTermsView.swift
import SwiftUI
import TranslationCore

/// One row of the review: either the user's own entry, shown for context, or an index into
/// the request's editable entries.
///
/// An index and not a copy for the document case, because the field writes through a
/// binding into `DocumentTermsRequest.entries`, and a copied entry would edit a value
/// nobody reads.
enum DocumentTermsRow: Equatable {
    case user(GlossaryEntry)
    case document(Int)
}

/// «Термины документа» — the документный глоссарий, before the translation that uses it.
///
/// Every decision this surface makes is a static function below, so it can be checked
/// without rendering: which rows exist, in what order, and what the two sentences say. The
/// `body` only arranges them.
struct DocumentTermsView: View {
    @Bindable var request: DocumentTermsRequest
    let target: Language
    /// True only in a queue run, which is the only place «больше не спрашивать» means
    /// anything.
    var showsSuppress: Bool = false
    var onAddToGlossary: () -> Void = {}

    static func headline(for draft: DocumentTermsDraft) -> String {
        "Термины документа — \(draft.documentEntries.count)"
    }

    static func explanation(for draft: DocumentTermsDraft) -> String {
        let parts = RussianCopy.plural(draft.chunkCount, "части", "частях", "частях")
        return "Они переведены один раз и будут одинаковы во всех \(draft.chunkCount) \(parts). "
            + "Исправьте то, что переведено не так, — перевод ещё не начался."
    }

    static func origin(_ row: DocumentTermsRow) -> String {
        switch row {
        case .user: "глоссарий"
        case .document: "документ"
        }
    }

    /// The user's entries first, then the model's — and a model entry whose term the user's
    /// glossary already covers is dropped rather than shown twice.
    ///
    /// `GlossaryMerge.merge(user:document:)` lets the user's entry win, so an editable
    /// duplicate would take a change that the engine discards on the very next line.
    /// Compared case-insensitively, because `merge` does.
    static func rows(for draft: DocumentTermsDraft) -> [DocumentTermsRow] {
        let covered = Set(draft.userEntries.map { $0.term.lowercased() })
        return draft.userEntries.map { DocumentTermsRow.user($0) }
            + draft.documentEntries.enumerated()
                .filter { !covered.contains($0.element.term.lowercased()) }
                .map { DocumentTermsRow.document($0.offset) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.headline(for: request.draft)).font(.headline)
                Text(Self.explanation(for: request.draft))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider()
            table
            Divider()

            HStack(spacing: 8) {
                Button("Добавить в пользовательский глоссарий", action: onAddToGlossary)
                    .buttonStyle(.link).font(.caption)
                Spacer()
                if showsSuppress {
                    Toggle("Больше не спрашивать в этом прогоне", isOn: $request.suppressForRun)
                        .toggleStyle(.checkbox).font(.caption)
                }
                // One primary button, not the drawing's two. «Переводить без правок» beside
                // «Перевести» is indistinguishable from it before any edit and silently
                // discards work after one; Esc and ⨯ are the escape, and they cancel the run.
                // `.borderedProminent` explicitly, and not left to `.defaultAction` to
                // imply it. The drawing gives this button the same blue fill the window's
                // «Перевести» has, and whether the default-action shortcut alone produces
                // that fill for a plain `Button` in a custom sheet is not something this
                // environment can render and check. Stating the style costs one line and
                // does not depend on the answer.
                Button("Перевести") { request.proceed() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .frame(width: 520)
        // Esc. A sheet with no way out is a trap, and the drawing has no cancel at all —
        // the panel's ⨯ was its escape, and a sheet has none of its own.
        .onExitCommand { request.cancel() }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("термин").frame(maxWidth: .infinity, alignment: .leading)
                Text("перевод").frame(maxWidth: .infinity, alignment: .leading)
                Text("откуда").frame(width: 96, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(Self.rows(for: request.draft).enumerated()), id: \.offset) { _, row in
                        rowView(row)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func rowView(_ row: DocumentTermsRow) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .user(let entry):
                Text(entry.term).frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.doNotTranslate ? "не переводить"
                                          : entry.requiredTranslation(for: target) ?? "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .document(let index):
                Text(request.entries[index].term)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("перевод", text: binding(for: index))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            Text(Self.origin(row))
                .font(.caption).foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    /// Writes through into the request's own entries, keyed by the target language, the
    /// same way `SettingsGlossaryView.entryBinding` writes into a glossary row.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { request.entries[index].translations[target.rawValue] ?? "" },
            set: { request.entries[index].translations[target.rawValue] = $0 })
    }
}
