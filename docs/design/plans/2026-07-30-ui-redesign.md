# UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The floating panel sizes itself to its content on both axes, and the main window and settings window are rebuilt as exemplary native macOS surfaces.

**Architecture:** Every size decision the panel makes moves out of AppKit into two pure types — `PanelSizer` (how big) and an extended `PanelPlacement` (where, and from which corner it grows) — so the risky part of the change is unit-testable. `hosting.sizingOptions` stays `[]`; the controller measures a detached, never-installed `NSHostingView` and sets the frame itself. The main window gains a real toolbar and a collapsible status bar; the settings window collapses from four self-sizing tabs to three tabs of one fixed size.

**Tech Stack:** Swift 5 language mode on Swift 6 tools, SwiftUI + AppKit, Observation, Swift Testing. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-07-30-ui-redesign-design.md`. Where this plan and the spec disagree, the spec is right; report the disagreement rather than choosing.

## Global Constraints

- Swift tools version 6.0, platform floor macOS 14, `.swiftLanguageMode(.v5)` on every target. No new targets.
- **No external dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation, ApplicationServices, CoreGraphics, Carbon, Swift Testing only.
- All user-facing strings are Russian, with «guillemets» and «ё». Identifiers (`aya-expanse:8b`) and key glyphs (⌥⌘T) stay as they are.
- **No backticks in any string rendered by `Text(String)`.** The plain-`String` initialiser never parses Markdown, so a backtick shows as a literal grave accent. Use guillemets. Building a string with `+` forces that initialiser.
- Tests are Swift Testing (`@Test`, `#expect`), never XCTest. Test names are sentences describing the behaviour being pinned. `UserDefaults`-backed tests use `InMemoryDefaults`.
- **Baseline at the start of this plan: 289 tests passing, `swift build` and `swift build --build-tests` both at zero warnings.** Both must hold at every commit. Zero warnings is a standing rule, not an aspiration.
- Comments carry *why* and the measurement behind it, not what the code does. **«Measured» and «load-bearing» are a contract**: where this plan deletes code such a comment justifies, the comment moves with the behaviour or records why the measurement no longer applies. Deleting the line and keeping the comment has already cost this project two defects.
- GUI automation is unavailable. **Never describe UI behaviour that was not observed.** A task that ships a view states what indirect evidence was gathered instead.
- Commit messages: conventional, scoped — `feat(app):`, `fix(app):`, `test(app):`, `docs(app):`, `feat(ollama):`.
- Branch: `feat/ui-redesign`, already created from `main` and already carrying the spec commit.

---

## File Structure

**New files in `Sources/TranslatorApp/`:**

| File | Responsibility |
|---|---|
| `PanelSizer.swift` | Pure: next panel size from ideal size, frozen width, previous size, screen, `userSized`. Owns the ceilings, the frozen width and the monotonic height. |
| `SourcePane.swift` | The window's left pane: header, editor, placeholder, footer. |
| `TranslationPane.swift` | The window's right pane: header, read-only result, empty state. |
| `RunStatusBar.swift` | The window's bottom bar and its warnings disclosure. |
| `SettingsPane.swift` | The one size and form style every settings tab uses. |
| `GlossaryOrder.swift` | Pure: `visibleOrder(entries:query:) -> [Int]`. |
| `GlossaryList.swift` | The glossary pane's list, header and empty state. |

**New test files in `Tests/TranslatorAppTests/`:** `PanelSizerTests.swift`, `GlossaryOrderTests.swift`.

**Modified:** `PanelPlacement.swift`, `TranslationPanel.swift`, `PanelView.swift`, `MainWindowView.swift`, `TranslationViewModel.swift`, `TranslatorApp.swift`, `SettingsGeneralView.swift`, `SettingsModelsView.swift`, `SettingsGlossaryView.swift`, `ModelsViewModel.swift`, `OllamaStatusModel.swift`, `RussianCopy.swift`, `Sources/OllamaKit/OllamaClient.swift` (one public initialiser).

**Deleted:** `SettingsAdvancedView.swift`.

---

## Task 1: The panel's anchor corner

**Files:**
- Modify: `Sources/TranslatorApp/PanelPlacement.swift`
- Test: `Tests/TranslatorAppTests/PanelPlacementTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PanelAnchor` (`.topLeading`, `.topTrailing`, `.bottomLeading`, `.bottomTrailing`); `PanelPlacement.Placement` (`frame: CGRect`, `anchor: PanelAnchor`); `PanelPlacement.place(cursor:size:screen:gap:) -> Placement`; `PanelPlacement.reframe(current:newSize:anchor:screen:) -> CGRect`. The existing `PanelPlacement.frame(cursor:size:screen:gap:) -> CGRect` keeps its exact signature and behaviour.

Background the implementer needs: AppKit screen coordinates have their origin at the bottom-left with y increasing upwards, so "top" means `maxY`. The existing placement puts the panel below and to the right of the pointer, flipping left when it would overflow the right edge and flipping up when it would overflow the bottom, then clamping. The corner nearest the pointer is therefore the corner the panel should grow from.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/PanelPlacementTests.swift`:

```swift
// MARK: - The anchor corner, and growing from it

@Test func thePreferredPlacementIsAnchoredByItsTopLeftCorner() {
    // The panel hangs down and to the right of the pointer, so the corner nearest the
    // pointer — the one the reader's eye is already on — is the top left.
    let placement = PanelPlacement.place(cursor: CGPoint(x: 400, y: 600), size: size, screen: screen)
    #expect(placement.anchor == .topLeading)
    #expect(placement.frame == PanelPlacement.frame(cursor: CGPoint(x: 400, y: 600),
                                                    size: size, screen: screen))
}

@Test func flippingLeftMovesTheAnchorToTheTopRight() {
    let placement = PanelPlacement.place(cursor: CGPoint(x: 1400, y: 600), size: size, screen: screen)
    #expect(placement.anchor == .topTrailing)
}

@Test func flippingUpwardMovesTheAnchorToTheBottomLeft() {
    let placement = PanelPlacement.place(cursor: CGPoint(x: 400, y: 100), size: size, screen: screen)
    #expect(placement.anchor == .bottomLeading)
}

@Test func aPointerInTheBottomRightCornerAnchorsTheBottomRight() {
    let placement = PanelPlacement.place(cursor: CGPoint(x: 1400, y: 100), size: size, screen: screen)
    #expect(placement.anchor == .bottomTrailing)
}

@Test func growingFromATopLeftAnchorLeavesTheTopLeftCornerWhereItWas() {
    // The whole point of the anchor: text the user has already read must not move.
    let start = CGRect(x: 100, y: 500, width: 360, height: 240)
    let grown = PanelPlacement.reframe(current: start,
                                       newSize: CGSize(width: 360, height: 400),
                                       anchor: .topLeading, screen: screen)
    #expect(grown.minX == 100)
    #expect(grown.maxY == 740)
    #expect(grown.height == 400)
}

@Test func growingFromABottomRightAnchorLeavesTheBottomRightCornerWhereItWas() {
    let start = CGRect(x: 100, y: 500, width: 360, height: 240)
    let grown = PanelPlacement.reframe(current: start,
                                       newSize: CGSize(width: 420, height: 400),
                                       anchor: .bottomTrailing, screen: screen)
    #expect(grown.maxX == 460)
    #expect(grown.minY == 500)
}

@Test func aPanelThatOutgrowsTheScreenIsClampedRatherThanLeftHangingOffIt() {
    // Re-clamping on every resize is not belt and braces. `constrainFrameRect` is
    // overridden to return the frame untouched — deliberately, because Stage Manager was
    // measured moving a frame 202pt sideways — so nothing else will pull a grown panel back.
    let start = CGRect(x: 100, y: 40, width: 360, height: 240)
    let grown = PanelPlacement.reframe(current: start,
                                       newSize: CGSize(width: 360, height: 800),
                                       anchor: .topLeading, screen: screen)
    #expect(grown.minY >= screen.minY)
    #expect(grown.maxY <= screen.maxY)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PanelPlacement`
Expected: FAIL — `place`, `reframe`, `PanelAnchor` and `Placement` do not exist, so this does not compile.

- [ ] **Step 3: Write the implementation**

Replace the body of `Sources/TranslatorApp/PanelPlacement.swift` with:

```swift
// Sources/TranslatorApp/PanelPlacement.swift
import CoreGraphics

/// The corner a panel grows from.
///
/// Not decoration and not symmetry: the panel resizes while the user is reading it, and a
/// resize that moves the corner nearest the pointer drags every line of already-read text
/// with it. The corner nearest the pointer is whichever one the placement arithmetic below
/// put there, so the two decisions are made in one place and cannot disagree.
///
/// "Top" is `maxY`: AppKit screen coordinates have their origin bottom-left.
enum PanelAnchor: Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }
}

/// Where the floating panel goes, given where the pointer is.
///
/// Extracted from the panel controller because it is the only part of the panel that is
/// arithmetic rather than AppKit, and the corner cases — the pointer near an edge, a second
/// display at a negative origin, a panel taller than the screen — are exactly the ones
/// nobody exercises by hand.
///
/// AppKit screen coordinates: origin bottom-left, y increasing upwards.
enum PanelPlacement {
    struct Placement: Equatable {
        let frame: CGRect
        let anchor: PanelAnchor
    }

    static func place(cursor: CGPoint, size: CGSize, screen: CGRect,
                      gap: CGFloat = 14) -> Placement {
        // Preferred: to the right of the pointer, hanging downwards from it.
        var x = cursor.x + gap
        var y = cursor.y - gap - size.height
        var leading = true
        var top = true

        // Flip before clamping. Clamping alone would slide the panel along the edge and
        // park it on top of the selection the user is trying to read.
        if x + size.width > screen.maxX { x = cursor.x - gap - size.width; leading = false }
        if y < screen.minY { y = cursor.y + gap; top = false }

        let anchor: PanelAnchor = switch (top, leading) {
        case (true, true): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (false, false): .bottomTrailing
        }
        return Placement(frame: clamp(CGRect(origin: CGPoint(x: x, y: y), size: size), in: screen),
                         anchor: anchor)
    }

    /// The frame alone, for callers that do not resize. Kept so the placement rules have one
    /// implementation rather than two that drift.
    static func frame(cursor: CGPoint, size: CGSize, screen: CGRect,
                      gap: CGFloat = 14) -> CGRect {
        place(cursor: cursor, size: size, screen: screen, gap: gap).frame
    }

    /// A resized panel, with `anchor`'s corner left exactly where it was.
    static func reframe(current: CGRect, newSize: CGSize, anchor: PanelAnchor,
                        screen: CGRect) -> CGRect {
        let x = anchor.isLeading ? current.minX : current.maxX - newSize.width
        let y = anchor.isTop ? current.maxY - newSize.height : current.minY
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: newSize), in: screen)
    }

    /// Clamp last, for the cases flipping cannot solve: a panel wider or taller than the
    /// screen, or a pointer close enough to a corner that both sides overflow. It is also
    /// the only thing that pulls a *grown* panel back on screen — `constrainFrameRect` is
    /// overridden to return frames untouched, so AppKit will not do it.
    private static func clamp(_ rect: CGRect, in screen: CGRect) -> CGRect {
        let x = min(max(rect.minX, screen.minX), max(screen.minX, screen.maxX - rect.width))
        let y = min(max(rect.minY, screen.minY), max(screen.minY, screen.maxY - rect.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PanelPlacement`
Expected: PASS, including every pre-existing test in the file — `frame(cursor:size:screen:)` must be behaviour-identical.

- [ ] **Step 5: Run the whole suite and the warnings check**

Run: `swift build --build-tests 2>&1 | grep -c warning` → expected `0`
Run: `swift test` → expected 296 tests passing (289 + 7).

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/PanelPlacement.swift Tests/TranslatorAppTests/PanelPlacementTests.swift
git commit -m "feat(app): give the panel's placement an anchor corner to grow from"
```

---

## Task 2: `PanelSizer`

**Files:**
- Create: `Sources/TranslatorApp/PanelSizer.swift`
- Test: `Tests/TranslatorAppTests/PanelSizerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PanelSizer.Fit` (`size: CGSize`, `scrolls: Bool`); `PanelSizer.fit(ideal:frozenWidth:previous:screen:userSized:) -> Fit`; the constants `PanelSizer.minWidth` (300), `maxWidth` (560), `minHeight` (120), `maxHeightFraction` (0.6).

- [ ] **Step 1: Write the failing tests**

Create `Tests/TranslatorAppTests/PanelSizerTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import TranslatorApp

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)   // ceiling: 540pt

