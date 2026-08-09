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
    /// True only in a queue run, which is the only place «больше не спрашивать» means
    /// anything.
    var showsSuppress: Bool = false
    var onAddToGlossary: () -> Void = {}

    /// Counts the документный глоссарий, which is what the title names — not every row in
    /// the table.
    ///
    /// The user's rows are context, and counting them made this the odd one out among three
    /// surfaces describing one glossary: the queue row says «9 терминов документа» and
    /// `WarningsView` says «Термины документа (9)» while the sheet was titled «— 12». The
    /// extra rows are explained by «откуда», not by the heading.
    static func headline(for draft: DocumentTermsDraft) -> String {
        "Термины документа — \(draft.documentEntries.count)"
    }

    static func explanation(for draft: DocumentTermsDraft) -> String {
        let parts = RussianCopy.plural(draft.chunkCount, "части", "частях", "частях")
        return "Они переведены один раз и будут одинаковы во всех \(draft.chunkCount) \(parts). "
            + "Исправьте то, что переведено не так, — перевод ещё не начался."
    }

    /// What the escape is called. A queue run says which queue it stops, because that is
    /// the case where the effect reaches past the file on screen.
    static func cancelLabel(inQueue: Bool) -> String {
        inQueue ? "Остановить очередь" : "Отмена"
    }

    static func origin(_ row: DocumentTermsRow) -> String {
        switch row {
        case .user: "глоссарий"
        case .document: "документ"
        }
    }

    /// The user's entries first, then the model's — **all** of them, including terms the
    /// user's glossary also names.
    ///
    /// It used to drop those, on the reasoning that `GlossaryMerge.merge(user:document:)`
    /// lets the user's entry win so an editable duplicate would take a change the engine
    /// discards. That is true of a *part where the user's term occurs*, and only there: the
    /// engine filters the user side per часть — `relevantEntries(for:)` over that часть's
    /// code-stripped text — while the документный глоссарий goes into every часть whole
    /// (ADR 0001). `userEntries` here is computed once over the whole document.
    ///
    /// So a term the user glossary names in prose in часть 1 and that appears only inside a
    /// fenced block in часть 4 has *no* user entry injected for часть 4 — the model's
    /// version is what reaches that prompt, and hiding its row made it the one thing in the
    /// document the gate could not show or correct. Both rows are on screen now: the user's
    /// as read-only context, the model's editable, and «откуда» says which is which.
    static func rows(for draft: DocumentTermsDraft) -> [DocumentTermsRow] {
        draft.userEntries.map { DocumentTermsRow.user($0) }
            + draft.documentEntries.indices.map { DocumentTermsRow.document($0) }
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
                // The escape, named for what it does. Esc alone was the whole of it, and
                // **three separate reviews** filed the same complaint: a conventional
                // dismiss gesture was quietly abandoning every file behind this one. The
                // answer is not to shrink what Esc does — «Перевести» already is «skip this
                // file's review», so «stop» is the only other thing the sheet can mean — but
                // to let the user read it before pressing it. In a queue that means saying
                // out loud that the queue is what stops.
                //
                // This is why the drawing's *second* button was still right to drop and this
                // one is right to add: «Переводить без правок» duplicated «Перевести», while
                // this does something no other control here can.
                Button(Self.cancelLabel(inQueue: showsSuppress)) { request.cancel() }
                    .keyboardShortcut(.cancelAction)
                // One primary button beside it. «Переводить без правок» is indistinguishable
                // from «Перевести» before any edit and silently discards work after one.
                // `.borderedProminent` explicitly, and not left to `.defaultAction` to
                // imply it. The drawing gives this button the same blue fill the window's
                // «Перевести» has, and whether the default-action shortcut alone produces
                // that fill for a plain `Button` in a custom sheet is not something this
                // environment can render and check. Stating the style costs one line and
                // does not depend on the answer.
                Button {
                    request.proceed()
                } label: {
                    // On the `Text` and not on the `Button`: the latter is ignored by this
                    // style. `AccentLabel` carries the measurement and the reason.
                    Text("Перевести").foregroundStyle(PrimaryButtonColour.label)
                }
                .buttonStyle(.borderedProminent)
                .tint(PrimaryButtonColour.fill)
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

    /// The language every «перевод» cell is keyed by — the engine's answer, carried on the
    /// draft. Never the window's own last target: this sheet may belong to the queue or to
    /// the hotkey panel, and re-deriving it from the window's last outcome answers about a
    /// different document.
    private var target: Language { request.draft.target }

    /// Writes through into the request's own entries, keyed by the target language, the
    /// same way `SettingsGlossaryView.entryBinding` writes into a glossary row.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { request.entries[index].translations[target.rawValue] ?? "" },
            set: { request.entries[index].translations[target.rawValue] = $0 })
    }
}
