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
    /// Why the main window would refuse this run right now, straight from the type that
    /// decides it — not a restatement of its rule. `nil` means the hand-off would go through.
    ///
    /// Asked rather than re-derived because the button needs two answers from one rule:
    /// whether to be available, and what to say when it is not. A view that computed its own
    /// version would keep offering a button for any refusal added later, and would explain
    /// it with whichever reason it happened to know about.
    var adoptionRefusal: AdoptionRefusal?
    var onCopy: () -> Void = {}
    var onOpenInWindow: () -> Void = {}
    var onRetry: () -> Void = {}
    var onGrantPermission: () -> Void = {}
    /// Whether the content must scroll — `PanelSizer` decided the content is taller than
    /// the panel it can be given. Wrapping the *whole* content and not just the text,
    /// because the ceiling applies to the sum: a long translation with a long document
    /// glossary can put the button row off the bottom on its own.
    var scrolls = false
    var onClose: () -> Void = {}
    /// Whether this view is the one *installed* in the panel, as opposed to the copy
    /// `PanelController` keeps only to measure. Defaults to the installed behaviour, so no
    /// call site that does not know about measuring can be surprised by it.
    ///
    /// The one thing it governs is the fill frame below, and the difference is not cosmetic.
    /// Measured through the same two `sizeThatFits` calls the controller makes: with the fill
    /// frame, this view answers `greatestFiniteMagnitude` on **both** axes to an unbounded
    /// proposal, and `400 × greatestFiniteMagnitude` to a 400pt-wide one — the same answer for
    /// a one-word translation and a forty-sentence one. That number is finite and positive, so
    /// `PanelSizer` reads it as a real measurement rather than as «no idea»: every panel would
    /// come out `maxWidth` × the height ceiling, `scrolls` would always be true, and
    /// `applyFit`'s `guard fit.size != panel.frame.size` would then return early on every
    /// token, so the panel would never resize at all.
    var fillsPanel = true

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .padding(14)
        // Fills the window so the material paints all the way to its edge — which still
        // matters, because a panel the user has dragged larger than its content would
        // otherwise carry a transparent border. Dropped for the measured copy, where
        // accepting the whole proposal is the difference between a measurement and an echo
        // of the question. See `fillsPanel` above.
        .frame(maxWidth: fillsPanel ? .infinity : nil,
               maxHeight: fillsPanel ? .infinity : nil,
               alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The panel's content at its natural size, with nothing that compresses.
    ///
    /// **Nothing in here may be a `ScrollView`, and that is a measurement, not taste.** The
    /// controller sizes the panel by measuring this view, and a `ScrollView` compresses to
    /// nothing when measured: before `hosting.sizingOptions = []` existed, the panel opened
    /// at 380 × 120 on the running bundle no matter what was in it, because AppKit shrank
    /// the window to the hosting view's compressed measurement. The flag above is how
    /// scrolling is reached instead — outside the thing being measured.
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Exhaustive with no `default:` on purpose: a fourth `SelectionResult` case
            // should fail to compile here rather than open an empty panel.
            switch selection {
            case .notPermitted: permissionPrompt
            case .empty: emptyHint
            case .text: translation
            }
        }
    }

    /// The direction line and the way out.
    ///
    /// The ⨯ is here rather than in the window chrome because Task 4 drops `.titled` from
    /// the style mask to get a rounded, material panel, and `standardWindowButton(.closeButton)`
    /// returns nil without it.
    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let line = Self.direction(outcome: model.outcome, target: model.resolvedTarget) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Закрыть")
        }
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
            header
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
        VStack(alignment: .leading, spacing: 8) {
            header
            Label("Выделите текст и нажмите сочетание ещё раз", systemImage: "text.cursor")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(model.translatedText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A `Text` given less width than it wants truncates rather than wrapping,
                // and the panel's width is now measured from this view — so without this
                // the measurement and the rendering disagree about how many lines there are.
                .fixedSize(horizontal: false, vertical: true)

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
                // `problem:` and `onMute:` are deliberately not passed. Muting a term is a
                // decision about the glossary, and the glossary is not on screen here; the
                // window is where that belongs.
                // Gated on `hasContent`, not merely on `outcome` being present. A short clean
                // translation has no diffs, no missing terms and no document glossary, so
                // `WarningsView` draws an empty `VStack` — and the sizer measures whatever is
                // here, so an empty stack would still add its `VStack` spacing to a height
                // nothing is asking for. The 120pt slot this used to fill is gone — `scrolls`
                // and `PanelSizer` own the ceiling now — and this gate exists only so an empty
                // stack does not pad a measured height.
                let warnings = WarningsView(outcome: outcome, target: model.resolvedTarget)
                if warnings.hasContent {
                    warnings
                }
            }

            HStack {
                // Enabled the moment the first token lands, not only at the end: a run the
                // user interrupts leaves partial output that spec 8 says must be kept, and
                // keeping it while refusing to copy it would be pointless.
                Button("Скопировать", action: onCopy)
                    .disabled(model.translatedText.isEmpty)
                // One condition, and it is the window's own answer. Whatever
                // `adoptionRefusal` covers, this button covers — including refusals added
                // after this line was written, which is the whole point of asking rather
                // than restating.
                Button("Открыть в окне", action: onOpenInWindow)
                    .disabled(adoptionRefusal != nil)
                Spacer()
                if model.state == .running {
                    // ⌘. is the macOS convention for cancelling an operation in progress,
                    // and Esc is taken: the panel gives it to «close and cancel».
                    Button("Отмена") { model.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }

            // Only `targetBusy` gets words. `sourceBusy` means this panel's own run is still
            // going, which the spinner and «Отмена» beside it already say; `sameModel` is not
            // reachable from here. A greyed-out button with no explanation is fine when the
            // reason is on screen, and not fine when it is in another window.
            if adoptionRefusal == .targetBusy {
                Text("Окно занято своим переводом — дождитесь его окончания.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