@Test func aShortResultGetsAPanelTheSizeOfItsContent() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 420, height: 180), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size == CGSize(width: 420, height: 180))
    #expect(fit.scrolls == false)
}

@Test func aNarrowResultIsWidenedToTheFloorRatherThanLeftAsASliver() {
    // A one-word translation would otherwise open a panel too narrow for its own buttons.
    let fit = PanelSizer.fit(ideal: CGSize(width: 90, height: 60), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size == CGSize(width: 300, height: 120))
}

@Test func aWideResultIsCappedRatherThanSpanningTheDisplay() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 1300, height: 200), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size.width == 560)
}

@Test func theWidthIsFrozenOnceARunHasStarted() {
    // A width that moved while tokens arrived would re-wrap every line on every token.
    let fit = PanelSizer.fit(ideal: CGSize(width: 520, height: 300), frozenWidth: 380,
                             previous: CGSize(width: 380, height: 200), screen: screen,
                             userSized: false)
    #expect(fit.size.width == 380)
}

@Test func theHeightNeverDecreasesWhileMoreTextArrives() {
    // Monotonic within a run. A cleaner that shortens the reply mid-stream, or a chunk
    // boundary that briefly measures small, must not make the panel jump shut.
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 200), frozenWidth: 380,
                             previous: CGSize(width: 380, height: 340), screen: screen,
                             userSized: false)
    #expect(fit.size.height == 340)
}

@Test func theHeightStopsAtSixtyPercentOfTheScreenAndScrollsInstead() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 2000), frozenWidth: 380,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size.height == 540)
    #expect(fit.scrolls)
}

@Test func contentThatFitsDoesNotAskForAScrollView() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 539), frozenWidth: 380,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.scrolls == false)
}

@Test func aHandResizedPanelKeepsTheSizeTheUserGaveIt() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 500, height: 900), frozenWidth: 380,
                             previous: CGSize(width: 300, height: 200), screen: screen,
                             userSized: true)
    #expect(fit.size == CGSize(width: 300, height: 200))
    #expect(fit.scrolls)   // the content no longer fits what the user chose
}

@Test func anUnmeasuredContentSizeProducesTheFloorRatherThanANaNFrame() {
    // A SwiftUI view asked for its fitting size before the first layout pass reports
    // `.zero`, and an `NSWindow` moved to a NaN origin is unrecoverable. Infinity is the
    // same hazard from the other direction: `sizeThatFits` is asked with an unbounded
    // proposal, and a greedy subview can hand the proposal straight back.
    let zero = PanelSizer.fit(ideal: .zero, frozenWidth: nil, previous: .zero,
                              screen: screen, userSized: false)
    #expect(zero.size == CGSize(width: 300, height: 120))

    let infinite = PanelSizer.fit(ideal: CGSize(width: .infinity, height: .infinity),
                                  frozenWidth: nil, previous: .zero, screen: screen,
                                  userSized: false)
    #expect(infinite.size == CGSize(width: 560, height: 540))
    #expect(infinite.size.width.isFinite)
    #expect(infinite.size.height.isFinite)
}

@Test func aScreenTooShortForTheHeightFloorStillYieldsTheFloor() {
    // 60% of a 150pt strip is 90pt, below the 120pt floor. A panel smaller than its own
    // buttons is worse than one that overhangs a freak display.
    let strip = CGRect(x: 0, y: 0, width: 1440, height: 150)
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 400), frozenWidth: nil,
                             previous: .zero, screen: strip, userSized: false)
    #expect(fit.size.height == 120)
    #expect(fit.scrolls)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PanelSizer`
Expected: FAIL — `PanelSizer` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Sources/TranslatorApp/PanelSizer.swift`:

```swift
// Sources/TranslatorApp/PanelSizer.swift
import CoreGraphics

/// How big the floating panel should be, given how big its content wants to be.
///
/// A type of its own, with no AppKit in it, because this is the part of "the panel fits its
/// content" that can be checked: the ceilings, the frozen width, the monotonic height and
/// the decision to start scrolling are rules, and rules stated in a controller alongside
/// `setFrame` calls can only be read, not tested.
///
/// The panel was a fixed 380 × 260 until this existed, and the reason it was fixed is worth
/// keeping in view: a panel that changes size while text streams into it moves under the
/// reader's eyes. That objection is answered by the anchor (`PanelAnchor` — growth leaves
/// the corner nearest the pointer alone) and by the two rules below, not by ignoring it.
enum PanelSizer {
    /// Below this a panel is narrower than its own button row.
    static let minWidth: CGFloat = 300
    /// Above this the panel stops being a panel. A translation is read, not scanned, and a
    /// 900pt line is worse to read than a 560pt one.
    static let maxWidth: CGFloat = 560
    /// Enough for the header, one line and the buttons.
    static let minHeight: CGFloat = 120
    /// The panel floats over the work the user is reading; taking more than this much of
    /// the screen makes it a window with no way to move it aside.
    static let maxHeightFraction: CGFloat = 0.6

    struct Fit: Equatable {
        let size: CGSize
        /// The content is taller than the size granted, so the caller must install the
        /// scrolling variant of the content view.
        let scrolls: Bool
    }

    /// - Parameters:
    ///   - ideal: what the content measured to, unconstrained. `.zero` before the first
    ///     layout pass; may be infinite if a subview hands an unbounded proposal back.
    ///   - frozenWidth: the width already chosen for this presentation, or nil if none has
    ///     been chosen yet.
    ///   - previous: the panel's current size. `.zero` before it is first shown.
    ///   - screen: the `visibleFrame` of the screen the panel is on.
    ///   - userSized: the user has dragged the panel's edge, so it is theirs until it hides.
    static func fit(ideal: CGSize, frozenWidth: CGFloat?, previous: CGSize,
                    screen: CGRect, userSized: Bool) -> Fit {
        let wanted = CGSize(width: sanitised(ideal.width, fallback: minWidth),
                            height: sanitised(ideal.height, fallback: minHeight))

        // The user's choice wins outright. Not "wins until the content grows past it":
        // resizing a panel is an instruction, and taking the size back the moment another
        // line arrives would make the handle useless exactly when it is reached for.
        guard !userSized else {
            return Fit(size: previous, scrolls: wanted.height > previous.height)
        }

        let width = frozenWidth ?? min(max(wanted.width, minWidth), maxWidth)
        // `max(minHeight, …)` and not the fraction alone: on a very short screen — a strip
        // display, or a `visibleFrame` squeezed by a tall menu bar — the fraction falls
        // below the floor, and a panel shorter than its own buttons is the worse failure.
        let ceiling = max(minHeight, screen.height * maxHeightFraction)
        let fitted = min(max(wanted.height, minHeight), ceiling)
        // Monotonic within a presentation. The caller resets `previous` by hiding the panel.
        let height = min(max(fitted, previous.height), ceiling)
        return Fit(size: CGSize(width: width, height: height), scrolls: wanted.height > height)
    }

