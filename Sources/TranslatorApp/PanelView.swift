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
        case progress, awaitingUser, formatting, interrupted, failure

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
        /// `docs/reference/OPEN-ITEMS.md` rather than provable here.
        var symbol: String? {
            switch self {
            case .progress: nil
            // The row has no spinner in this state, so unlike `.progress` there is nothing
            // else in it carrying the meaning — and «жду вас» told by wording alone is the
            // same colour-only failure the two symbols below were added to fix.
            case .awaitingUser: "square.and.pencil"
            // Same rule: no spinner in this state (the machine is working, but on a text
            // that is about to be replaced, and «Перевожу…» with a spinner over it read as a
            // stall), so the glyph is what carries the meaning.
            case .formatting: "text.alignleft"
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
    /// «Заменить»'s dedicated shortcut — issue #27. Pulled out to a named value, rather than
    /// written inline on the button's `.keyboardShortcut(...)` call, because this project
    /// carries no view-inspection dependency (the closed framework whitelist has none) and so
    /// has no way to assert what a rendered button's modifier actually is. Pinning the value
    /// here at least catches an accidental change to the combination itself; the button
    /// reading it live is what a screen still has to confirm — see `docs/reference/OPEN-ITEMS.md`.
    static let replaceShortcut = KeyboardShortcut(.return, modifiers: [.command, .shift])

    let model: TranslationViewModel
    let selection: SelectionResult
    /// Whether a press has been captured and its translation has not started yet — the window
    /// `PanelController.show(at:)` measures in. `HotkeyCoordinator.isStartingRun` is the only
    /// thing that knows, because nothing about the model does: `translate()` has not run, so
    /// the state and the pane still describe the previous press.
    ///
    /// Defaults to false so a call site that does not know about it measures the model alone.
    var awaitingRun = false
    /// Why the main window would refuse this run right now, straight from the type that
    /// decides it — not a restatement of its rule. `nil` means the hand-off would go through.
    ///
    /// Asked rather than re-derived because the button needs two answers from one rule:
    /// whether to be available, and what to say when it is not. A view that computed its own
    /// version would keep offering a button for any refusal added later, and would explain
    /// it with whichever reason it happened to know about.
    var adoptionRefusal: AdoptionRefusal?
    var onCopy: () -> Void = {}
    /// «Заменить» — issue #27. Writes the finished result back into the source application in
    /// place of the captured selection. Gated the same way «Скопировать» is on non-empty text,
    /// plus `model.state == .finished`: unlike «Скопировать», which is deliberately available
    /// the moment the first token lands so an interrupted run's partial output is not stranded,
    /// «Заменить» must never write a half-streamed answer into another application.
    var onReplace: () -> Void = {}
    /// Whether the application in front of the panel right now is a known terminal emulator —
    /// issue #29. Asked, not re-derived here, for the same reason `adoptionRefusal` is: the
    /// decision (`TerminalBlocklist`) lives with `HotkeyCoordinator`, which is what
    /// `replaceInSource()` re-checks it against too.
    var frontmostIsTerminal = false
    var onOpenInWindow: () -> Void = {}
    var onRetry: () -> Void = {}
    var onGrantPermission: () -> Void = {}
    /// Opens the settings window on «Модели». The panel's counterpart to the window's
    /// «выберите модель» line: there is no picker next to the pointer, so the way out is
    /// offered rather than described.
    var onOpenSettings: () -> Void = {}
    /// Set when the press could not translate because no model is chosen — see
    /// `HotkeyCoordinator.needsModelChoice`.
    var needsModelChoice = false
    /// The header's «Перевод | Правка» switch. Re-runs the captured selection under the
    /// chosen operation rather than reading a new one — see
    /// `HotkeyCoordinator.switchOperation(to:)`.
    var onSwitchOperation: (TextOperation) -> Void = { _ in }
    /// «Ещё вариант», offered only for a finished правка whose степень allowed wording
    /// to move — never «только ошибки» (`model.offersAnotherVariant`).
    var onAnotherVariant: () -> Void = {}
    /// The степень and стиль the next правка will use — the *settings*, passed in rather than
    /// read here, because this view is a readout: `HotkeyCoordinator` owns every decision a
    /// press makes, and writing a setting is one of them.
    ///
    /// Defaulted for the reason `awaitingRun` is: a call site that knows nothing about правка
    /// draws no row at all — `showsProofreadingControls` gates on the operation — so the
    /// values it would have passed are never rendered.
    var proofreadingLevel: ProofreadingLevel = .errorsOnly
    var rewriteStyle: RewriteStyle = .original
    var onProofreadingLevelChange: (ProofreadingLevel) -> Void = { _ in }
    var onRewriteStyleChange: (RewriteStyle) -> Void = { _ in }
    /// «Шрифт текста» — the face and size the *reply* is drawn in. Nothing else in this view
    /// takes it: the header, the степень/стиль row, the status line, the warnings and the
    /// buttons all keep the system's size, which is what keeps `PanelSizer`'s floors
    /// (`minHeight` 132, `dragMinHeight` 164 — both measurements of the pinned block) true at
    /// every setting. See `docs/adr/0008`.
    ///
    /// **Two `Text`s take it, and that pairing is load-bearing.** The visible one and the
    /// hidden reservation below it are laid out in the same font or the reservation stops
    /// predicting the reply's height — which is the whole of its job, and «кнопки прыгают» is
    /// what it looks like when it fails.
    ///
    /// It must also arrive through `PanelHost`, i.e. be read inside a body, for the reason
    /// `proofreadingLevel` is: `PanelController` builds *two* hosts from one builder and sizes
    /// the panel from the detached one. A font applied only to the installed copy would leave
    /// every panel measured at the previous size.
    var font: ContentFont = .default
    /// Whether the reply is drawn as a *document* rather than as characters — the panel's whole
    /// of Phase 4, and true only after a run has settled.
    ///
    /// A value and not a rule evaluated here, for the reason `scrolls` is one: the panel's size
    /// comes from a second, detached host, and the *controller* is what holds the one answer
    /// both hosts are built with (`PanelController.setRendersFinalReply(_:)`). Two copies of the
    /// view deciding for themselves is how the panel comes to be sized for one thing and to draw
    /// another. The rule itself is `PanelView.rendersFinalReply(state:awaitingRun:text:
    /// showsRenderedMarkup:)`, which is a value with a test.
    ///
    /// Defaults to false, so every call site that predates this — and every test that pins the
    /// streaming panel — measures and draws exactly what it did before.
    var rendersFinalReply = false
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

    /// As much of the selection as can still change the answer, and no more.
    ///
    /// **Measured on the running panel**, showing it with a selection of each length and
    /// timing `show(at:)`. The height stops moving long before the cost does:
    ///
    ///        500 chars → 560 × 214,  15.7 ms
    ///      2 000 chars → 560 × 582,  11.6 ms
    ///      8 000 chars → 560 × 998,  29.3 ms   ← already the 0.6-of-screen ceiling (997)
    ///     16 000 chars → 560 × 998,  43.1 ms
    ///    200 000 chars → 560 × 998, 419.3 ms
    ///
    /// Past the ceiling every further character is laid out to produce the same number, and
    /// pays for it on the main actor at the one moment the panel is supposed to appear: 419 ms
    /// for a selection of a few pages, which is most of half a second of nothing on screen
    /// after the shortcut. The cap is what makes the cost of reserving bounded while leaving
    /// the answer identical — 16 000 is twice the length that already reached this display's
    /// ceiling, so it holds on a much taller one too.
    ///
    /// A cut mid-word does not matter: this copy is never drawn, only measured.
    ///
    /// **The cap moves with «Шрифт текста», and the figures above are the 13 pt column of it.**
    /// The argument for 16 000 was «twice the length that already reached this display's
    /// ceiling» — and that length is a function of the line height, which the setting changes.
    /// Measured by bisection (`Scripts/content-font.swift`, against a 774 pt ceiling): the
    /// reserved height first reaches it at 2 914 characters at 13 pt, 1 032 at 22 and 511 at 32.
    /// `ContentFont.reservationLimit` is the generalisation — it scales by the *square* of the
    /// size, which is what those numbers say, and only ever downwards, because 16 000 is the one
    /// length whose cost was measured — and it carries the one thing that could **not** be
    /// re-measured, that millisecond cost itself.
    static func reservation(for source: String, font: ContentFont) -> String {
        String(source.prefix(font.reservationLimit))
    }

    /// The selection to reserve room for, or nil — **only while the run has not started**.
    ///
    /// This and the status row below were one gate, on the reasoning that they must open and
    /// close together. They must not: the row is on screen for the whole run and the
    /// reservation has one job, done in `PanelController.show(at:)` and finished the moment it
    /// returns. Leaving it in cost the rest of the run dearly — `measure()` runs on every
    /// streamed token, throttled to ten a second, and each pass laid the hidden copy out
    /// again: 29.3 ms for 8 000 characters and 43.1 ms for 16 000, so a multi-page selection
    /// spent 300–430 ms of every second re-measuring an invisible copy of itself on the main
    /// actor. The 16 000-character cap bounds one pass; nothing bounded the number of them.
    ///
    /// Dropping it once the run starts cannot let the panel shrink back: `PanelSizer` is
    /// monotonic in both axes outside the settle, so the size the reservation won at
    /// `show(at:)` is kept without it being re-measured to justify it.
    ///
    /// **`scrolls` is not consulted, and the clause that read it was dead where it mattered.**
    /// It said `!scrolls` — «stop reserving once the panel is at its ceiling, where the
    /// reservation buys nothing and becomes blank scroll extent the reader can drag past the
    /// arriving reply». But the only copy whose size decides the panel is the `.measured`
    /// variant, and `PanelContentVariant` hard-wires `scrolls` to `false` there, so it could
    /// never be true at the one moment it was asked. `awaitingRun` is itself true only inside
    /// that same synchronous window, so there was no other path for it to govern.
    ///
    /// What it was reaching for is real and is **not** answered elsewhere, which is worth
    /// stating plainly rather than implying `reservationLimit` covers it. Measured on the
    /// panel: a 2 000-character selection opens it at 550 pt, and 8 000, 16 000 and 100 000
    /// all open it at 998 — the 0.6-of-screen ceiling. The cap bounds what the *measurement*
    /// costs, not the height it arrives at.
    ///
    /// That is the reservation working rather than failing: a reply to pages of text will need
    /// that room, and opening there is the alternative to climbing there during the run, which
    /// is the complaint the reservation exists for. What it costs is a panel covering 60% of
    /// the display from its first frame, over the document being read.
    /// `docs/reference/OPEN-ITEMS.md` carries that trade, which is a judgement and not a number.
    ///
    /// **«Шрифт текста» makes that trade arrive sooner, deliberately.** The figures above are
    /// the 13 pt ones. Measured at the same 560 pt width, against a 774 pt ceiling, the reserved
    /// height first reaches it at 2 914 characters at 13 pt, 1 032 at 22 and **511** at 32 — so
    /// on a large setting the panel opens at its ceiling for a selection of two paragraphs.
    /// That is the same judgement, accepted again rather than re-opened.
    private var selectionAwaitingReply: String? {
        guard awaitingRun, case let .text(source) = selection else { return nil }
        return source.plain
    }

    /// Whether the panel should report progress rather than whatever the model's state says.
    ///
    /// Wider than the reservation above, and the difference is the point: this holds for the
    /// whole run, so the row is «Перевожу…» from the first frame to the settle. Sharing the
    /// reservation's gate meant the `!scrolls` clause — added for the scroll extent, which has
    /// nothing to do with status — silently took the row away too, and a selection long enough
    /// to open at the ceiling was drawn carrying the *previous* run's «Ollama не запущена…»
    /// and a «Повторить» that does nothing, over a run already in flight.
    private var awaitingReply: Bool { awaitingRun || model.state == .running }

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
            // Checked before the capture's own outcome, because it outranks it: with no model
            // chosen, what was selected does not matter yet. It is *not* a fourth
            // `SelectionResult` case — that enum belongs to `TextCapture`, which knows nothing
            // about models, and putting an app-layer refusal in it would be the wrong layer.
            if needsModelChoice {
                modelChoicePrompt
            } else {
                // Exhaustive with no `default:` on purpose: a fourth `SelectionResult` case
                // should fail to compile here rather than open an empty panel.
                switch selection {
                case .notPermitted: permissionPrompt
                case .empty: emptyHint
                case .text: translation
                }
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
    /// Pinning the row answers the same observation outright instead. The buttons are no
    /// longer in the flow the glossary grows in.
    ///
    /// **That is a claim about the buttons only, and it once said more than it should.** It
    /// read «a document glossary of any length cannot push the buttons anywhere» — true of the
    /// buttons, and read by a later pass as a promise about the whole bottom of the panel.
    /// This region holds the translation **and** the warnings, and both grow inside it; what
    /// the three sections buy is that neither can move the row below.
    ///
    /// Moving the warnings out into the pinned flow was tried and taken back out: unbounded
    /// there they starve the flexible region instead of pushing the buttons out of it —
    /// measured on a 560 × 540 stack, the translation's clip view came out 438, 365, 215 and
    /// 0 pt tall at 0, 5, 15 and 30 warning rows — and the ceiling that would have answered
    /// that is larger than the panel's own floor. The reasoning sits with the warnings, below.
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
            if let line = Self.direction(outcome: model.outcome, target: model.resolvedTarget,
                                         operation: model.resolvedOperation) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            // Only where there is a captured selection to re-run under the chosen operation.
            // `header` is also drawn by `permissionPrompt` and `emptyHint`, where the switch
            // would have nothing to act on — an inert control drawn over «выделите текст» and
            // the permission prompt.
            if case .text = selection {
                Picker("", selection: Binding(get: { model.operation },
                                              set: { onSwitchOperation($0) })) {
                    ForEach(TextOperation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                .disabled(model.state == .running || awaitingRun)
                .accessibilityLabel("Операция: перевод или правка")
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Закрыть")
        }
    }

    /// Степень and стиль, drawn only for правка.
    ///
    /// **Pinned, beside the header rather than inside `scrollingMiddle`**, for the reason the
    /// header is pinned: the middle region is where the reply and the warnings grow, and a
    /// control that scrolls away with them is one the user cannot reach at the moment they
    /// want it.
    ///
    /// Both are `.menu` pickers rather than a segmented степень: the panel's width floor is
    /// 300 pt and `PanelView` pads by 14 a side, so the row has 272 pt for everything in it,
    /// and «только ошибки» beside «ошибки и стиль» does not fit in that.
    /// `Scripts/panel-proofread-row.swift` carries the measurement.
    @ViewBuilder private var proofreadingControls: some View {
        if Self.showsProofreadingControls(operation: model.operation, selection: selection) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { proofreadingLevel },
                                              set: { onProofreadingLevelChange($0) })) {
                    ForEach(ProofreadingLevel.allCases, id: \.self) {
                        Text($0.russianName).tag($0)
                    }
                }
                .fixedSize()
                .accessibilityLabel("Степень правки")
                Picker("", selection: Binding(get: { rewriteStyle },
                                              set: { onRewriteStyleChange($0) })) {
                    ForEach(RewriteStyle.allCases, id: \.self) {
                        Text($0.russianName).tag($0)
                    }
                }
                .fixedSize()
                // One rule, read from the type. The window's toolbar and the settings pane
                // read the same property; a restated comparison is how two surfaces come to
                // disagree about what is available (правка design §7).
                .disabled(!proofreadingLevel.allowsRewriteStyle)
                .accessibilityLabel("Стиль правки")
                Spacer(minLength: 0)
            }
            .pickerStyle(.menu)
            .controlSize(.mini)
            .labelsHidden()
            // The condition the operation switch already carries: a control that restarts the
            // run must not be live while a run is in flight.
            .disabled(model.state == .running || awaitingRun)
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

    /// Shaped like `permissionPrompt` rather than like a failure: nothing went wrong, the app
    /// is simply not configured yet, and «Повторить» would fail identically every time.
    private var modelChoicePrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text("Модель для перевода не выбрана. Откройте «Модели» в настройках и выберите её.")
                .font(.callout)
                // The same `fixedSize` as the permission prompt, and for the reason recorded
                // there: at the panel's 300 pt floor a sentence this long is cut, and what gets
                // cut is the half that says where to go.
                .fixedSize(horizontal: false, vertical: true)
            Button("Настройки", action: onOpenSettings)
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
            // Pinned with it, and present only for правка — see the property's own comment.
            proofreadingControls

            // The translation and the warnings that describe it, in one scrolling region:
            // they are the two things with no length of their own, and inside here their
            // length costs only itself. Everything below is pinned.
            scrollingMiddle {
                VStack(alignment: .leading, spacing: 8) {
                    // **The room the reply is about to need, taken before it arrives.**
                    //
                    // Measured on the real panel while a run streams, at 560 pt wide: it opens
                    // at the 120 pt floor and gains ~16 pt per sentence — 120 → 198 for a
                    // six-sentence paragraph, in five steps, with the width going 347 → 475 →
                    // 560 on the way. Every one of those steps moves the button row, because
                    // the buttons sit under the text. That is the «кнопки прыгают».
                    //
                    // A bigger floor would fix it by making every short translation open with
                    // a hole under it, since the height is monotonic within a presentation and
                    // would never give the space back. This reserves the right amount instead:
                    // the panel is translating a selection it already holds, and a translation
                    // is about as long as its source. So an invisible copy of the source sets
                    // the floor while the run is in flight, and stops setting it the moment the
                    // run settles.
                    //
                    // It reserves the *width* too, which is the larger win: the width rule in
                    // `PanelSizer.fit` records 4–12 changes per streaming run because no early
                    // moment knows the final width. The source knows it.
                    //
                    // `.hidden()` and not `.opacity(0)`: both keep the space, and only the
                    // first is documented to. `accessibilityHidden` because it is furniture —
                    // VoiceOver reading the source back inside the translation panel would be
                    // the same text twice.
                    ZStack(alignment: .topLeading) {
                        if let source = selectionAwaitingReply {
                            // The reply's font, not the system's. This copy exists to be the
                            // size the reply will be; in any other font it reserves the wrong
                            // room, and at a large setting it would reserve a fraction of it.
                            Text(Self.reservation(for: source, font: font))
                                .font(font.font)
                                .hidden()
                                .accessibilityHidden(true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if rendersFinalReply {
                            // The settled document, in a hosted text view. Reached only after
                            // the run has ended — never during the stream, where this panel
                            // stays plain characters on purpose (`RenderedReplyView`'s own
                            // comment carries the reason and the measurement). The reservation
                            // above is nil by then, so the two never occupy the `ZStack`
                            // together.
                            //
                            // No `.textSelection` and no `.updatesFrequently`: the text view
                            // selects across the whole document by construction, which is why
                            // it is a text view, and a settled reply is not a live region.
                            RenderedReplyView(text: model.translatedText, font: font)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(model.translatedText)
                                .font(font.font)
                                .textSelection(.enabled)
                                // Without this the text is a live region VoiceOver has no
                                // warning about: it is rewritten on every streamed token, up to
                                // ten times a second, and an assistive technology that re-reads
                                // a changed label would talk over itself for the whole of a
                                // run. The trait is the documented way to say «this changes
                                // often, do not follow it» — the settle is announced once
                                // instead, by `announcement(for:)`.
                                .accessibilityAddTraits(.updatesFrequently)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // A `Text` given less width than it wants truncates rather than
                                // wrapping, and the panel's width is now measured from this
                                // view — so without this the measurement and the rendering
                                // disagree about how many lines there are.
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

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
                        let warnings = WarningsView(outcome: outcome, target: model.resolvedTarget,
                                                    formattingNotice: model.formattingNotice)
                        if warnings.hasContent {
                            // **Unbounded, and inside the scrolling region with the
                            // translation.** Both halves of that were tried the other way round
                            // and taken back out, so both are worth stating.
                            //
                            // Pinned beside the buttons, an unbounded warning list starves the
                            // flexible section: measured on a 560 × 540 stack — the
                            // 0.6-of-screen cap on a 900 pt display — the translation's clip
                            // view came out 438, 365, 215 and **0** pt tall at 0, 5, 15 and 30
                            // warning rows. At 30 the translation is not merely small, it is
                            // unreachable.
                            //
                            // The ceiling that would have answered that is what fails: 160 pt
                            // is larger than this panel's whole floor (`PanelSizer.minHeight`,
                            // 132), so at the smallest size the user may drag to the pinned
                            // block alone outgrew the window. Here the warnings' length costs
                            // only itself. `RunStatusBar` keeps its own `bounded(byHeight: 200)`
                            // because that block sits in a window the user sized, with no floor
                            // anywhere near its ceiling.
                            //
                            // `docs/reference/OPEN-ITEMS.md` carries whether scrolling them with the
                            // translation reads right, which is the one part a number cannot
                            // settle.
                            warnings
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // **The one section that stretches.** The panel is three: a header that does not
            // move, the translation, and everything below it. Only the middle takes the
            // difference between the panel's height and the text's, so the header stays at the
            // top and the status row, the warnings and the buttons stay together at the bottom
            // rather than floating on a spacer.
            //
            // Gated on `fillsPanel` for the reason the spacer it replaces had to be —
            // measured: anything greedy inside the copy `PanelController` sizes from answers
            // «as much as you will give me», and every panel came back at 998 pt, the
            // 0.6-of-screen ceiling, for every reply length from one sentence to twenty.
            .frame(maxHeight: fillsPanel ? .infinity : nil, alignment: .top)

            // The bottom section, static. What the run has to say about itself belongs with
            // the buttons that act on it: the status row and the notice were inside the
            // scrolling middle, where a long translation scrolled them out of reach — and
            // where they took the space the reader wanted for the text. Both are one row and
            // cost the pinned block a fixed height.
            //
            // The warnings stayed in the middle deliberately, and are the one thing here that
            // is not a claim about this block: they have no length of their own, and the
            // ceiling that would give them one is larger than the panel's floor. See their
            // site above.
            statusLine
            termsNotice

            // Pinned, and «Отмена» below is why this matters most: it exists only while a run
            // is in flight, which is exactly when the text above it is still growing. In the
            // scrolling flow it was pushed further out of reach by every token it was there
            // to stop.
            HStack {
                // «Заменить» first and accented — issue #27 makes it the primary path a
                // finished result is expected to leave the panel by, with «Скопировать»
                // staying the manual fallback for a user who wants to paste somewhere else
                // themselves. Gated on `.finished`, not merely non-empty text: unlike
                // «Скопировать» below, this may never write a half-streamed answer into
                // another application.
                Button("Заменить", action: onReplace)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(Self.replaceShortcut)
                    .disabled(!model.offersReplace || frontmostIsTerminal)
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
                if model.offersAnotherVariant {
                    Button("Ещё вариант", action: onAnotherVariant)
                }
                Spacer()
                if model.state == .running {
                    // ⌘. is the macOS convention for cancelling an operation in progress,
                    // and Esc is taken: the panel gives it to «close and cancel».
                    Button("Отмена") { model.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Only `targetBusy` gets words. `sourceBusy` means this panel's own run is still
            // going, which the spinner and «Отмена» beside it already say; `sameModel` is not
            // reachable from here. A greyed-out button with no explanation is fine when the
            // reason is on screen, and not fine when it is in another window.
            if adoptionRefusal == .targetBusy {
                Text("Окно занято своим переводом — дождитесь его окончания.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // «Заменить» — issue #29. A terminal has no editable selection to replace, and a
            // multi-line result can, depending on the shell and session, be read as a
            // sequence of Enter-terminated commands rather than as inert text — the reason
            // this refusal has no override, unlike `targetBusy` above which is just a wait.
            if frontmostIsTerminal {
                Text("«Заменить» не работает в терминале — там нет выделения для замены.")
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

    /// The row's contents, with one override the static rule cannot make on its own.
    ///
    /// While `awaitingReply` holds, `model.state` describes the **previous** press — a
    /// `.finished` or `.failed` left over from a run that is not this one. So the panel reports progress, which is what
    /// is actually happening — a selection has been captured and a translation of it is under
    /// way, or is about to be in the same turn of the main actor.
    ///
    /// It is also 24 pt of the reservation above. The status row exists only from `.running`,
    /// which arrives after `show(at:)` has taken its measurement — so the panel opened 24 pt short of
    /// the row it was about to grow, at every selection length from three sentences to twelve.
    /// Measured: with this, `show(at:)` measures what it is about to display and the shortfall
    /// is zero.
    ///
    /// `Self.status(for:awaitingTerms:)` keeps its own contract untouched. It answers about a
    /// state; this answers about a presentation, and only the caller knows which selection the
    /// state belongs to.
    private var status: PanelStatus? {
        // No `if case .text` guard: `statusLine` is reachable only from `translation`, which
        // `content` builds for that case alone. Restating it here reads as though the
        // «выделите текст» and «нет доступа» panels also draw a status row, and leaves a
        // branch that cannot be false for a later reader to keep in step with the enum.
        awaitingReply ? Self.status(for: .running, awaitingTerms: model.isAwaitingTerms,
                                    operation: model.operation, formatting: model.isFormatting)
                      : Self.status(for: model.state, awaitingTerms: model.isAwaitingTerms,
                                    operation: model.operation, formatting: model.isFormatting)
    }

    @ViewBuilder private var statusLine: some View {
        if let status = status {
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
        case .progress, .awaitingUser, .formatting: .secondary
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
    /// including a `static func` over three value parameters — is inferred `@MainActor`, and a
    /// synchronous test calling it from a nonisolated context is «call to main actor-isolated
    /// static method … in a synchronous nonisolated context»: the one warning left standing
    /// after this target reached `-swift-version 6`. Both functions are pure over
    /// `Sendable` values and touch no view state, so the isolation was never true of them;
    /// declaring that is better than making the tests `@MainActor` to satisfy an inference
    /// that describes nothing.
    nonisolated static func direction(outcome: TranslationOutcome?, target: Language?,
                                      operation: TextOperation?) -> String? {
        guard let outcome else { return nil }
        if operation == .proofread {
            return RussianCopy.proofreadHeader(language: outcome.detectedSource)
        }
        guard let target else { return nil }
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
    nonisolated static func announcement(for state: TranslationState,
                                         operation: TextOperation = .translate) -> String? {
        switch state {
        case .idle, .running: nil
        case .finished: operation == .proofread ? "Правка готова" : "Перевод готов"
        case .interrupted: operation == .proofread
            ? "Правка прервана, показана пришедшая часть"
            : "Перевод прерван, показана пришедшая часть"
        // The view model has already put this into Russian and it carries the only
        // instruction the user gets — the same reasoning as `status(for:)`'s failure case.
        case .failed(let message): message
        }
    }

    /// Whether the степень/стиль row belongs on screen.
    ///
    /// A value rather than a condition written inside the `ViewBuilder`, for `status(for:)`'s
    /// reason: which controls appear is a decision, and a decision inside a view body can only
    /// be read by rebuilding the view.
    ///
    /// The selection half is not redundant with the operation half: `header` is drawn by the
    /// permission prompt and the empty hint too, and a control with nothing captured to re-run
    /// is the inert chrome the operation switch is already gated against.
    nonisolated static func showsProofreadingControls(operation: TextOperation,
                                                      selection: SelectionResult) -> Bool {
        guard case .text = selection else { return false }
        return operation == .proofread
    }

    /// Whether the reply should be drawn as a rendered document — the panel's one Phase 4
    /// decision, in one place.
    ///
    /// Four conditions, and each of them is load-bearing in a different direction:
    ///
    /// - **The run has ended.** `state != .running` is what keeps the panel byte-identical to
    ///   what it was during a stream, which the design asks for on its own terms
    ///   (§7: the panel answers in under a second at 300–560 pt, and a reflowing layout there is
    ///   worse than raw `**`) and which is also what leaves `PanelSizer`'s monotonic height and
    ///   the reservation's square-law prediction measuring the thing they were tuned against.
    ///   `.interrupted` and `.failed` count as ended: an interrupted run's partial output is
    ///   kept on purpose, and there is nothing more coming to reflow it.
    /// - **No press is being started.** `awaitingRun` is the window inside which the panel is
    ///   measured against the *reservation* while still showing the previous run's text
    ///   (`selectionAwaitingReply`, `PanelController.show(at:)`). Rendering there would put a
    ///   document and an invisible copy of the new source in one `ZStack` and measure the panel
    ///   against both.
    /// - **There is markup.** `MarkdownPresence.hasMarkup` — the same gate the window's pane
    ///   uses, so «Цена 5 * 3 = 15» is prose in both places. Prose with no markup renders
    ///   identically either way, and drawing it through a text view anyway would change the
    ///   panel's measured height for nothing.
    /// - **The user has not asked for «Исходник».** The panel has no toggle of its own — the
    ///   design puts it in the pane's header — so this reads the same
    ///   `AppSettings.showsRenderedMarkup` the pane writes.
    ///
    /// `nonisolated` for the reason `direction(outcome:target:operation:)` is.
    nonisolated static func rendersFinalReply(state: TranslationState,
                                              awaitingRun: Bool,
                                              text: String,
                                              showsRenderedMarkup: Bool) -> Bool {
        guard !awaitingRun, state != .running, showsRenderedMarkup else { return false }
        return MarkdownPresence.hasMarkup(text)
    }

    /// The rich flavour the panel's «Скопировать» and its ⏎ write beside the Markdown, or nil
    /// for a plain copy.
    ///
    /// The «is there markup, and is the user looking at it» half is `PaneRendering`'s — the
    /// window's own rule, delegated rather than restated, because the panel and the pane copying
    /// different things out of one translation is exactly the failure that type was introduced
    /// to prevent. What is added here is the panel's own half: the reply is only *rendered* after
    /// the run settles, so a copy taken mid-stream — which «Скопировать» deliberately allows,
    /// from the first token — is plain. Nothing half-arrived leaves this app wearing a font it
    /// chose.
    ///
    /// A function called at the instant a button is pressed, never from a body:
    /// `MainWindowView.richFlavour()`'s reason, which is that this serialises the whole document
    /// to RTF.
    nonisolated static func richFlavour(text: String, rendersFinalReply: Bool,
                                        showsRenderedMarkup: Bool,
                                        font: ContentFont) -> Data? {
        guard rendersFinalReply else { return nil }
        return PaneRendering.of(text, showsRenderedMarkup: showsRenderedMarkup)
            .rtf(of: text, font: font)
    }

    /// Exhaustive with no `default:` on purpose: a sixth `TranslationState` case should
    /// fail to compile here instead of leaving the panel silent about a state it has no
    /// words for.
    ///
    /// `nonisolated` for the reason given on `direction(outcome:target:operation:)` above.
    /// - Parameter awaitingTerms: whether the run is suspended on the «Термины документа»
    ///   sheet. A parameter rather than a fifth `TranslationState`, because it is not a
    ///   state the run *reaches* — it is a thing happening inside `.running`, and adding a
    ///   case would make every other switch over `TranslationState` in this app answer a
    ///   question it has no business answering.
    nonisolated static func status(for state: TranslationState,
                                   awaitingTerms: Bool = false,
                                   operation: TextOperation = .translate,
                                   formatting: Bool = false) -> PanelStatus? {
        switch state {
        case .idle, .finished:
            // Nothing to add. The panel opens on a translation and closes on Esc; a caption
            // saying so would be a line of chrome over a result the user is trying to read.
            return nil
        case .running:
            // The «Оформить» pass: the model is working, on the source, and the reply has not
            // begun. Before the terms check, because the pass runs before anything that
            // could raise the sheet.
            if formatting {
                return PanelStatus(kind: .formatting, message: "Оформляю…", offersRetry: false)
            }
            // The escalated sheet is on the main window, in front; this panel is behind it
            // and the model is idle. Saying «Перевожу…» here contradicts the table asking
            // for the user's attention two windows up.
            if awaitingTerms {
                return PanelStatus(kind: .awaitingUser, message: "Жду ваших правок…",
                                   offersRetry: false)
            }
            let message = operation == .proofread ? "Исправляю…" : "Перевожу…"
            return PanelStatus(kind: .progress, message: message, offersRetry: false)
        case .interrupted:
            let message = operation == .proofread
                ? "Правка прервана — показана та часть, что успела прийти"
                : "Перевод прерван — показана та часть, что успела прийти"
            return PanelStatus(kind: .interrupted, message: message, offersRetry: false)
        case .failed(let message):
            // Spec 8: a failure offers a retry rather than only an explanation. The message
            // is passed through untouched — `TranslationViewModel.message(for:)` has already
            // put it into Russian, and it carries the only instruction the user gets.
            return PanelStatus(kind: .failure, message: message, offersRetry: true)
        }
    }
}
