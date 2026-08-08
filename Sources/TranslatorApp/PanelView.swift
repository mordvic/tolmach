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
    /// `CaseIterable` for the tests, and deliberately: `everyStatusThatIsNotProgress…`
    /// claims to count over **every** kind, and with a hand-written array it silently did
    /// not — `.awaitingUser` was added to this enum and never to that list, so the one case
    /// whose glyph rule is least obvious was the one nothing checked.
    enum Kind: Equatable, CaseIterable {
        case progress, awaitingUser, interrupted, failure

        /// Whether this row's state means *the machine* is working.
        ///
        /// Only `.progress` does. `.awaitingUser` is the run held open on a person — the
        /// terms sheet is up on the main window and the model is idle — and a spinner
        /// beside «Жду ваших правок…» would say the opposite of the words next to it. That
        /// contradiction is exactly the defect this case was added to remove: the panel
        /// stays on screen behind the escalated sheet, and it used to keep claiming
        /// «Перевожу…» while nothing was being translated.
        var showsSpinner: Bool { self == .progress }

        /// The glyph that says what `colour(of:)` says, for everyone who does not see colour.
        ///
        /// This row was the one place in the app where state was carried by hue alone —
        /// `.orange` for an interrupted run against `.red` for a failed one, with nothing else
        /// to tell them apart. Every other status in the program already pairs its colour with
        /// a symbol: «Основные» draws `checkmark.circle` beside «предоставлен» and
        /// `exclamationmark.triangle.fill` beside «нет доступа», and `SettingsNote` does the
        /// same for its warnings and errors. The two symbols here are deliberately the ones
        /// those panes already use, so a user meets one vocabulary rather than two.
        ///
        /// Nil for `.progress` on purpose: that row already carries a `ProgressView`, and a
        /// spinner beside a glyph beside a word is three ways of saying «идёт перевод».
        ///
        /// All three are SF Symbols 1 (macOS 11), so they need no `#available` at this
        /// floor. A name that does not resolve renders as an empty image rather than
        /// trapping, which is why `square.and.pencil` reaching a screen is owed a look in
        /// `docs/OPEN-ITEMS.md` rather than provable here.
        var symbol: String? {
            switch self {
            case .progress: nil
            // The row has no spinner in this state, so unlike `.progress` there is nothing
            // else in it carrying the meaning — and «жду вас» told by wording alone is the
            // same colour-only failure the two symbols below were added to fix.
            case .awaitingUser: "square.and.pencil"
            case .interrupted: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            }
        }
    }
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
    /// Whether the content must scroll — `PanelSizer` decided the content is taller than the
    /// panel it can be given. It wraps only the rows whose height the content decides; the
    /// header and the button row are pinned outside it. See `scrollingMiddle`.
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

    /// «Уменьшение прозрачности» in «Универсальный доступ» → «Дисплей».
    ///
    /// The panel is the one surface in this app that genuinely samples what is behind it: it
    /// floats over the document the user is reading, and `.regularMaterial` blurs that document
    /// under their translation. That is precisely the effect the setting exists to switch off,
    /// and until now the panel ignored it — while `applyFit` has honoured «Уменьшение движения»
    /// since it started animating, so the app was already asking the system about one of these
    /// two and not the other.
    ///
    /// Read from the environment rather than from
    /// `NSWorkspace.accessibilityDisplayShouldReduceTransparency`, so SwiftUI re-renders when
    /// the user changes it; the AppKit property publishes a notification nothing here observes.
    /// Both spellings were checked to exist at this project's macOS 14 floor by typechecking
    /// them at `-target arm64-apple-macosx14.0`.
    ///
    /// It cannot disturb the sizing, which is the one thing about this view that is delicate:
    /// a background changes no proposal and no ideal size, and `PanelController` measures a
    /// detached copy that reads the same environment. If that copy ever read `false` while the
    /// installed one read `true`, the two would still measure identically.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
        .padding(14)
        // Fills the window so the material paints all the way to its edge — which still
        // matters, because a panel the user has dragged larger than its content would
        // otherwise carry a transparent border. Dropped for the measured copy, where
        // accepting the whole proposal is the difference between a measurement and an echo
        // of the question. See `fillsPanel` above.
        .frame(maxWidth: fillsPanel ? .infinity : nil,
               maxHeight: fillsPanel ? .infinity : nil,
               alignment: .topLeading)
        // The shape stays whatever the transparency setting is: `TranslationPanel` turns the
        // window's own background off (`isOpaque = false`, `backgroundColor = .clear`) so that
        // this clip is what draws the corner, and an opaque fill clipped to the same rectangle
        // keeps that working. `windowBackgroundColor` rather than a literal, so light and dark
        // both come out right without this view knowing which it is in.
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // `.contain` and not `.combine`: the panel holds a translation, a status line and up to
        // three buttons, and combining them would flatten all of that into one unreadable
        // label. `.contain` names the group and leaves every child reachable, which is what
        // this window needs — it has no title bar to carry a name, because `TranslationPanel`
        // hides it so the content can draw there.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Толмач — перевод выделенного текста")
    }

    private var background: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(.regularMaterial)
    }

    /// The panel's content at its natural size.
    ///
    /// **The measured variant must reach this with `scrolls == false`, and that is a
    /// measurement, not taste** — see `PanelContentVariant.scrolls`, which carries the
    /// numbers. A `ScrollView` does not compress under measurement, it is greedy: it answers
    /// the whole unbounded height proposal, `PanelSizer` reads that as a real measurement and
    /// clamps it to the ceiling, and every panel comes out 0.6 × the screen and scrolling.
    ///
    /// Scrolling is reached through `scrollingMiddle` below, which wraps only the rows whose
    /// height the content decides. The pinned rows around it keep their own heights, so the
    /// flat layout the controller measures still sums to something real.
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

    /// The one region that scrolls, and the reason it is only this region.
    ///
    /// An earlier version wrapped the *whole* content, justified by an observation that was
    /// correct: the ceiling applies to the sum, so a long translation with a long document
    /// glossary can put the button row off the bottom on its own. Scrolling everything answers
    /// that by making the row reachable **by** scrolling — at the cost of making it
    /// unreachable **without** scrolling, always, along with the ⨯ and, worst of all,
    /// «Отмена»: a run at the ceiling pushed its own stop button further out of reach with
    /// every arriving token.
    ///
    /// Pinning the row answers the same observation outright instead. A document glossary of
    /// any length cannot push the buttons anywhere, because the buttons are no longer in the
    /// flow the glossary grows in.
    ///
    /// The two variants do **not** produce the same ideal height, and it would be wrong to
    /// require that they did: measured, the flat one answers 368 at a 400pt width and the
    /// scrolling one answers `greatestFiniteMagnitude`, because a `ScrollView` takes whatever
    /// it is offered. What makes the sizing sound is narrower — `PanelContentVariant.measured`
    /// reports `scrolls == false`, so the flat layout is always the one measured. That case is
    /// pinned by three existing tests; mutating it to `true` puts every panel at the ceiling,
    /// short and long alike, and all three fail.
    @ViewBuilder private func scrollingMiddle<Content: View>(
        @ViewBuilder _ middle: () -> Content) -> some View {
        if scrolls {
            ScrollView { middle() }
        } else {
            middle()
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
                // Measured on the running bundle at the 380pt the panel was fixed at then —
                // it is sized to its content now, so the width is no longer that number, but
                // `PanelSizer.minWidth` is 300 and the sentence is longer than either: this
                // rendered as
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
            // Pinned, outside the scroll. The ⨯ is the only way to close this panel with a
            // mouse — dropping `.titled` from the style mask took the standard close button
            // with it — so a header that scrolled away left a long translation with no mouse
            // exit at all.
            header

            // Everything whose height the content decides goes in one scrolling region, so
            // exactly one thing moves. Two scroll views in a panel this size would be worse
            // than the defect this replaces.
            scrollingMiddle {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.translatedText)
                        .textSelection(.enabled)
                        // Without this the text is a live region VoiceOver has no warning
                        // about: it is rewritten on every streamed token, up to ten times a
                        // second, and an assistive technology that re-reads a changed label
                        // would talk over itself for the whole of a run. The trait is the
                        // documented way to say «this changes often, do not follow it» — the
                        // settle is announced once instead, by `announcement(for:)`.
                        .accessibilityAddTraits(.updatesFrequently)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A `Text` given less width than it wants truncates rather than wrapping,
                        // and the panel's width is now measured from this view — so without this
                        // the measurement and the rendering disagree about how many lines there are.
                        .fixedSize(horizontal: false, vertical: true)

                    statusLine
                    termsNotice

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
                        // `onMute:` is deliberately not passed. Muting a term is a
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Pinned, and «Отмена» below is why this matters most: it exists only while a run
            // is in flight, which is exactly when the text above it is still growing. In the
            // scrolling flow it was pushed further out of reach by every token it was there
            // to stop.
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
    /// Rendered without them, in a real `NSHostingView` at the 380pt the panel was fixed at
    /// when this was taken — it is sized to its content now, and `PanelSizer.minWidth` is
    /// narrower still, so the squeeze this describes has not gone away —
    /// «Ollama не запущена. Запустите её командой «ollama serve».» came out as «…командой
    /// «oll…»: an `HStack` splits its width between a `Text` and a `Button`, and a `Text`
    /// that is short of room truncates to one line rather than wrapping. The clipped half
    /// is the half that says what to do — so the panel would offer a «Повторить» that
    /// retries the same failure while hiding the fix. `fixedSize(vertical:)` makes the text
    /// grow downwards instead, and the `Spacer` keeps the button pinned right rather than
    /// letting it drift in against a wrapped message.
    /// §6.6 in the panel. The window says this in its status bar and every queue row says
    /// it too; the hotkey path said nothing at all — which is the exact silence the flag
    /// exists to remove, and «Файлы» settings promise the gate works «и по сочетанию
    /// клавиш».
    @ViewBuilder private var termsNotice: some View {
        if model.documentTermsUnavailable, model.state == .finished {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(StatusColour.warning)
                    .accessibilityHidden(true)
                Text("Термины документа не удалось подготовить")
                    .font(.caption).foregroundStyle(StatusColour.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let status = Self.status(for: model.state, awaitingTerms: model.isAwaitingTerms) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if status.kind.showsSpinner { ProgressView().controlSize(.small) }
                if let symbol = status.kind.symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(colour(of: status.kind))
                        // The word beside it already says what happened; a screen reader
                        // hearing the symbol's English name as well would be told twice, in
                        // two languages.
                        .accessibilityHidden(true)
                }
                Text(status.message).font(.caption).foregroundStyle(colour(of: status.kind))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if status.offersRetry {
                    // Small for the same reason the window's «Повторить» is, and it has to
                    // stay in step with it: the drawing gives both 19 pt against the 22 of
                    // «Скопировать» and «Открыть в окне» directly below, and here that
                    // difference is doing work — it is what keeps the failure's own retry
                    // from reading as a third button of the panel's action row.
                    Button("Повторить", action: onRetry).font(.caption).controlSize(.small)
                }
            }
        }
    }

    private func colour(of kind: PanelStatus.Kind) -> Color {
        switch kind {
        case .progress, .awaitingUser: .secondary
        case .interrupted: StatusColour.warning
        case .failure: StatusColour.failure
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
    ///
    /// `nonisolated`, like `status(for:)` below, and for a reason the Swift 6 language mode
    /// made visible rather than one of taste. `PanelView` is a `View`, so everything on it —
    /// including a `static func` over two value parameters — is inferred `@MainActor`, and a
    /// synchronous test calling it from a nonisolated context is «call to main actor-isolated
    /// static method … in a synchronous nonisolated context»: the one warning left standing
    /// after this target reached `-swift-version 6`. Both functions are pure over
    /// `Sendable` values and touch no view state, so the isolation was never true of them;
    /// declaring that is better than making the tests `@MainActor` to satisfy an inference
    /// that describes nothing.
    nonisolated static func direction(outcome: TranslationOutcome?, target: Language?) -> String? {
        guard let outcome, let target else { return nil }
        return RussianCopy.direction(from: outcome.detectedSource, to: target)
    }

    /// What VoiceOver is told when a run settles, or nil when there is nothing to say.
    ///
    /// The panel is the surface this matters most on and the one that had least of it. It is
    /// summoned by a shortcut, it never takes the application into the foreground, and it
    /// appears next to the pointer rather than where focus was — so a user who does not see it
    /// gets no indication that anything happened at all. Everything else in this app is
    /// reached by clicking something, which announces itself.
    ///
    /// A value rather than a call to `AccessibilityNotification` inline, for the same reason
    /// `status(for:)` is a value: which states speak, and what they say, is a decision, and a
    /// decision buried in a view modifier can only be read. `.running` is deliberately silent —
    /// the run has only just started and the user pressed the key themselves — and so is
    /// `.idle`, which is not a settle.
    ///
    /// Exhaustive with no `default:` for the same reason as everything else here.
    nonisolated static func announcement(for state: TranslationState) -> String? {
        switch state {
        case .idle, .running: nil
        case .finished: "Перевод готов"
        case .interrupted: "Перевод прерван, показана пришедшая часть"
        // The view model has already put this into Russian and it carries the only
        // instruction the user gets — the same reasoning as `status(for:)`'s failure case.
        case .failed(let message): message
        }
    }

    /// Exhaustive with no `default:` on purpose: a sixth `TranslationState` case should
    /// fail to compile here instead of leaving the panel silent about a state it has no
    /// words for.
    ///
    /// `nonisolated` for the reason given on `direction(outcome:target:)` above.
    /// - Parameter awaitingTerms: whether the run is suspended on the «Термины документа»
    ///   sheet. A parameter rather than a fifth `TranslationState`, because it is not a
    ///   state the run *reaches* — it is a thing happening inside `.running`, and adding a
    ///   case would make every other switch over `TranslationState` in this app answer a
    ///   question it has no business answering.
    nonisolated static func status(for state: TranslationState,
                                   awaitingTerms: Bool = false) -> PanelStatus? {
        switch state {
        case .idle, .finished:
            // Nothing to add. The panel opens on a translation and closes on Esc; a caption
            // saying so would be a line of chrome over a result the user is trying to read.
            return nil
        case .running:
            // The escalated sheet is on the main window, in front; this panel is behind it
            // and the model is idle. Saying «Перевожу…» here contradicts the table asking
            // for the user's attention two windows up.
            if awaitingTerms {
                return PanelStatus(kind: .awaitingUser, message: "Жду ваших правок…",
                                   offersRetry: false)
            }
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