    /// `sizeThatFits` is asked with an unbounded proposal, so a greedy subview can return
    /// infinity, and a view measured before its first layout pass returns zero. Both reach
    /// `NSWindow.setFrame`, where a non-finite origin is unrecoverable.
    private static func sanitised(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : fallback
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PanelSizer`
Expected: PASS, 10 tests.

Note on the infinity case: `sanitised(.infinity, fallback: minWidth)` returns `minWidth` (300), not 560, because infinity is not finite. The test expects 560. **Fix the implementation, not the test**: an unbounded measurement means "as much as you will give me", so the fallback for a non-finite value must be the *ceiling*, not the floor. Change the two call sites to `sanitised(ideal.width, fallback: maxWidth)` and `sanitised(ideal.height, fallback: .greatestFiniteMagnitude)`, keeping `.zero` handling correct by testing `> 0` first:

```swift
        let wanted = CGSize(width: measured(ideal.width, unmeasured: minWidth, unbounded: maxWidth),
                            height: measured(ideal.height, unmeasured: minHeight,
                                             unbounded: .greatestFiniteMagnitude))
...
    /// Three cases, and they mean different things. A finite positive number is a real
    /// measurement. Zero is a view asked for its size before its first layout pass, which
    /// means "no idea" — take the floor. Infinity is a greedy subview handing an unbounded
    /// proposal straight back, which means "as much as you will give me" — take the ceiling.
    /// Both non-numbers reach `NSWindow.setFrame`, where they are unrecoverable.
    private static func measured(_ value: CGFloat, unmeasured: CGFloat,
                                 unbounded: CGFloat) -> CGFloat {
        if value.isFinite && value > 0 { return value }
        return value == .infinity ? unbounded : unmeasured
    }
```

Re-run and expect PASS.

- [ ] **Step 5: Run the whole suite and the warnings check**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 306 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/PanelSizer.swift Tests/TranslatorAppTests/PanelSizerTests.swift
git commit -m "feat(app): decide the panel's size in a type that can be tested"
```

---

## Task 3: The panel's content

**Files:**
- Modify: `Sources/TranslatorApp/PanelView.swift`
- Test: `Tests/TranslatorAppTests/PanelViewTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `PanelView(model:selection:scrolls:adoptionRefusal:onCopy:onOpenInWindow:onRetry:onGrantPermission:onClose:)`. `scrolls` defaults to `false`; `onClose` defaults to `{}`. `PanelView.status(for:)` and `PanelView.direction(outcome:target:)` keep their exact existing signatures and behaviour.

What changes and why:

1. The `.frame(minWidth: 340, maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)` is **removed**. Its `maxHeight` and `.topLeading` existed to stop short content floating in the middle of a fixed 380 × 260 rectangle, and the rectangle is no longer fixed. Its width clamp would now fight `PanelSizer` for the same decision, and two clamps disagreeing about width is how a measured ideal width silently stops being the width used.
2. A header row carries the direction line and a borderless ⨯. The titlebar is going away in Task 4, and with it the close button.
3. `ScrollView` inside `translation` is **removed** — the `.frame(maxHeight: 220)` on it was the panel's internal ceiling and the sizer owns that now. Its place is taken by the `scrolls` flag, which wraps the *whole* content.
4. `.regularMaterial` behind a 12pt rounded rectangle.

Everything else — the exhaustive `switch` over `SelectionResult`, the permission prompt's full path and its `fixedSize(horizontal: false, vertical: true)`, the `hasContent` gate on the warnings, the `adoptionRefusal` rules, `statusLine`'s `fixedSize` and `Spacer` — is unchanged and must be carried over verbatim, comments included.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/PanelViewTests.swift`:

```swift
@MainActor
@Test func thePanelOffersACloseControlOfItsOwn() {
    // The titlebar goes away with `.titled` in Task 4, and its close button with it. A
    // panel a mouse cannot dismiss would leave Esc as the only way out, which is fine for
    // the keyboard and not fine for anyone else.
    //
    // Constructed, not rendered: this process has no GUI automation, so what is checked is
    // that the view takes the callback and that a default exists — not that a glyph appears.
    var closed = false
    let view = PanelView(model: model(), selection: .empty, onClose: { closed = true })
    view.onClose()
    #expect(closed)
}
```

If `PanelViewTests.swift` has no `model()` helper, add one built the way the existing tests in that file build their view model; read the file first and follow it rather than inventing a second shape.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PanelView`
Expected: FAIL — `PanelView` has no `onClose`.

- [ ] **Step 3: Write the implementation**

In `Sources/TranslatorApp/PanelView.swift`:

Add the two properties beside the existing callbacks:

```swift
    /// Whether the content must scroll — `PanelSizer` decided the content is taller than
    /// the panel it can be given. Wrapping the *whole* content and not just the text,
    /// because the ceiling applies to the sum: a long translation with a long document
    /// glossary can put the button row off the bottom on its own.
    var scrolls = false
    var onClose: () -> Void = {}
```

Replace `body` with:

```swift
    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
```

In `translation`, replace the direction `Text` and the `ScrollView` with the header and a plain `Text`:

```swift
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
            ... unchanged ...
```

Delete the `.frame(maxHeight: 220)` and the `ScrollView` around the text. In the warnings block, delete `.frame(maxHeight: 120)` and the `ViewThatFits`, leaving the bare `warnings` behind its `hasContent` gate — the sizer owns the ceiling now, and a `ViewThatFits` inside a view being measured for its ideal size answers a question nobody asked. Keep the `hasContent` gate and its comment, updating the comment's last paragraph to say the 120pt slot is gone and the gate now exists so an empty stack does not add padding to a measured height.

Add `header` to `permissionPrompt` and `emptyHint` too, so every state has a way out:

```swift
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Label("Нет доступа к тексту в других программах", systemImage: "lock")
            ... unchanged ...
```

```swift
    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Label("Выделите текст и нажмите сочетание ещё раз", systemImage: "text.cursor")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PanelView`
Expected: PASS, including every pre-existing test in the file.

- [ ] **Step 5: Run the whole suite and the warnings check**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 307 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/PanelView.swift Tests/TranslatorAppTests/PanelViewTests.swift
git commit -m "feat(app): give the panel content that can be measured"
```

---

## Task 4: The panel measures and resizes itself

**Files:**
- Modify: `Sources/TranslatorApp/TranslationPanel.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift` (the `PanelController` construction and `PanelHost`)
- Test: `Tests/TranslatorAppTests/TranslationPanelTests.swift`

**Interfaces:**
- Consumes: `PanelSizer.fit(ideal:frozenWidth:previous:screen:userSized:) -> PanelSizer.Fit`; `PanelPlacement.place(cursor:size:screen:gap:) -> Placement`; `PanelPlacement.reframe(current:newSize:anchor:screen:) -> CGRect`; `PanelView(… scrolls: …)`.
- Produces: `PanelController.init(content: @escaping (Bool) -> AnyView)` — the flag is `scrolls`; `PanelController.setContentBuilder(_:)`; `PanelController.contentDidChange(settling:)`; `PanelController.show(at:)` and `hide()` keep their signatures.

This is the task with the real risk. Read it whole before starting.

**Why a second, detached hosting view.** The controller must measure the *non-scrolling* content while the *scrolling* one may be installed. Measuring the installed view once it has been swapped would return the compressed height and the panel would never grow back. A detached `NSHostingView` that is never added to a window solves it outright: it always holds the non-scrolling variant and is only ever asked for a size.

**Why `sizingOptions` stays `[]`.** It is what stops AppKit deriving the window size from the hosting view's constraints. Measured on the running bundle: without it the panel opened at 380 × 120 regardless of content. Nothing about content-sizing changes that; the controller now computes the size instead of hard-coding it.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/TranslationPanelTests.swift`:

```swift
@MainActor
@Test func theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive() {
    // The measurement this replaces was taken with `.titled` in the mask. Dropping `.titled`
    // is what buys the rounded material panel, and it is also the one change that could
    // silently cost the panel its key status — and with it Esc and Enter, which are the
    // only way to close and copy. This process runs at `.prohibited` activation policy,
    // where activation is impossible, so `isKeyWindow == true` here has exactly one
    // possible cause. Same reasoning as the test above it; re-run because the mask changed.
    let controller = PanelController { _ in AnyView(Text("готово")) }
    controller.show(at: CGPoint(x: 300, y: 400))
    #expect(controller.panel.isKeyWindow)
    #expect(NSRunningApplication.current.isActive == false)
    controller.hide()
}

@MainActor
@Test func aPanelWithLittleToSayOpensSmallerThanOneWithALot() {
    // The change in one line. Both panels are built the same way and differ only in their
    // content, so a fixed-size panel fails this and a content-sized one does not.
    let short = PanelController { _ in AnyView(Text("Готово.").padding(14)) }
    let long = PanelController { _ in
        AnyView(Text(String(repeating: "Длинная строка перевода. ", count: 40)).padding(14))
    }
    short.show(at: CGPoint(x: 300, y: 500))
    long.show(at: CGPoint(x: 300, y: 500))
    #expect(short.panel.frame.height < long.panel.frame.height)
    short.hide()
    long.hide()
}

@MainActor
@Test func theMeasuredPanelStaysInsideTheSizersBounds() {
    // Whatever the hosting view reports, the frame that reaches AppKit is the sizer's.
    let controller = PanelController { _ in
        AnyView(Text(String(repeating: "строка ", count: 4000)).padding(14))
    }
    controller.show(at: CGPoint(x: 300, y: 500))
    let frame = controller.panel.frame
    #expect(frame.width >= PanelSizer.minWidth)
    #expect(frame.width <= PanelSizer.maxWidth)
    #expect(frame.height >= PanelSizer.minHeight)
    #expect(frame.width.isFinite && frame.height.isFinite)
    controller.hide()
}

@MainActor
@Test func growingContentLeavesTheAnchoredCornerWhereItWas() {
    // The reason the panel was a fixed size for so long: growth that moves the corner
    // nearest the pointer drags every already-read line with it.
    let text = Box("Готово.")
    let controller = PanelController { _ in AnyView(Text(text.value).padding(14)) }
    controller.show(at: CGPoint(x: 300, y: 700))
    let before = controller.panel.frame
    text.value = String(repeating: "Ещё одна строка перевода. ", count: 30)
    controller.contentDidChange()
    let after = controller.panel.frame
    #expect(after.height > before.height)
    #expect(after.minX == before.minX)
    #expect(after.maxY == before.maxY)
    controller.hide()
}

@MainActor
@Test func hidingThePanelForgetsTheSizeSoTheNextPressStartsFresh() {
    let text = Box(String(repeating: "Длинный первый перевод. ", count: 30))
    let controller = PanelController { _ in AnyView(Text(text.value).padding(14)) }
    controller.show(at: CGPoint(x: 300, y: 700))
    let tall = controller.panel.frame.height
    controller.hide()
    text.value = "Да."
    controller.show(at: CGPoint(x: 300, y: 700))
    #expect(controller.panel.frame.height < tall)
    controller.hide()
}

/// A reference box so a test can change the content a `@escaping` builder closes over.
/// `@MainActor` rather than `Sendable`: everything here runs on the main actor.
@MainActor final class Box {
    var value: String
    init(_ value: String) { self.value = value }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TranslationPanel`
Expected: FAIL — `PanelController.init` takes `() -> AnyView`, and `contentDidChange` does not exist.

- [ ] **Step 3: Rewrite `TranslationPanel`'s window chrome**

In `Sources/TranslatorApp/TranslationPanel.swift`, replace `init()` and delete the doc comment about the fixed 380 × 260, replacing it with what is true now:

```swift
    /// Opened at 380 × 260 and immediately resized.
    ///
    /// The initial rect is not a design decision, it is somewhere to stand: `PanelController`
    /// measures the content and sets the real frame before the panel is ordered in. It stays
    /// non-zero because an `NSWindow` built at `.zero` reports a degenerate frame to the
    /// first layout pass, and the measurement is taken from a detached hosting view anyway.
    ///
    /// `.titled` is deliberately **absent**. A titled panel cannot be given a corner radius
    /// without the square window background showing through at the corners, and its
    /// titlebar is 22pt of chrome over a readout with no title. Dropping it costs the
    /// standard close button — `PanelView` draws its own ⨯ — and it invalidates the
    /// measurement that used to sit on `canBecomeKey`, which is why
    /// `theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive` exists.
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                   styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // The app is never active when this appears, so a panel that hid on deactivation
        // would be dismissed by the very state it is shown in. Redundant *while* the mask
        // says `.nonactivatingPanel` — that alone flips the default from true to false —
        // and load-bearing the moment anyone touches the mask, which is the case it guards.
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        // A rounded corner needs the window to stop painting: the material and the
        // `clipShape` are drawn by `PanelView`, and without these two lines the square
        // window background stays visible behind them as a grey notch in each corner.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Follows the user across desktops and sits over full-screen apps, because the
        // selection it is translating came from one.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
```

Delete the two `standardWindowButton(...)?.isHidden = true` lines — without `.titled` those accessors return nil and the lines are dead.

`canBecomeKey`, `canBecomeMain`, `constrainFrameRect`, `cancelOperation` and `keyDown` are unchanged. Update `canBecomeKey`'s doc comment: it currently says a `.titled` `NSPanel` already answers `true` either way, and the panel is no longer `.titled`, so the override may now be doing real work. Say exactly that, and point at the test.

- [ ] **Step 4: Rewrite `PanelController`**

Replace `PanelController` in the same file with:

```swift
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// Internal rather than private so the tests can drive real `NSEvent`s through it and
    /// read the frame AppKit actually settled on. The app talks to the controller.
    let panel = TranslationPanel()
    private let hosting: NSHostingView<AnyView>
    /// A second hosting view that is never installed in a window, holding the *non-scrolling*
    /// content, used only to be asked for a size.
    ///
    /// It exists because measuring the installed view would be measuring the wrong thing the
    /// moment the scrolling variant is swapped in: a `ScrollView` compresses to nothing, so
    /// the panel would report a tiny ideal height and never grow back. This one always holds
    /// the variant whose height means something.
    private let measuring: NSHostingView<AnyView>
    private var build: (Bool) -> AnyView

    private var anchor: PanelAnchor = .topLeading
    private var frozenWidth: CGFloat?
    private var userSized = false
    private var scrolls = false
    private var lastFit: CFAbsoluteTime = 0
    private var pendingFit = false

    var onEscape: () -> Void = {}
    var onEnter: () -> Void = {}

    var isVisible: Bool { panel.isVisible }

    init(content: @escaping (Bool) -> AnyView) {
        build = content
        hosting = NSHostingView(rootView: content(false))
        measuring = NSHostingView(rootView: content(false))
        super.init()
        // The panel must not be sized by its hosting view, and this line is what stops it.
        //
        // Measured on the running bundle before it existed: the panel opened **380 × 120**
        // no matter what was in it, because an `NSHostingView` installed as a window's
        // `contentView` publishes Auto Layout constraints derived from SwiftUI's *compressed*
        // measurement, and AppKit then shrinks the window to satisfy them. Content-sizing
        // does not undo that — the size is still this controller's decision, it is merely
        // computed now instead of hard-coded.
        //
        // **No test in this file can hold this**, and one was written and deleted rather
        // than kept: the shrink does not reproduce in the test process. The evidence is the
        // running bundle, measured three times before and twice after.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.onEscape() }
        panel.onEnter = { [weak self] in self?.onEnter() }
    }

    /// The real content is only knowable from inside a scene — «Открыть в окне» needs
    /// `openWindow`, and the close action needs this controller — so the builder is replaced
    /// once at launch rather than passed to `init`. This is what `setContent(_:)` used to be;
    /// it takes a builder now because the controller has to be able to rebuild the content in
    /// its other variant when the ceiling is reached.
    func setContentBuilder(_ builder: @escaping (Bool) -> AnyView) {
        build = builder
        hosting.rootView = builder(scrolls)
        measuring.rootView = builder(false)
    }

    func show(at cursor: CGPoint) {
        // Every per-presentation decision is reset here, not in `hide()`: a panel shown
        // twice without an intervening hide — which nothing does today, and which a future
        // caller might — must still start from automatic sizing.
        frozenWidth = nil
        userSized = false
        setScrolling(false)

        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        // `visibleFrame`, not `frame`: the difference is the menu bar, and placing against
        // `frame` opens a tall panel underneath it.
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = measure(previous: .zero, screen: visible)
        frozenWidth = fit.size.width
        setScrolling(fit.scrolls)
        let placement = PanelPlacement.place(cursor: cursor, size: fit.size, screen: visible)
        anchor = placement.anchor
        panel.setFrame(placement.frame, display: false)
        // `makeKeyAndOrderFront` on a `.nonactivatingPanel` gives the panel key status
        // without activating the app.
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        pendingFit = false
    }

    /// The content changed shape, so the panel may need to be a different size.
    ///
    /// Throttled to ten times a second because it is called on every streamed token and the
    /// measurement is a full SwiftUI layout pass. The throttle can only *delay* growth,
    /// never skip it: a call that arrives too soon sets `pendingFit`, and the trailing call
    /// re-measures whatever the content has become by then.
    /// - Parameter settling: the run has just ended, so this is the last resize and the one
    ///   worth animating. It also bypasses the throttle: making the final size wait up to
    ///   100ms behind a token that arrived just before it is the one delay a user would see.
    func contentDidChange(settling: Bool = false) {
        guard panel.isVisible else { return }
        if settling {
            pendingFit = false
            applyFit(settling: true)
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFit >= 0.1 else {
            guard !pendingFit else { return }
            pendingFit = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.pendingFit else { return }
                self.pendingFit = false
                self.applyFit()
            }
            return
        }
        applyFit()
    }

    /// - Parameter settling: this is the resize that follows the end of a run, rather than
    ///   one of the many during it.
    private func applyFit(settling: Bool = false) {
        lastFit = CFAbsoluteTimeGetCurrent()
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = measure(previous: panel.frame.size, screen: visible)
        setScrolling(fit.scrolls)
        guard fit.size != panel.frame.size else { return }
        let frame = PanelPlacement.reframe(current: panel.frame, newSize: fit.size,
                                           anchor: anchor, screen: visible)
        // Unanimated while a run streams, and that is not an omission. The steps are a line
        // of text at a time and arrive up to ten times a second; animating each one puts a
        // 150ms tween on top of a 100ms interval, so the animations overlap and the panel
        // shivers instead of growing. The settle is the one resize worth animating — it is
        // where the shape genuinely changes, because the warnings appear and the scrolling
        // variant is swapped out — and it happens once.
        guard settling, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func measure(previous: CGSize, screen: CGRect) -> PanelSizer.Fit {
        measuring.layoutSubtreeIfNeeded()
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        // Two passes, and the order matters. The first asks how wide the content would like
        // to be with nothing wrapping it; the second asks how tall it is *once the width is
        // settled*, because height without a width is not a number — it is a different
        // number for every width.
        let idealWidth = measuring.sizeThatFits(in: unbounded).width
        let width = PanelSizer.fit(ideal: CGSize(width: idealWidth, height: 0),
                                   frozenWidth: frozenWidth, previous: previous,
                                   screen: screen, userSized: userSized).size.width
        let idealHeight = measuring.sizeThatFits(in: CGSize(width: width,
                                                           height: .greatestFiniteMagnitude)).height
        return PanelSizer.fit(ideal: CGSize(width: idealWidth, height: idealHeight),
                              frozenWidth: frozenWidth ?? width, previous: previous,
                              screen: screen, userSized: userSized)
    }

    private func setScrolling(_ wanted: Bool) {
        guard wanted != scrolls else { return }
        scrolls = wanted
        hosting.rootView = build(wanted)
    }

    /// The user dragged an edge. That is an instruction, and it holds until the panel hides.
    func windowDidEndLiveResize(_ notification: Notification) {
        userSized = true
    }
}
```

Note the `measure` call passing `height: 0` in the first pass: `PanelSizer` treats a non-positive height as unmeasured and returns the floor, which this pass discards — only `.size.width` is read. Add a one-line comment saying so, or the next reader will think the floor is being applied twice.

- [ ] **Step 5: Wire the app to the new controller**

In `Sources/TranslatorApp/TranslatorApp.swift`:

```swift
        _panel = State(initialValue: PanelController { _ in AnyView(EmptyView()) })
```

In `configurePanel()`, the content builder takes the flag and the host reports changes:

```swift
    private func configurePanel() {
        panel.setContentBuilder { scrolls in
            AnyView(PanelHost(
                coordinator: coordinator,
                windowModel: translation,
                scrolls: scrolls,
                onCopy: { Task { await coordinator.copyResult() } },
                onOpenInWindow: { handOffToWindow() },
                onClose: {
                    coordinator.panelModel.cancel()
                    panel.hide()
                },
                onGrantPermission: {
                    PermissionsGate.requestTrust()
                    PermissionsGate.openSettings()
                },
                onContentChange: { settling in panel.contentDidChange(settling: settling) }))
        }
        ...
```

`build` must therefore be `private var build: (Bool) -> AnyView`, not a `let` — the real content is only knowable inside a scene, so it is replaced once at launch. `setContentBuilder(_:)` is written out in the controller listing above; `setContent(_:)` is gone, and `configurePanel` was its only caller.

`PanelHost` gains `scrolls`, `onClose`, `onContentChange`, and the two `onChange` hooks that drive resizing:

```swift
private struct PanelHost: View {
    let coordinator: HotkeyCoordinator
    let windowModel: TranslationViewModel
    let scrolls: Bool
    let onCopy: () -> Void
    let onOpenInWindow: () -> Void
    let onClose: () -> Void
    let onGrantPermission: () -> Void
    let onContentChange: (Bool) -> Void

    var body: some View {
        PanelView(model: coordinator.panelModel,
                  selection: coordinator.selection,
                  scrolls: scrolls,
                  adoptionRefusal: windowModel.adoptionRefusal(from: coordinator.panelModel),
                  onCopy: onCopy,
                  onOpenInWindow: onOpenInWindow,
                  onRetry: { Task { await coordinator.retry() } },
                  onGrantPermission: onGrantPermission,
                  onClose: onClose)
            // Deferred to a later turn of the main actor on purpose. These fire *during*
            // the view update that produced the new text, and resizing a window from
            // inside a SwiftUI update re-enters layout on a view AppKit is already laying
            // out. The controller's own throttle then coalesces the burst.
            .onChange(of: coordinator.panelModel.translatedText) { _, _ in
                Task { @MainActor in onContentChange(false) }
            }
            .onChange(of: coordinator.panelModel.state) { _, new in
                // A state that is no longer `.running` is the settle: the last size this
                // presentation will be asked for, and the only one animated.
                Task { @MainActor in onContentChange(new != .running) }
            }
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter TranslationPanel`
Expected: PASS, including the pre-existing key-status and Esc/Enter tests.

If `aPanelWithLittleToSayOpensSmallerThanOneWithALot` fails with both heights equal at the floor, the detached hosting view is returning `.zero` from `sizeThatFits`. Do **not** paper over it by loosening the test. Try `measuring.frame = NSRect(x: 0, y: 0, width: PanelSizer.maxWidth, height: PanelSizer.minHeight)` before `layoutSubtreeIfNeeded()`, which gives the view a starting geometry to lay out in. If it still returns `.zero`, stop and report: the measurement strategy is wrong and the spec's §8 anticipated that this is where it would show.

- [ ] **Step 7: Run the whole suite and the warnings check**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 312 tests passing.

- [ ] **Step 8: Build the bundle and check by hand**

```bash
./Scripts/make-app-bundle.sh
open build/LocalTranslator.app
```

Then, with Ollama running, select a one-word phrase in another app and press ⌥⌘T; then a long paragraph. Record in the commit message what was actually seen: the two panel sizes, whether Esc closed it, whether Enter copied and closed, and whether the corner nearest the pointer stayed put while text streamed. **If you cannot run this, say so in the commit message and leave the checks in `docs/OPEN-ITEMS.md` for Task 14 rather than claiming them.**

- [ ] **Step 9: Commit**

```bash
git add Sources/TranslatorApp/TranslationPanel.swift Sources/TranslatorApp/TranslatorApp.swift Tests/TranslatorAppTests/TranslationPanelTests.swift
git commit -m "feat(app): size the floating panel to its content"
```

---

## Task 5: Swapping the languages

**Files:**
- Modify: `Sources/TranslatorApp/TranslationViewModel.swift`
- Test: `Tests/TranslatorAppTests/TranslationViewModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TranslationViewModel.canSwapLanguages: Bool`; `TranslationViewModel.swapLanguages()`.

Domain facts the implementer needs: `sourceOverride` and `targetOverride` are `Language?`, where nil means «определить» and «по правилу» respectively. `outcome?.detectedSource` is `Language?` and is what a finished run determined. `resolvedTarget` is the target that run actually used. `outcome` and `translatedText` are cleared as a pair everywhere in this file, because an outcome describing text that is no longer on screen renders a previous run's warnings under a new run's paragraph.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/TranslationViewModelTests.swift`, following the file's existing helper for building a model with a `FakeLLMClient`:

```swift
@MainActor
@Test func swappingIsRefusedUntilBothLanguagesAreActuallyKnown() {
    // Exchanging «определить» and «по правилу» exchanges two absences. The button has to be
    // able to say so before it is pressed, which is why this is a property and not a
    // `Bool` returned by the swap.
    let model = makeModel()
    #expect(model.canSwapLanguages == false)
    model.sourceOverride = .en
    #expect(model.canSwapLanguages == false)   // the target is still «по правилу»
    model.targetOverride = .ru
    #expect(model.canSwapLanguages)
}

@MainActor
@Test func afinishedRunSuppliesTheLanguagesTheOverridesDidNot() {
    // The ordinary case: the user typed English, left both pickers alone, and pressed
    // translate. Both languages are now known — one detected, one resolved — so the swap
    // is available even though neither override was ever set.
    let model = makeModel(reply: "Готово")
    model.sourceText = "Ready"
    await model.translate()
    #expect(model.canSwapLanguages)
}

@MainActor
@Test func swappingExchangesTheLanguagesAndMovesTheTranslationIntoTheSource() {
    let model = makeModel()
    model.sourceOverride = .en
    model.targetOverride = .ru
    model.sourceText = "Ready"
    model.translatedText = "Готово"
    model.swapLanguages()
    #expect(model.sourceOverride == .ru)
    #expect(model.targetOverride == .en)
    #expect(model.sourceText == "Готово")
    #expect(model.translatedText.isEmpty)
}

@MainActor
@Test func swappingDropsTheOutcomeWithTheTextItDescribed() {
    // `outcome` and `translatedText` are cleared as a pair everywhere else in this type,
    // and this is not the place to break that: an outcome left behind would render the old
    // run's markup diffs and glossary checks under an empty pane.
    let model = makeModel(reply: "Готово")
    model.sourceText = "Ready"
    await model.translate()
    #expect(model.outcome != nil)
    model.swapLanguages()
    #expect(model.outcome == nil)
}

@MainActor
@Test func swappingWithNoTranslationYetLeavesTheSourceAlone() {
    // Pressing ⇄ before translating should exchange the pickers, not blank the text the
    // user has just typed.
    let model = makeModel()
    model.sourceOverride = .en
    model.targetOverride = .ru
    model.sourceText = "Ready"
    model.swapLanguages()
    #expect(model.sourceText == "Ready")
    #expect(model.sourceOverride == .ru)
}

@MainActor
@Test func swappingIsRefusedWhileARunIsInFlight() {
    // The running task writes into `translatedText`. Moving it out from under that task
    // would put half a translation into the source field.
    let model = makeModel(reply: "Готово")
    model.sourceOverride = .en
    model.targetOverride = .ru
    model.sourceText = "Ready"
    let run = Task { await model.translate() }
    // The state flips synchronously inside `translate()` before its first suspension.
    await Task.yield()
    if model.state == .running {
        #expect(model.canSwapLanguages == false)
    }
    await run.value
}
```

If the file's model factory is not called `makeModel`, use whatever it is called; read the file first.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TranslationViewModel`
Expected: FAIL — `canSwapLanguages` and `swapLanguages` do not exist.

- [ ] **Step 3: Write the implementation**

Add to `TranslationViewModel`, below `adopt(from:)`:

```swift
    /// The source language as the next run would resolve it, or nil if nobody knows yet.
    ///
    /// The override first, then what the last finished run detected. Not
    /// `LanguageDetector.detect(sourceText)`: detection is the *translation's* job and
    /// running it here would make a toolbar button re-detect on every keystroke, and would
    /// promise a language the run may not agree with.
    private var knownSource: Language? { sourceOverride ?? outcome?.detectedSource }
    private var knownTarget: Language? { targetOverride ?? resolvedTarget }

    /// Whether ⇄ has two languages to exchange.
    ///
    /// A property rather than a `Bool` returned by `swapLanguages()`, for the same reason
    /// `adoptionRefusal(from:)` is a property of the rule and not of the attempt: the button
    /// must answer before it is pressed, and a view that re-derived the condition would
    /// keep offering a swap for a case added later.
    var canSwapLanguages: Bool {
        state != .running && knownSource != nil && knownTarget != nil
    }

    /// Translate the other way: the languages change places and the translation becomes the
    /// new source.
    ///
    /// The translation is moved rather than copied because the alternative is worse in both
    /// directions — left in place it would be a translation of text that is no longer in the
    /// source pane, and cleared without being moved it would throw away the only thing the
    /// user has to translate back.
    func swapLanguages() {
        guard canSwapLanguages, let source = knownSource, let target = knownTarget else { return }
        sourceOverride = target
        targetOverride = source
        if !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
        }
        // Dropped with the text it described, the same pairing `translate()` maintains: an
        // outcome that outlives its text renders the previous run's markup diffs and
        // glossary checks under whatever is on screen now.
        outcome = nil
        resolvedTarget = nil
        state = .idle
    }
```

`resolvedTarget` is `private(set)`, so this compiles from inside the type.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TranslationViewModel`
Expected: PASS.

- [ ] **Step 5: Run the whole suite and the warnings check**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 318 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/TranslationViewModel.swift Tests/TranslatorAppTests/TranslationViewModelTests.swift
git commit -m "feat(app): let the window translate the other way round"
```

---

## Task 6: The window's two panes

**Files:**
- Create: `Sources/TranslatorApp/SourcePane.swift`
- Create: `Sources/TranslatorApp/TranslationPane.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift` (remove `ChunkHint`, which moves)
- Modify: `Sources/TranslatorApp/RussianCopy.swift`
- Test: `Tests/TranslatorAppTests/RussianCopyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SourcePane(model:onClear:)`, `TranslationPane(model:onCopy:)`, `RussianCopy.characterCount(_ count: Int) -> String`.

**The measurement this task must not break.** `MainWindowView.body` reads `model.translatedText`, so every streamed token invalidates it. `ChunkHint` is a separate `View` value holding a single class reference precisely so SwiftUI compares the re-created value against the previous one, finds the reference identical, and skips its body — as a computed property it ran `Chunker.chunk` in full twice per token. The character count joins it in the same type and inherits the same protection. **Do not inline either into a pane's body.**

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/RussianCopyTests.swift`:

```swift
@Test func theCharacterCountAgreesWithRussianGrammar() {
    // Through `plural`, like the chunk count, because the number comes from the user's
    // typing and every form is reachable within a sentence of it.
    #expect(RussianCopy.characterCount(1) == "1 символ")
    #expect(RussianCopy.characterCount(2) == "2 символа")
    #expect(RussianCopy.characterCount(5) == "5 символов")
    #expect(RussianCopy.characterCount(11) == "11 символов")
    #expect(RussianCopy.characterCount(21) == "21 символ")
    #expect(RussianCopy.characterCount(0) == "0 символов")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RussianCopy`
Expected: FAIL — `characterCount` does not exist.

- [ ] **Step 3: Add the copy**

In `Sources/TranslatorApp/RussianCopy.swift`, beside `chunkCount`:

```swift
    static func characterCount(_ count: Int) -> String {
        "\(count) " + plural(count, "символ", "символа", "символов")
    }
```

Run `swift test --filter RussianCopy` → PASS.

- [ ] **Step 4: Write the two panes**

Create `Sources/TranslatorApp/SourcePane.swift`:

```swift
// Sources/TranslatorApp/SourcePane.swift
import SwiftUI

/// The window's left half: what the user typed.
struct SourcePane: View {
    @Bindable var model: TranslationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Исходник") {
                Button("Очистить") { model.sourceText = "" }
                    .buttonStyle(.link)
                    .disabled(model.sourceText.isEmpty)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.sourceText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                // A placeholder and not a first line of grey text in the editor itself:
                // anything in the binding is text the user would have to delete, and would
                // be translated if they did not.
                if model.sourceText.isEmpty {
                    Text("Вставьте или наберите текст")
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) { SourceFooter(model: model).padding(6) }
        }
        .frame(minWidth: 280)
    }
}

/// A `View` of its own rather than a computed property, and that is the whole point of the
/// type.
///
/// `MainWindowView` reads `model.translatedText`, so every streamed token invalidates its
/// body and everything inlined in it. `expectedChunkCount` runs `Chunker.chunk` in full — a
/// line split, a `String.count` per block, and `enumerateSubstrings(options: .bySentences)`
/// over oversized ones — and was measured at 2 evaluations per token, for a value whose only
/// inputs cannot change while a run is streaming.
///
/// As a separate view value holding a single class reference, SwiftUI compares the re-created
/// value against the previous one, finds the reference identical, and skips its body.
/// Observation then re-runs it only when `sourceText` itself changes. The character count is
/// here for the same protection, not for tidiness.
private struct SourceFooter: View {
    let model: TranslationViewModel

    var body: some View {
        // Read once each. An earlier version read `expectedChunkCount` twice — once for the
        // test and once for the label — and so paid for chunking twice on every pass.
        let characters = model.sourceText.count
        let chunks = model.expectedChunkCount
        HStack(spacing: 6) {
            if characters > 0 {
                Text(RussianCopy.characterCount(characters))
            }
            if chunks > 1 {
                Text("·")
                Text(RussianCopy.chunkCount(chunks))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// One row, one title, one action. Shared by both panes so they cannot drift apart.
struct PaneHeader<Action: View>: View {
    let title: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            action().font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.25))
        Divider()
    }
}
```

Create `Sources/TranslatorApp/TranslationPane.swift`:

```swift
// Sources/TranslatorApp/TranslationPane.swift
import SwiftUI

/// The window's right half: what came back.
///
/// A selectable `Text` in a `ScrollView` and **not** a `TextEditor`. The pane used to be a
/// `TextEditor` bound to `.constant(model.translatedText)`, which takes a caret and silently
/// discards every keystroke — a control that accepts input and does nothing with it.
struct TranslationPane: View {
    let model: TranslationViewModel
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Перевод") {
                Button("Скопировать", action: onCopy)
                    .buttonStyle(.link)
                    // Enabled the moment the first token lands, not only at the end: an
                    // interrupted run leaves partial output the app keeps on purpose, and
                    // keeping it while refusing to copy it would be pointless. Same rule as
                    // the panel's own copy button.
                    .disabled(model.translatedText.isEmpty)
            }
            if model.translatedText.isEmpty && model.state != .running {
                VStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Здесь появится перевод")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.translatedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
        .frame(minWidth: 280)
    }
}
```

Delete `ChunkHint` from `MainWindowView.swift` — `SourceFooter` replaces it — and move its doc comment's measurement across, which the code above already does. Leave the rest of `MainWindowView` alone until Task 7; it will not compile against the removed `ChunkHint` until then, so **do Task 7 in the same working session** and commit once at the end of Task 7 if the build cannot be made green here. If you prefer a green commit at every step, defer the `ChunkHint` deletion to Task 7 and let the two coexist for one commit.

- [ ] **Step 5: Verify**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 319 tests passing.

State plainly in the commit message that the two panes were compiled, not seen: this process has no GUI automation, and neither the placeholder's position nor the empty state's appearance was observed.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/SourcePane.swift Sources/TranslatorApp/TranslationPane.swift Sources/TranslatorApp/RussianCopy.swift Tests/TranslatorAppTests/RussianCopyTests.swift
git commit -m "feat(app): give the window's two panes headers, a placeholder and an honest readout"
```

---

## Task 7: The window's toolbar and status bar

**Files:**
- Create: `Sources/TranslatorApp/RunStatusBar.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Test: `Tests/TranslatorAppTests/WarningsViewTests.swift`

**Interfaces:**
- Consumes: `SourcePane(model:)`, `TranslationPane(model:onCopy:)`, `TranslationViewModel.canSwapLanguages`, `swapLanguages()`.
- Produces: `RunStatusBar(model:status:glossaryProblem:onMute:onRetry:)`; `RunStatusBar.summary(outcome:problem:) -> String?`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/WarningsViewTests.swift`:

```swift
@Test func theCollapsedStatusBarSaysHowManyWarningsAreHidingUnderIt() {
    // A disclosure triangle with no summary is a triangle the user has no reason to press.
    // The summary must agree with `WarningsView.hasContent`: a bar that offered «0
    // предупреждений» would be a control that expands to nothing.
    #expect(RunStatusBar.summary(outcome: quietOutcome(), problem: nil) == nil)

    let dropped = MarkupDiff(expected: .paragraphBreak, actual: nil,
                             note: "dropped in translation")
    let added = MarkupDiff(expected: nil, actual: .hardLineBreak, note: "added in translation")

    #expect(RunStatusBar.summary(outcome: quietOutcome(markupDiffs: [dropped]),
                                 problem: nil) == "1 предупреждение")
    #expect(RunStatusBar.summary(outcome: quietOutcome(markupDiffs: [dropped, added]),
                                 problem: nil) == "2 предупреждения")
    #expect(RunStatusBar.summary(outcome: quietOutcome(),
                                 problem: "не сохранён") == "1 предупреждение")
}
```

`quietOutcome(documentGlossary:checks:markupDiffs:)` is the factory already at the top of
`WarningsViewTests.swift`; it is `private`, so the new test must live in that same file.
`MarkupDiff` is a struct — `MarkupDiff(expected: MarkupToken?, actual: MarkupToken?, note: String)`
— not an enum of named failures, and `MarkupToken` is the enum with `.paragraphBreak` and
`.hardLineBreak` on it. Do not invent case names.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WarningsView`
Expected: FAIL — `RunStatusBar` does not exist.

