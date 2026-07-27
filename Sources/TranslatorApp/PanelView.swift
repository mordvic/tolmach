// Sources/TranslatorApp/PanelView.swift
import SwiftUI
import TranslationCore
import TextCapture

/// The status row's contents, as a value rather than as a view.
///
/// Extracted for one reason: *which* state offers «Повторить» and *whether* the view
/// model's own Russian survives the trip to the screen are decisions, and spec 8 pins both.
/// A `@ViewBuilder` switch can only be read; this can be checked.
struct PanelStatus: Equatable {
    enum Kind: Equatable { case progress, interrupted, failure }
    let kind: Kind
    let message: String
    let offersRetry: Bool
}

struct PanelView: View {
    let model: TranslationViewModel
    let selection: SelectionResult
    var onCopy: () -> Void = {}
    var onOpenInWindow: () -> Void = {}
    var onRetry: () -> Void = {}
    var onGrantPermission: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Exhaustive with no `default:` on purpose: a fourth `SelectionResult` case
            // should fail to compile here rather than open an empty panel.
            switch selection {
            case .notPermitted: permissionPrompt
            case .empty: emptyHint
            case .text: translation
            }
        }
        .padding(14)
        // `maxHeight` and `.topLeading` because the panel is a fixed 380×260 and short
        // content would otherwise float in the middle of it — the hint is one line, and it
        // hung level with nothing. Slack goes to the bottom, where it reads as a panel with
        // room left rather than as a mis-centred one.
        .frame(minWidth: 340, maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Spec 8's «нет разрешения Accessibility» row, shown at the moment the user pressed
    /// the key rather than at launch — which is when they are actually asking for it.
    ///
    /// The full path is spelled out because the permission does not live where its name
    /// suggests: it is under «Конфиденциальность и безопасность», not under the
    /// «Универсальный доступ» pane of the same name that holds the accessibility features.
    /// A user sent to the wrong one finds nothing and concludes the app is broken.
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Нет доступа к тексту в других программах", systemImage: "lock")
                .font(.headline)
            Text("Чтобы переводить выделенное по сочетанию клавиш, приложению нужен доступ "
                 + "в разделе «Конфиденциальность и безопасность» → «Универсальный доступ». "
                 + "Главное окно работает и без него.")
                .font(.caption).foregroundStyle(.secondary)
                // Same defect Task 9 found on the status row, in the place it does the most
                // damage — and it took the first live run to see it, because Task 9's
                // `ImageRenderer` check measured the view at its *ideal* height, where the
                // sentence wraps happily. In the shipped panel it does not: the real
                // `NSHostingView` sizes the window to what the content will compress to, and
                // a `Text` given less height than it wants truncates rather than wrapping.
                // Measured on the running bundle at the panel's own 380pt: this rendered as
                // «Чтобы переводить выделенное по сочетанию клавиш, приложению…», i.e. the
                // whole of *where the setting actually lives* was cut — from the one screen
                // every new user sees before anything else works.
                .fixedSize(horizontal: false, vertical: true)
            Button("Открыть настройки системы", action: onGrantPermission)
        }
    }

    private var emptyHint: some View {
        Label("Выделите текст и нажмите сочетание ещё раз", systemImage: "text.cursor")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = Self.direction(outcome: model.outcome, target: model.resolvedTarget) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                Text(model.translatedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            statusLine

            // Gated on `outcome`, not on `state == .finished`, and the header above is
            // gated the same way — because `TranslationViewModel` drops `outcome` at the
            // exact instant it clears `translatedText`, so "there is an outcome" means
            // "this outcome describes the text in the pane" and nothing weaker. One
            // condition governs everything derived from the run, so the header, the
            // warnings and the text can never disagree about which run they belong to.
            //
            // The visible difference from a `.finished` gate is a run that fails without
            // producing output — Ollama down, an empty reply — where spec 8 requires the
            // previous translation to stay on screen. It keeps its own header and warnings,
            // with the failure and its «Повторить» underneath, instead of a labelled
            // paragraph losing its annotations for a reason that has nothing to do with it.
            if let outcome = model.outcome {
                // `WarningsView` has no natural ceiling — `documentGlossary` is one row per
                // extracted term — and this panel floats over the user's work, so it cannot
                // take the whole screen. `ViewThatFits` rather than a bare `ScrollView`,
                // which is greedy in its scroll axis and would sit at the full 120 under a
                // one-line warning. Same reasoning as `MainWindowView`, smaller budget.
                //
                // `problem:` and `onMute:` are deliberately not passed. Muting a term is a
                // decision about the glossary, and the glossary is not on screen here; the
                // window is where that belongs.
                ViewThatFits(in: .vertical) {
                    WarningsView(outcome: outcome, target: model.resolvedTarget)
                    ScrollView { WarningsView(outcome: outcome, target: model.resolvedTarget) }
                }
                .frame(maxHeight: 120)
            }

            HStack {
                // Enabled the moment the first token lands, not only at the end: a run the
                // user interrupts leaves partial output that spec 8 says must be kept, and
                // keeping it while refusing to copy it would be pointless.
                Button("Скопировать", action: onCopy)
                    .disabled(model.translatedText.isEmpty)
                Button("Открыть в окне", action: onOpenInWindow)
                Spacer()
                if model.state == .running {
                    // ⌘. is the macOS convention for cancelling an operation in progress,
                    // and Esc is taken: the panel gives it to «close and cancel».
                    Button("Отмена") { model.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }
        }
    }

    /// `fixedSize(horizontal: false, vertical: true)` and the `Spacer` are not tidiness.
    ///
    /// Rendered without them, in a real `NSHostingView` at the panel's own 380pt width,
    /// «Ollama не запущена. Запустите её командой «ollama serve».» came out as «…командой
    /// «oll…»: an `HStack` splits its width between a `Text` and a `Button`, and a `Text`
    /// that is short of room truncates to one line rather than wrapping. The clipped half
    /// is the half that says what to do — so the panel would offer a «Повторить» that
    /// retries the same failure while hiding the fix. `fixedSize(vertical:)` makes the text
    /// grow downwards instead, and the `Spacer` keeps the button pinned right rather than
    /// letting it drift in against a wrapped message.
    @ViewBuilder private var statusLine: some View {
        if let status = Self.status(for: model.state) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if status.kind == .progress { ProgressView().controlSize(.small) }
                Text(status.message).font(.caption).foregroundStyle(colour(of: status.kind))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if status.offersRetry {
                    Button("Повторить", action: onRetry).font(.caption)
                }
            }
        }
    }

    private func colour(of kind: PanelStatus.Kind) -> Color {
        switch kind {
        case .progress: .secondary
        case .interrupted: .orange
        case .failure: .red
        }
    }

    // MARK: - The decisions

    /// Spec 7.2's «определённое направление перевода», or nothing at all.
    ///
    /// Takes the whole `outcome` rather than just its `detectedSource`, because the
    /// *presence* of the outcome is the load-bearing half: `TranslationViewModel` assigns
    /// `resolvedTarget` and `outcome` together at the end of a run and then clears only
    /// `outcome` when the next run's first token arrives. Between those two moments
    /// `resolvedTarget` is a whole run out of date, so a header built from it alone reads
    /// «язык не определён → русский» over text on its way to English. Nil is the honest
    /// answer for that window, and `theHeaderIsWithheldWhileTheNextRunReplacesTheTextInThePane`
    /// is the measurement.
    ///
    /// `target` stays optional so the caller can hand over both of the model's values
    /// as-is; it is nil only before the first run of the app's life, when `outcome` is nil
    /// too.
    static func direction(outcome: TranslationOutcome?, target: Language?) -> String? {
        guard let outcome, let target else { return nil }
        return RussianCopy.direction(from: outcome.detectedSource, to: target)
    }

    /// Exhaustive with no `default:` on purpose: a sixth `TranslationState` case should
    /// fail to compile here instead of leaving the panel silent about a state it has no
    /// words for.
    static func status(for state: TranslationState) -> PanelStatus? {
        switch state {
        case .idle, .finished:
            // Nothing to add. The panel opens on a translation and closes on Esc; a caption
            // saying so would be a line of chrome over a result the user is trying to read.
            return nil
        case .running:
            return PanelStatus(kind: .progress, message: "Перевожу…", offersRetry: false)
        case .interrupted:
            return PanelStatus(kind: .interrupted,
                               message: "Перевод прерван — показана та часть, что успела прийти",
                               offersRetry: false)
        case .failed(let message):
            // Spec 8: a failure offers a retry rather than only an explanation. The message
            // is passed through untouched — `TranslationViewModel.message(for:)` has already
            // put it into Russian, and it carries the only instruction the user gets.
            return PanelStatus(kind: .failure, message: message, offersRetry: true)
        }
    }
}