- [ ] **Step 3: Write `RunStatusBar`**

Create `Sources/TranslatorApp/RunStatusBar.swift`:

```swift
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
    let status: OllamaStatus
    var glossaryProblem: String?
    var onMute: (String) -> Void = { _ in }
    var onRetry: () -> Void = {}

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let summary, model.state == .finished {
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
            if expanded, let outcome = model.outcome, model.state == .finished {
                let warnings = WarningsView(outcome: outcome, target: model.resolvedTarget,
                                            problem: glossaryProblem, onMute: onMute)
                // `ViewThatFits` and not a bare `ScrollView`, because a `ScrollView` is
                // greedy in its scroll axis: it would sit at the full 200 under a two-line
                // warning and leave the rest blank. This takes the plain stack's own height
                // while that fits, and only falls back to scrolling once it does not.
                //
                // 200 rather than the 140 this used to be. The old number came out of the
                // window's minimum height because the warnings sat between the editors and
                // the bottom of the window whether or not anyone was reading them. Collapsed
                // by default, the region costs one row, so the ceiling can be set by what is
                // readable rather than by what the editors can spare.
                ViewThatFits(in: .vertical) {
                    warnings
                    ScrollView { warnings }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
    }

    private var summary: String? {
        Self.summary(outcome: model.outcome, problem: glossaryProblem)
    }

    @ViewBuilder private var line: some View {
        switch model.state {
        case .idle:
            Text(status.label).font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Перевожу…").font(.caption)
            }
        case .finished:
            if let outcome = model.outcome {
                Text(summary.map { "Готово за \(Int(outcome.totalMS)) мс · \($0)" }
                     ?? "Готово за \(Int(outcome.totalMS)) мс")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .interrupted:
            Text("Перевод прерван — показана та часть, что успела прийти")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            // Spec 8 pairs both failure rows — a timed-out request and an empty model reply
            // — with a retry. Reachable: `translate()` opens with `guard state != .running`,
            // and `.failed` is not `.running`. The source text is still in the editor, so
            // retrying costs the user nothing but the wait.
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить", action: onRetry).font(.caption)
            }
        }
    }

    /// How many warnings are hiding under the triangle, or nil if there are none.
    ///
    /// A static function rather than a computed property, because it is the one decision in
    /// this view that can be checked: it must agree with `WarningsView.hasContent` exactly.
    /// A summary that disagreed would offer a disclosure that expands to nothing, or hide a
    /// warning behind a triangle nobody is told to press.
    static func summary(outcome: TranslationOutcome?, problem: String?) -> String? {
        guard let outcome else { return problem.map { _ in "1 предупреждение" } }
        let warnings = WarningsView(outcome: outcome, target: nil, problem: problem)
        guard warnings.hasContent else { return nil }
        var count = outcome.markupDiffs.count
        count += outcome.checks.compactMap(DiffPresentation.describe).count
        if problem != nil { count += 1 }
        if !outcome.documentGlossary.isEmpty { count += 1 }
        return "\(count) " + RussianCopy.plural(count, "предупреждение", "предупреждения",
                                                "предупреждений")
    }
}
```

- [ ] **Step 4: Rewrite `MainWindowView`**

Replace the whole of `Sources/TranslatorApp/MainWindowView.swift` with:

```swift
// Sources/TranslatorApp/MainWindowView.swift
import SwiftUI
import TranslationCore

struct MainWindowView: View {
    @Bindable var model: TranslationViewModel
    @Bindable var settings: AppSettings
    /// Plain `let`, not `@Bindable`: nothing here binds to the store, it is only read
    /// (`lastProblem`) and messaged (`mute`/`save`). Observation still tracks the reads.
    let glossary: GlossaryStore
    /// The value, not the `OllamaStatusModel`. The window only reads the status; the app
    /// owns the model and the refresh schedule.
    let status: OllamaStatus
    var onCopy: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SourcePane(model: model)
                TranslationPane(model: model, onCopy: onCopy)
            }
            Divider()
            RunStatusBar(model: model, status: status,
                         glossaryProblem: glossary.lastProblem,
                         onMute: mute,
                         onRetry: { Task { await model.translate() } })
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // `russianName`, not `shortCode`. The settings name these languages in words and
            // this window used to name them in codes — one vocabulary under two names, which
            // is exactly what `CONTEXT.md` exists to prevent.
            Picker("Из", selection: $model.sourceOverride) {
                Text("Определить").tag(Language?.none)
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag(Language?.some($0)) }
            }
            Button {
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(!model.canSwapLanguages)
            .help("Перевести в обратную сторону")
            Picker("В", selection: $model.targetOverride) {
                Text("По правилу").tag(Language?.none)
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag(Language?.some($0)) }
            }
            Picker("Тон", selection: $model.toneOverride) {
                Text("По умолчанию").tag(Tone?.none)
                ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag(Tone?.some($0)) }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.state == .running {
                // ⌘. is the macOS convention for cancelling an operation in progress.
                // Without it a run is unstoppable from the keyboard: ⌘↩ belongs to
                // «Перевести», which is not on screen while the run is going.
                Button("Отмена") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Перевести") { Task { await model.translate() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.isHealthy)
            }
        }
    }

    /// Muting is two steps and only the first is guaranteed. `mute` updates the in-memory
    /// list, so the term is already hidden for this session; `save` is what makes that
    /// survive a restart, and it can fail — most importantly when the glossary never
    /// loaded, in which case `GlossaryStore` refuses rather than overwriting the user's
    /// file. A `try?` here would leave the user believing the term is gone for good.
    private func mute(_ term: String) {
        ... carried over verbatim from the current file, all three catch clauses ...
    }
}
```

Carry `mute(_:)` across unchanged, comments and all three catch clauses included.

In `TranslatorApp.swift`, pass the copy action to the window:

```swift
        Window("Толмач", id: TranslatorApp.mainWindowID) {
            MainWindowView(model: translation, settings: settings,
                           glossary: glossary, status: statusModel.status,
                           onCopy: { GeneralPasteboard.write(translation.translatedText) })
                .task { await statusModel.refresh(interactiveModel: settings.interactiveModel) }
        }
```

Check `GeneralPasteboard`'s actual API in `Sources/TextCapture/GeneralPasteboard.swift` before writing this line — it may be `async`, in which case wrap it in `Task { … }`. Do not guess.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter WarningsView` → PASS
Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 320 tests passing.

- [ ] **Step 6: Check by hand and commit**

```bash
./Scripts/make-app-bundle.sh && open build/LocalTranslator.app
```

Open the window from the menu bar and check: the toolbar renders, ⇄ is disabled before the first run and enabled after it, the right pane refuses the caret, the status bar collapses and expands. **Record exactly what was observed in the commit message, and nothing that was not.**

```bash
git add Sources/TranslatorApp/RunStatusBar.swift Sources/TranslatorApp/MainWindowView.swift Sources/TranslatorApp/TranslatorApp.swift Tests/TranslatorAppTests/WarningsViewTests.swift
git commit -m "feat(app): rebuild the main window around a toolbar and a collapsible status bar"
```

---

## Task 8: The probe carries model sizes

**Files:**
- Modify: `Sources/OllamaKit/OllamaClient.swift` (one public initialiser)
- Modify: `Sources/TranslatorApp/OllamaStatusModel.swift`
- Modify: `Sources/TranslatorApp/ModelsViewModel.swift`
- Test: `Tests/TranslatorAppTests/OllamaStatusModelTests.swift`, `Tests/TranslatorAppTests/ModelsViewModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `OllamaModel.init(name:sizeBytes:)` (public); `OllamaProbe.installedModels() async throws -> [OllamaModel]`; `ModelsViewModel.installed: [OllamaModel]`; `ModelsViewModel.installedNames: [String]`; `OllamaStatus.residentModelNames` is *not* introduced — `residentModels()` keeps returning `[String]`.

Why: `OllamaModel.sizeBytes` already exists and is thrown away at the protocol boundary. The «Модели» pane needs it. `RunningModel` carries only a name, so `residentModels()` is left alone.

- [ ] **Step 1: Update the stubs and write the failing test**

In `Tests/TranslatorAppTests/OllamaStatusModelTests.swift`, change `StubProbe`:

```swift
struct StubProbe: OllamaProbe {
    var installed: [OllamaModel] = []
    var resident: [String] = []
    var failure: Error?
    func installedModels() async throws -> [OllamaModel] { if let failure { throw failure }; return installed }
    func residentModels() async throws -> [String] { if let failure { throw failure }; return resident }
}
```

Every existing call site that passes `installed: ["aya-expanse:8b"]` becomes
`installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 0)]`. Update them all; the compiler will list them.

In `Tests/TranslatorAppTests/ModelsViewModelTests.swift` do the same to `FlakyProbe`, then append:

```swift
@MainActor
@Test func theInstalledListKeepsTheSizeTheServerReported() {
    // The size is what makes the list worth showing: a user deciding whether to pull a
    // second model is deciding about disk space. It exists in `OllamaModel` already and
    // used to be discarded at the protocol boundary.
    let probe = StubProbe(installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 5_100_273_664)])
    let models = ModelsViewModel(probe: probe, puller: { _ in .init { $0.finish() } })
    await models.reload()
    #expect(models.installed.first?.sizeBytes == 5_100_273_664)
    #expect(models.installedNames == ["aya-expanse:8b"])
    #expect(models.availability(of: "aya-expanse:8b") == .installed)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Models`
Expected: FAIL to compile — `OllamaModel` has no accessible initialiser and the protocol still returns `[String]`.

- [ ] **Step 3: Implement**

In `Sources/OllamaKit/OllamaClient.swift`:

```swift
public struct OllamaModel: Sendable {
    public let name: String
    public let sizeBytes: Int64
    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }

    /// Public so the app's tests can build one. A struct with public stored properties gets
    /// only an internal memberwise initialiser, which is invisible across the module
    /// boundary — the reason this is spelled out rather than synthesised.
    public init(name: String, sizeBytes: Int64) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}
```

In `Sources/TranslatorApp/OllamaStatusModel.swift`:

```swift
protocol OllamaProbe: Sendable {
    /// The whole model and not just its name: `sizeBytes` is what the settings pane shows,
    /// and flattening to `[String]` here is where it used to be lost.
    func installedModels() async throws -> [OllamaModel]
    func residentModels() async throws -> [String]
}

struct LiveOllamaProbe: OllamaProbe {
    let client: OllamaClient
    init(client: OllamaClient = OllamaClient()) { self.client = client }
    func installedModels() async throws -> [OllamaModel] { try await client.models() }
    func residentModels() async throws -> [String] { try await client.ps().map(\.name) }
}
```

`OllamaStatusModel.refresh` discards the value already (`_ = try await probe.installedModels()`), so it needs no change.

In `Sources/TranslatorApp/ModelsViewModel.swift`:

```swift
    var installed: [OllamaModel] = []

    /// The names alone, for the picker and for `availability(of:)`. A computed property
    /// rather than a second stored one, so the two cannot fall out of step.
    var installedNames: [String] { installed.map(\.name) }
```

and replace every `installed.contains(...)` with `installedNames.contains(...)`, and
`options(selecting:)`'s body with:

```swift
        installedNames.contains(selected) ? installedNames : installedNames + [selected]
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter Models` → PASS
Run: `swift test --filter Ollama` → PASS

- [ ] **Step 5: Whole suite and warnings**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 321 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/OllamaKit/OllamaClient.swift Sources/TranslatorApp/OllamaStatusModel.swift Sources/TranslatorApp/ModelsViewModel.swift Tests/TranslatorAppTests/OllamaStatusModelTests.swift Tests/TranslatorAppTests/ModelsViewModelTests.swift
git commit -m "feat(ollama): keep the model size the probe already had"
```

---

## Task 9: One size for every settings tab, and «Основные» in sections

**Files:**
- Create: `Sources/TranslatorApp/SettingsPane.swift`
- Modify: `Sources/TranslatorApp/SettingsGeneralView.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `View.settingsPane()`, and the constants `SettingsPane.width` (560) and `SettingsPane.height` (480).

- [ ] **Step 1: Write the wrapper**

Create `Sources/TranslatorApp/SettingsPane.swift`:

```swift
// Sources/TranslatorApp/SettingsPane.swift
import SwiftUI

/// The one size and form style every settings tab uses.
///
/// A modifier rather than three copies of two lines, because three copies is how the window
/// came to resize on every tab switch: the panes fixed 420, 420, 520 × 440 and 420, and a
/// `TabView` takes the size of the tab currently showing.
struct SettingsPane: ViewModifier {
    /// Wide enough for the glossary's four columns, which is the widest thing in the window.
    static let width: CGFloat = 560
    /// Tall enough for the models tab, which is the longest.
    static let height: CGFloat = 480

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .frame(width: Self.width, height: Self.height)
    }
}

extension View {
    func settingsPane() -> some View { modifier(SettingsPane()) }
}
```

- [ ] **Step 2: Rewrite «Основные»**

In `Sources/TranslatorApp/SettingsGeneralView.swift`, replace `body` with sections and an
always-visible access row, keeping `isTrusted`, its doc comment, `.onAppear` and
`.onReceive` exactly as they are:

```swift
    var body: some View {
        Form {
            Section("Доступ") {
                // Visible whether or not the permission is granted, unlike the block this
                // replaces. A row that appears only on failure makes the form jump when the
                // user comes back from System Settings, and leaves a user whose permission
                // *is* granted with no way to learn the permission exists.
                LabeledContent("Доступ к тексту в других программах") {
                    if isTrusted {
                        Label("предоставлен", systemImage: "checkmark.circle")
                            .foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        Label("нет доступа", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).labelStyle(.titleAndIcon)
                    }
                }
                if !isTrusted {
                    Text("Приложению нужен доступ в разделе «Конфиденциальность и "
                         + "безопасность» → «Универсальный доступ». Главное окно работает "
                         + "и без него.")
                        .font(.caption).foregroundStyle(.secondary)
                        // A `Text` given less width than it wants truncates rather than
                        // wrapping, and the clause that would go is the one saying where the
                        // setting actually lives.
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Открыть настройки системы") { PermissionsGate.openSettings() }
                }
            }

            Section("Сочетание клавиш") {
                LabeledContent("Сочетание клавиш") { HotkeyRecorder(combo: $settings.hotkey) }
                Text("Нажмите на поле и наберите новое сочетание. Нужен хотя бы один из "
                     + "модификаторов ⌃, ⌥ или ⌘ — иначе сочетание отняло бы обычную клавишу "
                     + "у всех остальных программ.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Языки") {
                Picker("Основной язык", selection: $settings.primaryLanguage) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                Picker("Рабочий язык", selection: $settings.workingLanguage) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                // Equal languages make `targetLanguage(forDetected:)` return the same
                // language whatever the source is, so every translation becomes a round trip
                // into the primary language and the app quietly stops doing anything useful.
                // Say so rather than swapping the value back or refusing the selection: the
                // user is mid-edit, and only they know which of the two pickers they meant.
                if languagesCollide {
                    Label {
                        Text("Основной и рабочий языки совпадают: любой текст, на каком бы "
                             + "языке он ни был, будет переводиться на "
                             + "\(settings.primaryLanguage.russianName) — включая текст, "
                             + "который уже на нём написан. Выберите разные языки.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
                Text("Направление выбирается само: текст на основном языке переводится в "
                     + "рабочий, любой другой — в основной.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Перевод") {
                Picker("Тон по умолчанию", selection: $settings.defaultTone) {
                    ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
            }

            Section("Поведение") {
                // «по хоткею» is not padding. `autoCopy` is read in exactly one place —
                // `HotkeyCoordinator.runTranslation` — so a translation done in the main
                // window never touches the clipboard whatever this says. Spec §7.2 puts
                // automatic copying in the panel's section deliberately; the label used to
                // promise the whole app and quietly mean a third of it.
                Toggle("Копировать результат по хоткею автоматически", isOn: $settings.autoCopy)
                Toggle("Прогревать модель при запуске", isOn: $settings.warmUpOnLaunch)
            }
        }
        .settingsPane()
        .onAppear { isTrusted = PermissionsGate.isTrusted() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = PermissionsGate.isTrusted()
        }
    }
```

- [ ] **Step 3: Verify**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 321 tests passing, unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/TranslatorApp/SettingsPane.swift Sources/TranslatorApp/SettingsGeneralView.swift
git commit -m "feat(app): give the settings one size and «Основные» its sections"
```

---

## Task 10: «Модели» absorbs «Дополнительно»

**Files:**
- Modify: `Sources/TranslatorApp/SettingsModelsView.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift` (the `TabView`)
- Delete: `Sources/TranslatorApp/SettingsAdvancedView.swift`
- Modify: `Sources/TranslatorApp/RussianCopy.swift`
- Test: `Tests/TranslatorAppTests/RussianCopyTests.swift`

**Interfaces:**
- Consumes: `ModelsViewModel.installed: [OllamaModel]`, `installedNames`, `View.settingsPane()`.
- Produces: `RussianCopy.modelSize(_ bytes: Int64) -> String`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/RussianCopyTests.swift`:

```swift
@Test func aModelSizeIsWrittenInRussianNotation() {
    // Comma for the decimal separator, and the locale pinned rather than taken from the
    // system: every string in this app is Russian and there is no localisation to switch,
    // so on a machine set to en_US the default format would put «4.8 ГБ» in a Russian
    // sentence next to «4,8» elsewhere.
    #expect(RussianCopy.modelSize(5_100_273_664) == "4,8 ГБ")
    #expect(RussianCopy.modelSize(0) == "0,0 ГБ")
}
```

- [ ] **Step 2: Run to verify it fails, then implement**

Run: `swift test --filter RussianCopy` → FAIL.

In `RussianCopy.swift`:

```swift
    /// A model's size on disk, in the notation the rest of this app uses.
    static func modelSize(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes.formatted(.number.precision(.fractionLength(1))
            .locale(Locale(identifier: "ru_RU"))) + " ГБ"
    }
```

Run: `swift test --filter RussianCopy` → PASS.

- [ ] **Step 3: Rewrite the pane**

In `Sources/TranslatorApp/SettingsModelsView.swift`, wrap the existing contents in sections,
add the two new ones, and take on the two controls from «Дополнительно» verbatim — their
captions and their comments, including the pinned locale on the temperature and the
`RussianCopy.plural` on the chunk size:

```swift
    var body: some View {
        Form {
            Section("Ollama") {
                LabeledContent("Состояние") {
                    Label(status.label, systemImage: status.isHealthy
                          ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isHealthy ? .green : .orange)
                        .labelStyle(.titleAndIcon)
                }
                Button("Проверить снова") { Task { await refresh() } }
            }

            Section("Модель для перевода") {
                ModelChoice(title: "Модель для перевода",
                            selection: $settings.interactiveModel, models: models)
            }

            Section("Установленные модели") {
                if models.installed.isEmpty {
                    Text(models.error == nil
                         ? "Ollama не сообщила ни одной модели."
                         : "Список не получен.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(models.installed, id: \.name) { model in
                        LabeledContent(model.name) {
                            Text(resident.contains(model.name)
                                 ? RussianCopy.modelSize(model.sizeBytes) + " · в памяти"
                                 : RussianCopy.modelSize(model.sizeBytes))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Загрузить модель") {
                ... the existing download field, button, progress, status and error, unchanged ...
            }

            Section("Дополнительно") {
                TextField("Держать модель в памяти", text: $settings.keepAlive)
                Text("Формат Ollama: «30m», «1h», «0» — выгружать сразу, «-1» — держать всегда. "
                     + "Холодная загрузка стоит около двух секунд, поэтому короткое значение "
                     + "делает каждое первое нажатие хоткея заметно медленнее.")
                    .font(.caption).foregroundStyle(.secondary)
                ... the chunk-size Stepper and the temperature Slider, carried over from
                    SettingsAdvancedView with their captions and comments verbatim ...
            }
        }
        .settingsPane()
        .task { await reload() }
    }
```

The pane now needs the status and the resident list. Give it what it needs rather than a
second probe: add `let status: OllamaStatus` and `var onRefresh: () async -> Void` as
properties supplied by `TranslatorApp`, and put the resident names on `ModelsViewModel`:

```swift
    /// Which installed models Ollama currently holds in memory. Read from `/api/ps` on the
    /// same reload as the installed list, so the two describe the same moment.
    var resident: [String] = []
```

set in `reload()` from `probe.residentModels()` inside the same `do` block, and cleared to
`[]` in the `catch` alongside `listIsConfirmed = false`. Add a test for that in
`ModelsViewModelTests.swift`:

```swift
@MainActor
@Test func aFailedReloadStopsClaimingAnythingIsInMemory() {
    // The installed list survives a failure on purpose — emptying it would blank the picker
    // — but «в памяти» is a claim about right now, and right now the server did not answer.
    var probe = StubProbe(installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 1)],
                          resident: ["aya-expanse:8b"])
    let models = ModelsViewModel(probe: probe, puller: { _ in .init { $0.finish() } })
    await models.reload()
    #expect(models.resident == ["aya-expanse:8b"])
    probe.failure = URLError(.cannotConnectToHost)
    let broken = ModelsViewModel(probe: probe, puller: { _ in .init { $0.finish() } })
    await broken.reload()
    #expect(broken.resident.isEmpty)
}
```

- [ ] **Step 4: Update the `TabView` and delete the fourth tab**

In `TranslatorApp.swift`:

```swift
        Settings {
            TabView {
                SettingsGeneralView(settings: settings)
                    .tabItem { Text("Основные") }
                SettingsModelsView(settings: settings, models: models,
                                   status: statusModel.status,
                                   onRefresh: {
                                       await statusModel.refresh(
                                           interactiveModel: settings.interactiveModel)
                                   })
                    .tabItem { Text("Модели") }
                SettingsGlossaryView(glossary: glossary, settings: settings)
                    .tabItem { Text("Глоссарий") }
            }
            .task { await statusModel.refresh(interactiveModel: settings.interactiveModel) }
        }
```

```bash
git rm Sources/TranslatorApp/SettingsAdvancedView.swift
```

- [ ] **Step 5: Verify**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 324 tests passing.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/TranslatorApp Tests/TranslatorAppTests Sources/TranslatorApp/RussianCopy.swift
git commit -m "feat(app): show what is installed, and fold «Дополнительно» into «Модели»"
```

---

## Task 11: `GlossaryOrder`

**Files:**
- Create: `Sources/TranslatorApp/GlossaryOrder.swift`
- Test: `Tests/TranslatorAppTests/GlossaryOrderTests.swift`

**Interfaces:**
- Consumes: `GlossaryEntry` from `TranslationCore` (`term: String`, `translations: [String: String]`, `doNotTranslate: Bool`).
- Produces: `GlossaryOrder.visibleOrder(entries:query:) -> [Int]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TranslatorAppTests/GlossaryOrderTests.swift`:

```swift
import Testing
import TranslationCore
@testable import TranslatorApp

private func entries(_ terms: String...) -> [GlossaryEntry] {
    terms.map { GlossaryEntry(term: $0) }
}

@Test func theListIsShownInAlphabeticalOrderByIndex() {
    // Indices, not entries. Rows are identified by their position in the file because a
    // term is not unique — the file is hand-edited and «Добавить термин» appends a blank —
    // so the order has to be a permutation the caller can map back.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "глоссарий", "тон"),
                                           query: "")
    #expect(order == [1, 2, 0])
}

@Test func aBlankTermSortsFirstSoANewRowIsWhereTheUserIsLooking() {
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", ""), query: "")
    #expect(order.first == 1)
}

@Test func theSearchMatchesTermsCaseInsensitively() {
    let order = GlossaryOrder.visibleOrder(entries: entries("Толмач", "чанк", "глоссарий"),
                                           query: "ЧАН")
    #expect(order == [1])
}

@Test func theSearchAlsoMatchesTheTranslations() {
    // A user looking for the English side of a pair should not have to remember the Russian.
    var withTranslation = GlossaryEntry(term: "чанк")
    withTranslation.translations["en"] = "chunk"
    let order = GlossaryOrder.visibleOrder(entries: [GlossaryEntry(term: "тон"), withTranslation],
                                           query: "chunk")
    #expect(order == [1])
}

@Test func anEmptyQueryHidesNothing() {
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "тон"), query: "   ")
    #expect(order.count == 2)
}

@Test func duplicateTermsBothSurviveInsteadOfCollapsingIntoOne() {
    // The failure index identity exists to prevent. Two hand-written rows with the same
    // term are two rows, and an order that returned one of them would silently drop the
    // other's translation.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "чанк"), query: "")
    #expect(order.sorted() == [0, 1])
}

@Test func theOrderIsStableForTermsThatCompareEqual() {
    // Two equal terms must keep their file order, or the two rows swap places whenever the
    // list is recomputed and the user cannot tell which one they were editing.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "чанк", "чанк"), query: "")
    #expect(order == [0, 1, 2])
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter GlossaryOrder`
Expected: FAIL — `GlossaryOrder` does not exist.

- [ ] **Step 3: Implement**

Create `Sources/TranslatorApp/GlossaryOrder.swift`:

```swift
// Sources/TranslatorApp/GlossaryOrder.swift
import Foundation
import TranslationCore

/// Which glossary rows to show, and in what order — as indices into `entries`.
///
/// Indices and not values, because rows are identified by position and that is deliberate:
/// `term` is the only other candidate and nothing uniques it. The file is hand-edited and
/// «Добавить термин» appends a blank one, so keying by term collapses two real rows into one
/// and silently drops the other's translation.
///
/// **The caller must not call this on every keystroke.** The pane recomputes the order only
/// when the set of rows or the query changes — adding, removing, searching, re-reading the
/// file — and never while a term is being typed. Live re-sorting would move the row out from
/// under the caret the moment its first letter changed, and live re-filtering would make it
/// vanish the moment it stopped matching the search.
enum GlossaryOrder {
    static func visibleOrder(entries: [GlossaryEntry], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = entries.indices.filter { index in
            needle.isEmpty || matches(entries[index], needle)
        }
        // `enumerated` and the index tiebreaker make this a stable sort. Swift's `sort` is
        // not guaranteed stable, and two rows with the same term swapping places between
        // recomputations would leave the user unable to tell which one they were editing.
        return matching
            .map { (index: $0, term: entries[$0].term.lowercased()) }
            .sorted { left, right in
                left.term == right.term ? left.index < right.index : left.term < right.term
            }
            .map(\.index)
    }

    private static func matches(_ entry: GlossaryEntry, _ needle: String) -> Bool {
        if entry.term.lowercased().contains(needle) { return true }
        return entry.translations.values.contains { $0.lowercased().contains(needle) }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter GlossaryOrder` → PASS, 7 tests.

- [ ] **Step 5: Whole suite and warnings**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 331 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/GlossaryOrder.swift Tests/TranslatorAppTests/GlossaryOrderTests.swift
git commit -m "feat(app): order and filter the glossary without moving rows under the caret"
```

---

## Task 12: The glossary pane

**Files:**
- Create: `Sources/TranslatorApp/GlossaryList.swift`
- Modify: `Sources/TranslatorApp/SettingsGlossaryView.swift`

**Interfaces:**
- Consumes: `GlossaryOrder.visibleOrder(entries:query:)`, `View.settingsPane()`.
- Produces: nothing later tasks depend on.

Everything currently in `SettingsGlossaryView` that is not layout — `entryBinding`'s
bounds-checking in both directions, `persist()`'s three catch clauses, `reload()`, the
translation binding's "empty means absent" rule, the muted-terms section, the file-path
caption and the disabled «Показать файл в Finder» — is carried over **verbatim, comments
included**. The pane gains a header and loses its bespoke sizing.

- [ ] **Step 1: Add the search and selection state**

In `SettingsGlossaryView`:

```swift
    @State private var query = ""
    @State private var order: [Int] = []
    @State private var selection: Set<Int> = []

    /// Recomputed here and nowhere else. See `GlossaryOrder`'s doc comment: recomputing on
    /// every keystroke would move the row the user is editing out from under the caret.
    private func reorder() {
        order = GlossaryOrder.visibleOrder(entries: glossary.file.entries, query: query)
        selection = selection.filter { order.contains($0) }
    }
```

Call `reorder()` from `.onAppear`, from `.onChange(of: query)`, at the end of `reload()`, and
after every add and remove. Do **not** call it from `entryBinding`'s setter.

- [ ] **Step 2: Write the header and list**

Create `Sources/TranslatorApp/GlossaryList.swift` holding `GlossaryHeader` (the search field,
the count, the language picker and the ± buttons) and the row view moved out of
`SettingsGlossaryView`:

```swift
// Sources/TranslatorApp/GlossaryList.swift
import SwiftUI
import TranslationCore

struct GlossaryHeader: View {
    @Binding var query: String
    @Binding var language: Language
    let count: Int
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Поиск", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
            Text("\(count) " + RussianCopy.plural(count, "термин", "термина", "терминов"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Перевод на", selection: $language) {
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 140)
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Добавить термин")
            Button(action: onRemove) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Удалить выделенные термины")
        }
    }
}

/// A view of its own so each row owns one `Binding<GlossaryEntry>` and SwiftUI can tell the
/// rows apart; also the only place that knows how an empty translation field maps onto the
/// dictionary.
struct GlossaryEntryRow: View {
    ... moved verbatim from SettingsGlossaryView, comments included ...
}
```

`RussianCopy.plural` needs a «термин / термина / терминов» call — it is generic over the
three forms already, so no change to `RussianCopy` is required.

- [ ] **Step 3: Rewrite the pane's body**

```swift
    var body: some View {
        Form {
            Section {
                if let problem = glossary.lastProblem {
                    Label { Text(problem) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption).foregroundStyle(.red)
                }
                GlossaryHeader(query: $query, language: languageBinding,
                               count: glossary.file.entries.count,
                               canRemove: !selection.isEmpty,
                               onAdd: add, onRemove: removeSelected)
            }

            Section("Термины") {
                if glossary.file.entries.isEmpty {
                    Text("Глоссарий пуст. Термины из него попадают в каждый перевод — "
                         + "добавьте первый кнопкой «плюс».")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if order.isEmpty {
                    Text("Ничего не найдено.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    // By index, and not a `Table`. Two independent reasons, both
                    // load-bearing. `Table` needs a stable identity per row, and rows have
                    // none: `term` is the only candidate, nothing on the path into
                    // `file.entries` uniques it — the file is hand-edited and «Добавить
                    // термин» appends a blank — so keying by term collapses two real rows
                    // into one and silently drops the other's translation.
                    List(order, id: \.self, selection: $selection) { index in
                        GlossaryEntryRow(entry: entryBinding(index),
                                         language: editingLanguage,
                                         onRemove: { remove(at: index) })
                    }
                    .frame(minHeight: 200)
                }
            }

            if !glossary.file.mutedTerms.isEmpty {
                ... the muted-terms section, unchanged ...
            }

            Section {
                HStack {
                    Button("Показать файл в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([glossary.url])
                    }
                    .disabled(!fileExists)
                    Button("Перечитать файл") { reload() }
                }
                ... the file-path caption, unchanged ...
            }
        }
        .settingsPane()
        .onAppear { reorder() }
        .onChange(of: query) { _, _ in reorder() }
    }

    private func add() {
        glossary.file.entries.append(GlossaryEntry(term: ""))
        persist()
        reorder()
    }

    /// Descending, so each removal cannot shift the index of one not yet removed.
    private func removeSelected() {
        for index in selection.sorted(by: >) where glossary.file.entries.indices.contains(index) {
            glossary.file.entries.remove(at: index)
        }
        selection = []
        persist()
        reorder()
    }
```

`remove(at:)` gains a `reorder()` after its `persist()`.

- [ ] **Step 4: Verify**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 331 tests passing, unchanged.

Say in the commit message that the pane was compiled, not seen.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/GlossaryList.swift Sources/TranslatorApp/SettingsGlossaryView.swift
git commit -m "feat(app): give the glossary a search, a count and multiple selection"
```

---

## Task 13: The menu bar says whether Ollama is up

**Files:**
- Modify: `Sources/TranslatorApp/OllamaStatusModel.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift`
- Test: `Tests/TranslatorAppTests/OllamaStatusModelTests.swift`

**Interfaces:**
- Consumes: `OllamaStatus`.
- Produces: `OllamaStatus.menuBarSymbol: String`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/OllamaStatusModelTests.swift`:

```swift
@Test func theMenuBarGlyphSaysWhetherOllamaIsAnswering() {
    // The icon is the only thing this app renders when nothing is open, and until now it
    // said the same thing whether or not the app could translate at all.
    #expect(OllamaStatus.running(modelResident: true).menuBarSymbol == "character.bubble")
    #expect(OllamaStatus.running(modelResident: false).menuBarSymbol == "character.bubble")
    #expect(OllamaStatus.notRunning.menuBarSymbol == "exclamationmark.bubble")
    // Unknown is not a failure — it is the first second of the app's life, and a warning
    // glyph there would cry wolf on every launch.
    #expect(OllamaStatus.unknown.menuBarSymbol == "character.bubble")
}
```

- [ ] **Step 2: Run to verify it fails, then implement**

Run: `swift test --filter Ollama` → FAIL.

In `OllamaStatus`:

```swift
    /// Exhaustive with no `default:` on purpose: a fourth case should fail to compile here
    /// rather than silently keep the healthy glyph.
    var menuBarSymbol: String {
        switch self {
        case .unknown, .running: "character.bubble"
        case .notRunning: "exclamationmark.bubble"
        }
    }
```

- [ ] **Step 3: Wire it into the scene**

In `TranslatorApp.swift`:

```swift
        MenuBarExtra {
            MenuContent(status: statusModel.status,
                        onRefresh: {
                            await statusModel.refresh(interactiveModel: settings.interactiveModel)
                        })
        } label: {
            // The `MenuBarExtra(_:systemImage:)` convenience initialiser takes no view, and
            // `warmUp()` needs one to hang a `.task` on — this label is the only thing the
            // app renders at launch. Its title argument was only ever an accessibility
            // label, so that is restored explicitly rather than dropped.
            Image(systemName: statusModel.status.menuBarSymbol)
                .accessibilityLabel("Толмач")
                .task { await launch() }
        }
```

and `MenuContent`:

```swift
private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    let status: OllamaStatus
    let onRefresh: () async -> Void

    var body: some View {
        Text(status.label)
        Divider()
        Button("Открыть окно перевода") { ... unchanged ... }
        SettingsLink { Text("Настройки…") }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }
}
```

Hanging `.task` on menu content is not reliable across macOS versions, so the refresh is
driven from where the state is known to change instead. Add to `launch()`, after the warm-up:

```swift
        await statusModel.refresh(interactiveModel: settings.interactiveModel)
```

and add to `PanelHost` a state hook that refreshes after a hotkey run ends, passed in from
`configurePanel()` as `onRunFinished`:

Fold it into the state hook Task 4 already added, rather than adding a second `onChange` on
the same value:

```swift
            .onChange(of: coordinator.panelModel.state) { _, new in
                Task { @MainActor in
                    onContentChange(new != .running)
                    if new != .running { await onRunFinished() }
                }
            }
```

with `onRunFinished` supplied as
`{ await statusModel.refresh(interactiveModel: settings.interactiveModel) }`, and the same
refresh added to `MainWindowView` via `.onChange(of: model.state)` passed in as a closure.

**This is the honest limit of it, and it must be written down rather than implied:** there is
no timer, so between a launch, a settings visit and a finished translation the glyph can lag
reality. Put that sentence in `OllamaStatus.menuBarSymbol`'s doc comment.

- [ ] **Step 4: Verify**

Run: `swift build --build-tests 2>&1 | grep -c warning` → `0`
Run: `swift test` → 332 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/OllamaStatusModel.swift Sources/TranslatorApp/TranslatorApp.swift Tests/TranslatorAppTests/OllamaStatusModelTests.swift
git commit -m "feat(app): let the menu bar icon say whether Ollama is answering"
```

---

## Task 14: The documentation the change owes

**Files:**
- Modify: `docs/OPEN-ITEMS.md`
- Modify: `docs/PLATFORM-TRAPS.md`
- Modify: `CLAUDE.md`
- Create: `docs/history/2026-07-30-ui-redesign-ledger.md`

**Interfaces:** none.

- [ ] **Step 1: Replace the panel's entry in `docs/OPEN-ITEMS.md`**

The accepted limitation «**The panel is a fixed 380 × 260.** Nothing resizes it.» is no longer
true. Delete it and record what replaced it, including the numbers: 300…560 pt wide, 120 pt to
60 % of `visibleFrame` tall, width frozen per presentation, height monotonic within a run,
manual resize held until the panel hides.

Add to the manual-checks table every row from §8 of the spec that Task 4 and Task 7 did not
already close, and strike the ones they did. In particular: the key-status check is **not**
owed to a human — `theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive` covers
it in-process, at `.prohibited` activation policy, where `isKeyWindow` has one possible cause.
Say that, rather than leaving a human a check the suite already makes.

- [ ] **Step 2: Update `docs/PLATFORM-TRAPS.md`**

Add the `NSHostingView` measuring trap: an installed hosting view measures what it is showing,
so a `ScrollView` in the content makes `sizeThatFits` report a compressed height, and the fix
is a second detached hosting view holding the non-scrolling variant. Point at
`PanelController.measuring`.

- [ ] **Step 3: Update `CLAUDE.md`**

Three claims in it are now false and must be corrected, not merely amended:

- «The app layer» section: the two `TranslationViewModel` instances and the ordering inside a
  press are unchanged, but add that the panel sizes itself and name `PanelSizer` and the
  anchor.
- The traps index: `NSPanel` framing, sizing, key status → add `PanelSizer.swift`.
- The «Where the reasoning lives» table: add the new spec and this plan's ledger.

Do not delete the sentence about scene order being load-bearing. It is still true and still
the reason the `MenuBarExtra` is first.

- [ ] **Step 4: Write the ledger**

`docs/history/2026-07-30-ui-redesign-ledger.md`, following the shape of the existing ledgers
in that directory: what each task actually did, what was rejected and why, what the plan got
wrong, and — most importantly — **which of the hand checks were actually performed and what
was seen**. A ledger that claims a screenshot nobody took is worse than one that says the
check is still owed.

- [ ] **Step 5: Verify and commit**

Run: `swift test` → 332 tests passing.

```bash
git add docs CLAUDE.md
git commit -m "docs(app): record what the UI redesign changed and what it still owes a human"
```

---

## Self-review notes

Checked against the spec section by section:

- §3.1 form → Task 4 (style mask, `isOpaque`, `backgroundColor`) and Task 3 (material, radius, ⨯).
- §3.2 content → Task 3.
- §3.3 sizing → Task 2 (rules) and Task 4 (measurement, throttle).
- §3.4 anchoring → Task 1.
- §3.5 manual resize → Task 4 (`windowDidEndLiveResize`, reset in `show`).
- §3.6 motion → Task 4: `applyFit(settling:)` animates only the settle, at 0.15 s ease-out,
  and skips the animation entirely under Reduce Motion. The first draft of this plan left it
  out; that was a gap, not a decision, and it is closed.
- §4.1 toolbar → Task 7. §4.2 panes → Task 6. §4.3 swap → Task 5. §4.4 status bar → Task 7.
  §4.5 size → Task 7. §4.6 decomposition → Tasks 6 and 7.
- §5.1 shape → Task 9. §5.2 «Основные» → Task 9. §5.3 «Модели» → Tasks 8 and 10.
  §5.4 «Глоссарий» → Tasks 11 and 12.
- §6 menu bar → Task 13.
- §7.1 pure types → Tasks 1, 2, 5, 11. §7.2 probe → Task 8. §7.3 files → all. §7.4 rules →
  Global Constraints.
- §8 hand checks → Task 14, with Task 4 and Task 7 closing what they can.
- §9 not in scope → nothing in this plan does any of it.

Test-count arithmetic assumes every listed test is added and none is deleted: 289 → 296 → 306
→ 307 → 312 → 318 → 319 → 320 → 321 → 324 → 331 → 331 → 332. Treat the numbers as a
checksum, not a target: if a count is off, find out why before continuing.
