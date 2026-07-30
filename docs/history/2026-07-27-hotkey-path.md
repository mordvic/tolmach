> Historical record of the build. Where this and the code disagree, the code is right.
>
> Copied verbatim from the session ledger that was written while the plan was executed.
> It records what was found, what was ruled, and what was rejected — including defects in
> the plan itself. It is not maintained: it is the account of a build that has finished.

# SDD ledger — plan: docs/superpowers/plans/2026-07-27-hotkey-path.md

Branch: feat/translation-engine
Started: 2026-07-27
Baseline: 192 tests, swift build and swift build --build-tests both at zero warnings.

Pre-flight, done while writing the plan rather than after: the three riskiest
pieces were compiled and run standalone instead of reasoned about.
  - HotkeyCombo: found a REAL defect. `case kVK_F1...kVK_F12` traps at run time,
    because the function-key virtual codes descend (F1=122, F12=111). Replaced
    with an explicit list. The rest of the type printed exactly the values Task 2
    asserts.
  - HotkeyManager's C-callback bridge (InstallEventHandler + Unmanaged +
    MainActor.assumeIsolated) registers, replaces, unregisters twice without
    trapping, and refuses an invalid combo. It also registered from a plain CLI
    binary with NO Accessibility grant — independent confirmation of the plan's
    claim that the hotkey needs no permission.
  - Two test-syntax risks: a trailing closure followed by `== false` inside a
    #expect argument, and nonisolated(unsafe) on a LOCAL var captured by a
    @Sendable closure. Both compile.

Pre-flight fix after the plan was committed: Task 1's second test was
un-failable. It timed 50 calls to isTrusted() and asserted under a second, but
AXIsProcessTrustedWithOptions returns immediately whether or not it prompts and
posts its dialog asynchronously — so the prompting variant would have passed it
too. That is the fifth un-failable test caught on this project. Replaced with a
`trustOptions(prompting:)` function and an assertion on the dictionary each
entry point builds, which is the only part a test process can actually observe.

P3-1: complete (commits fecac0e..0d78737, review Approved, 194 tests)
P3-1: CONTROLLER ERROR, caught by the implementer — the mutation I prescribed
  (point isTrusted() at trustOptions(prompting: true)) does NOT fail the test,
  because the test calls trustOptions directly and never calls isTrusted() at
  all. It pins the builder, not the wiring. They ruled out a stale build, then
  mutated the builder itself, which did fail, and reported the gap instead of
  hiding it. Reviewer confirmed the diagnosis by reading.
P3-1: ruling on that gap — leave it. isTrusted() is one line whose only possible
  defect is passing `true`, which produces a system dialog on EVERY hotkey press;
  Task 12's manual pass cannot miss it. Closing it needs a mutable static or an
  injectable seam, and the seam would break Task 5's use of PermissionsGate
  .isTrusted as a bare () -> Bool default argument. Reviewer agreed the trade
  is right.
P3-1: finding — the brief's test file did not compile: @testable import does not
  re-export a module's own imports, so kAXTrustedCheckOptionPrompt was out of
  scope without naming ApplicationServices. Task 2's test has the identical trap
  with Carbon's cmdKey — both fixed in the plan before Task 2 is dispatched.
P3-1: controller follow-up (0d78737) — the script's identity check was a
  substring grep that then signed with a hardcoded literal, so it could match one
  identity and hand codesign another. It now signs with the name it matched.
P3-1: note — this machine has 0 codesigning identities, so the ad-hoc branch is
  what runs, and the Accessibility grant will need re-issuing after every
  rebuild. Verified end to end: Signature=adhoc, the bundle assembles and launches.
P3-1: note — implementer corrected the old script header, which claimed ad-hoc
  was "enough for a stable Accessibility grant". Exactly backwards.

P3-2: implemented (commit 2118c14), review Needs fixes, 4 Important
P3-2: the implementer found TWO defects in the brief before review, and both were
  mine:
  - The brief's printableName ABORTS THE PROCESS. HIToolbox detects concurrent
    TIS/TSM use and kills it rather than returning an error. My pre-flight scratch
    binary could never have caught it — it was single-threaded. Reviewer
    reproduced: 8 threads x 400 calls, SIGABRT 3/3 without a lock, survives 3/3
    with one. Note it also PASSES under a narrow --filter, so the bug hides.
  - The mutation the brief itself prescribed for carbonModifiers was not caught,
    because the test asserted all four flags OR'd together — where swapping
    optionKey and controlKey is a no-op — despite its name promising per-flag.
    Sixth un-failable-or-vacuous test caught on this project, and mine.
P3-2: review findings, all reproduced with real values rather than argued:
  - Codable synthesis bypassed the masking init, so a hand-edited or stale JSON
    value decodes unmasked and compares unequal to the same combination recorded
    fresh. Exactly what the type's doc comment says the mask prevents, and Task 7
    persists this to UserDefaults. The existing round-trip test was vacuous here:
    its input was already masked on the way in.
  - printableName returned invisible CONTROL CHARACTERS for 17 of 128 key codes,
    because it guarded only length > 0. F13 rendered as «⌥⌘» + U+0010 — the user
    cannot tell which key they recorded. 13% of the key space.
  - Two tests were keyboard-layout dependent. Not hypothetical: the Russian
    layout is installed ON THIS MACHINE and maps 0x11 to Е, so `swift test` would
    go red whenever the author had it selected. For a Russian-language app that
    is a debugging session lost to an OS setting.
  - The lock's comment claimed more than the lock delivers: it serialises our
    calls but cannot exclude AppKit's own unlocked main-thread TIS calls.
P3-2: fix round 1/5 (5 addressed, 0 open — commit f43d843, 203 tests).
  Layout independence was PROVEN rather than argued: the implementer stubbed
  printableName's success path to return «Ж» and re-ran, showing the new tests
  pass and the old assertions produce ⌥⌘Ж. They also showed only the new decode
  test catches the Codable mutation, which is the direct evidence that the old
  round-trip test was vacuous.
P3-2: complete (commits 0d78737..f43d843, 203 tests, clean build 0 warnings)
P3-2: deferred — eleven named key glyphs and the functionKeys branch have no
  test. Reviewer executed all of them: 14/14 and 12/12 correct today, so this is
  coverage breadth, not a live defect. The F-number derives from the array index,
  so a reorder silently renumbers.

P3-3: complete (commits 77e4484..3260325, review Approved, 213 tests)
P3-3: the implementer found ANOTHER real defect in my plan, this one only visible
  with two instances alive. Both HotkeyManagers install a handler on the
  process-wide GetEventDispatcherTarget(), so every handler is offered every
  hot-key event. Measured: with the brief's fixed `id: 1` and no ID check, the
  most recently installed handler took the FIRST manager's press
  (firstFired 0, secondFired 1) and a foreign hot key with signature 0x5A5A5A5A
  also ran the closure. Fixed with per-registration ids from a main-actor counter
  and eventNotHandledErr on mismatch so the event reaches its real owner. The
  reviewer reproduced the numbers to the digit and confirmed handlers run
  most-recently-installed-first with noErr ending the chain.
P3-3: the brief's mutation story was also wrong, and the implementer said so.
  Removing the unregister() at the top of register does NOT make the app answer
  to both combinations — InstallEventHandler refuses a duplicate proc+userData
  with -9866, so register returns false and the app silently keeps the OLD
  shortcut. The test still catches it.
P3-3: the implementer explicitly stress-tested Task 2's killer against this code
  — 154k registrations against 1.7M off-main TIS lookups, 3/3 clean — because the
  same single-threaded pre-flight had missed it once.
P3-3: one self-reported claim was a FALSE alarm and the reviewer said so:
  `registered` is not left stale on the InstallEventHandler failure path, because
  unregister() runs first and nils it.
P3-3: MainActor.assumeIsolated is supported but not provable here. The reviewer
  built an NSApplication.run() scratch app and confirmed a background-posted
  event drains on the main thread with the handler seeing isMainThread. What
  nobody can establish from a test process is that the OS posts REAL hot-key
  presses into GetMainEventQueue() rather than a private one. Task 10.
P3-3: controller follow-up (3260325) — two review minors taken as tests rather
  than comments: registeringTwiceOnOneInstanceSucceedsBothTimes is now the
  assertion that actually depends on RemoveEventHandler (the old comment claimed
  a test proved it when that test passes with the call deleted), and
  aQueuedPressOfThePreviousShortcutIsDroppedAfterAChange pins why the counter is
  per-registration rather than per-instance. Both mutation-verified.
P3-3: NOTE FOR TASK 7 — `guard status == noErr else { unregister(); return false }`
  destroys a working registration when the NEW combination is refused (reachable:
  a combo already held in-process returns -9878). The settings path must
  re-register the previous combo on failure, not just show an error.
P3-3: deferred — a narrow off-main teardown race: Unmanaged.passUnretained means
  the callback's pointer is non-owning, so a last release landing off-main can
  interleave with an executing handler. Needs an off-main release of a @MainActor
  object; failure mode is a trap, not corruption.

P3-4: complete (commit cdb790c + controller doc/plan follow-up, review Approved, 221 tests)
P3-4: TWO more defects in my brief, both found by the implementer and both
  confirmed by the reviewer with numbers:
  - [[String: Data]] randomises the declared type order. Three runs, three
    different scrambles, never the original; a types.first consumer saw
    public.html where the original said public.utf8-plain-text in 2 of 3. The
    board itself preserved 20/20 random permutations, so the dictionary was the
    only thing destroying it. Changed to an ordered [[Flavour]] — a deviation
    from the interface the plan pinned, and the reviewer added the argument that
    settles it: [[String: Data]] == is order-insensitive, so under the pinned
    type the synthesised Equatable could never have detected its own defect.
  - The brief's changeCount test was VACUOUS: with a captured value of 0 the
    assertion `pb.changeCount > before.changeCount` reads 2 > 0 and passes.
    Seventh vacuous-or-unfailable test caught on this project. It matters because
    Task 5 compares against this value to detect the ⌘C.
P3-4: PLATFORM HAZARD, same shape as Task 2's TIS abort. Two threads reading
  pasteboardItems for the SAME NAME abort the process with an uncaught
  NSException — 10/10 on a shared object AND on fresh objects for the same name,
  0/10 for distinct names. The exception name varies (value not absent /
  NSRangeException) so nothing may match on it. NSPasteboard.general is one
  shared name, so the app is exposed.
P3-4: two things carried into Task 5's brief before dispatch, both from the
  reviewer:
  - clipboardText() must hold ONE process-wide serial section across the entire
    take -> post ⌘C -> poll -> read -> restore sequence. A lock, not @MainActor:
    the poll busy-waits up to half a second and would stall the run loop.
  - THE PLAN'S POLL WAS WRONG. clearContents() bumps changeCount BEFORE any data
    is written and the subsequent write does not bump it again, so returning on
    the first observed change samples the copying app's cleared-but-empty window
    and yields nil — an intermittent «выделите текст» on a good selection. The
    loop now requires a non-nil string.
P3-4: three things a snapshot provably cannot put back, all measured and now
  recorded in the type's own documentation rather than only in a report: file
  promises are downgraded while the board still LOOKS intact (fulfilment calls
  back to an owner that is now this app), ownership is unpreservable by any
  implementation, and changeCount is monotonic and server-owned so a clipboard
  manager sees one extra entry per hotkey press.
P3-4: note — a 64 MB flavour costs ~19 ms round trip. Not a hotkey hazard.
P3-4: note — string(forType:) newline-joins a multi-item board ("A\nB").

P3-5: complete (commits 5dbc905..c80155b, review Approved, 228 tests)
P3-5: MODIFIER BLEED — the biggest open question in the capture path, raised by
  the implementer and settled by the reviewer with three harnesses. It IS real,
  and it happens at event CONSTRUCTION, not at post: CGEvent(keyboardEventSource:)
  pre-loads the live hardware modifier state, so an event built while ⌥⌘ was held
  came out already carrying CMD+OPT, and one built while ⇧ was held carried SHIFT.
  The two `flags = .maskCommand` assignments overwrite it completely — with them
  the app receives exactly CMD in every configuration, without them ⌥⌘C. The
  posting tap is NOT the variable: .cgSessionEventTap, .privateState and
  .combinedSessionState are identical, and clearing modifiers first changes
  nothing. End to end with ⌥⌘ held, the real clipboardText() returned the
  selection in 13 ms and restored a planted sentinel intact.
  The fix was already in the code but read like tidiness — one careless
  "simplification" from silently producing exactly that failure. Now labelled.
P3-5: implementer found two more defects in the brief — the pinned init produced
  three non-Sendable-function-value warnings (errors in Swift 6 mode) because a
  reference to a plain static func as a value is not Sendable; and the snapshot
  was taken before the CGEvent guard, so a failure to build the events still ran
  a full restore, which per Task 4 transfers pasteboard ownership and downgrades
  file promises for nothing.
P3-5: they also disproved the brief's own comment: the force cast does NOT trap.
  CFString as! AXUIElement succeeds silently and hands the AX API a bogus element
  that answers -25202, so CFGetTypeID is the only guard. The brief's
  `// swiftlint:disable:next force_cast` was wrong twice over — there is no
  SwiftLint anywhere in this repo, and it implied a trap that does not happen.
P3-5: note — accessibilityText() silently returns nil in any process without an
  NSApplication: AXUIElementCreateSystemWide answers cannotComplete in a trusted
  CLI and starts answering .success the moment NSApplication.shared is touched.
  The menu-bar app is fine; a headless helper would fail silently forever.
P3-5: controller follow-up (c80155b) — AXUIElementSetMessagingTimeout(0.25).
  The reviewer measured a wedged frontmost app blocking kAXFocusedUIElement for
  1.503 s on 10 consecutive probes, after which read() falls through to the
  clipboard path and spends its full half second too: two seconds of synchronous
  blocking before the user is told «выделите текст». Healthy case is 22 ms.
  Also removed a tautological #expect and documented the one failure the function
  cannot contain — a copy landing after the deadline overwrites the just-restored
  clipboard.
P3-5: THE REVIEWER OVERWROTE THE USER'S CLIPBOARD with a sentinel during the
  end-to-end harness. Told the user.

P3-6: complete (commit 771dea5, 237 tests, clean build 0 warnings)
P3-6: EIGHTH weak test of mine caught. The brief's mutation B (replace
  screen.minX with 0) did NOT fail aScreenWithANonZeroOriginIsRespected as
  predicted: both its assertions are one-sided bounds, and the mutation pushes
  the panel INWARD — from x = -1886 to x = 0, 1886pt from the pointer at the far
  edge of that display — where `0 >= -1920` still holds. A bound that only
  catches outward placement cannot see inward. Fixed by pinning the exact origin
  alongside the two prescribed lines, left byte-identical.
P3-6: implementer added a 33k-case sweep asserting the panel is never off-screen
  and never over the pointer; it kills mutation A at 486 grid points rather than
  one hand-picked cursor. Mutation A also showed the flip becomes DEAD CODE when
  clamping runs first — the clamp lands the panel flush at maxX so the flip's
  test reads false.
P3-6: they established the flip can only cover the cursor when EVERY on-screen
  placement would — both axes must clamp back across it, which needs a panel
  exceeding about half the screen in both dimensions. Geometric necessity, not
  an ordering flaw. Reviewed by controller rather than a separate agent: pure
  arithmetic, and the implementer had already done the adversarial pass.
P3-6: rejected as unreachable and said so — negative CGSize, NaN cursor,
  CGRect.null/.infinite as screen.

P3-7: complete (commit e020624, 248 tests, clean build 0 warnings)
P3-7: THREE defects found beyond the brief, one of them serious:
  - ⌘ COMBINATIONS NEVER REACHED THE RECORDER. AppKit routes a Command-bearing
    key-down through key-equivalent dispatch before keyDown sees it, so the
    brief's control gave the app's own menu items first refusal on exactly what
    it exists to record — including the shipped default ⌥⌘T. ⌘W would have closed
    the settings window and ⌘Q quit the app, mid-recording. Fixed with
    performKeyEquivalent(with:) guarded on isRecording. Their mutation M12 is the
    brief's recorder verbatim, failing.
  - The corrupt-value guard was half a guard: the brief fell back to .default on
    undecodable bytes but not on a value that decodes cleanly and is unusable.
    {"keyCode":17,"modifiers":0} is well-formed JSON, a well-formed HotkeyCombo,
    and a bare «T» — which HotkeyManager.register refuses, producing the same
    unrecoverable no-hotkey state the fallback exists to prevent.
  - onRecord was assigned in makeNSView, which runs once and freezes that call's
    Binding. Moved to updateNSView.
P3-7: they challenged the brief's "the recorder is checked by hand, no view
  tests" and were right — that is true of what it DRAWS, false of what it
  DECIDES. Synthetic NSEvents need neither a window nor a running NSApplication,
  measured at ~10 ms headless. Six real tests now cover masking, refusal, Esc,
  menu precedence and a modifier-only press.
P3-7: they caught one of their OWN tests vacuous — M14 passed because the combo
  they recorded happened to equal HotkeyCombo.default, so the staleness assertion
  could not tell success from failure. Rewritten to differ in both fields.
  15 mutations run, 14 killed; the one survivor is documented as unobservable by
  design (HotkeyCombo re-masks, so HotkeyComboTests defends it instead).
P3-7: no plist leak — confirmed data(forKey:) routes through InMemoryDefaults's
  object(forKey:) override, and the test now asserts the bytes are visible before
  relying on it, since that connection is an undocumented implementation detail.
P3-7: reviewed by controller rather than a separate agent (248 green, Russian
  copy checked, clean build). The implementer's own adversarial pass was deeper
  than a review round would have added.
P3-7: owed to a human — that ⌘W/⌘Q are captured rather than firing menu items in
  the real bundle. The AppKit dispatch-order link is the one thing not
  exercisable headlessly.

P3-8: complete (commit 7e250fe, 258 tests, clean build 0 warnings)
P3-8: NINTH vacuous test of mine, and this one was worse than weak — it was
  UNFALSIFIABLE. showingThePanelDoesNotChangeWhichApplicationIsFrontmost passes
  with .nonactivatingPanel deleted, and the implementer showed no mutation can
  move frontmostApplication from a test process at all: in a standalone binary
  driven to .regular policy, NSApp.activate flipped isActive to true and
  frontmostApplication STILL read Safari. Replaced with the measurable half of
  spec 7.2's sentence: panel.isKeyWindow reads true with the bit and false
  without it, and the test process runs at .prohibited policy where activation
  is impossible — so isKeyWindow == true has exactly one cause. That is «key
  without active», which is the whole design. The frontmost lines stay, labelled
  as documentation rather than proof.
P3-8: real defect the brief left in — NSWindow.constrainFrameRect rewrites the
  frame on order-in for .titled windows. A pointer 5pt from the left screen edge
  produced a panel at x = 221 where PanelPlacement said 19, silently overruling
  Task 6's flip-and-clamp by 202pt (Stage Manager reserves that strip). The
  machine-independent half is the menu bar: a frame crossing it is pulled down on
  every Mac. Overridden to return the rect untouched, which is safe because
  PanelPlacement already clamps to visibleFrame. The brief's placement test could
  not see it — it uses the screen centre, where the constraint does nothing.
P3-8: my comment on canBecomeKey was WRONG and they corrected it: a .titled
  NSPanel answers true with AND without .nonactivatingPanel. canBecomeKey is
  permission; .nonactivatingPanel is the grant.
P3-8: 12 mutations, 9 killed. One survivor was a real gap and they closed it —
  placing against screen.frame instead of visibleFrame put the panel's top edge
  under the menu bar. The other two survivors are redundant lines kept as
  insurance, and they said so rather than claiming coverage.
P3-8: panel.delegate = nil in the brief was dead code — verified nil before and
  after, removed. thePanelLandsOnTheScreenThatHoldsTheCursor no longer skips
  silently; it uses try #require and did exercise a real screen here.
P3-8: deferred — a 1pt band where CGRect.contains sends an edge-of-screen cursor
  to the wrong display on a multi-monitor rig. NSMouseInRect is the fix,
  unverifiable on this single-display machine.

P3-9: complete (commit 972ff02, 264 tests, clean build 0 warnings)
P3-9: my direction-line question turned out to be a DEFECT, and neither of the
  two options I offered. `outcome` is nil for the whole streaming phase while
  `resolvedTarget` still holds the PREVIOUS run's target, so the brief's header
  renders «язык не определён → русский» over a translation heading for English.
  Fixed by requiring both halves to come from one run — the view model's own
  documented invariant, since outcome is dropped at the instant translatedText
  is. Warnings gated the same way instead of on .finished.
P3-9: the implementer rendered all six states through a real NSHostingView and
  LOOKED, which found a second defect: at 380pt the failure row clipped
  «…командой «oll…» — the half that says what to do — because an HStack truncates
  a Text rather than wrapping it. Fixed and re-rendered.
P3-9: they took the brief's one-test scope apart honestly. The selection switch
  and the «Скопировать» disabled state are restatements and they said so rather
  than padding the count; the status line is not — it carries spec 8's retry rule
  and the verbatim pass-through of the view model's Russian — so it became a
  PanelStatus value type with three tests. 8 mutations, 8 killed.
P3-9: NOTE FOR TASK 10 — do not size the panel by fittingSize or
  intrinsicContentSize. Both measure 97.0pt regardless of content; SwiftUI's
  ideal size gives 97 for the short state and 301 for the long one.

P3-10: complete (commit cb798cd, 279 tests, clean build 0 warnings)
P3-10: THE DEFECT THIS PLAN EXISTED TO FIND, and only a live run could. The
  brief's Step 5 showed the panel BEFORE the capture, which breaks the capture.
  Measured with a standalone probe: with the panel on screen, system-wide
  kAXFocusedUIElement resolves to Толмач / AXWindow and kAXSelectedTextAttribute
  returns -25205; with the app not running, the same query returns TextEdit's
  AXTextArea and the selected sentence. .nonactivatingPanel keeps the app
  INACTIVE but the panel still becomes KEY, and AX focus follows key, not active.
  Fixed with willCapture/afterCapture hooks — panel down before the read, up
  after. The implementer did NOT isolate why the clipboard fallback also came
  back empty and recorded it as a suspicion rather than a finding.
P3-10: second defect — the panel opened at 380x120 whatever was in it, because
  NSHostingView as contentView publishes constraints from SwiftUI's COMPRESSED
  measurement and AppKit shrinks the window. The permission prompt truncated to
  one line, cutting the clause naming where the setting lives. Fixed with
  hosting.sizingOptions = []. They wrote a test for it and DELETED it because all
  three mutations passed — it proved nothing.
P3-10: the brief's own re-entrancy test was vacuous (it awaited the first press
  to completion). Rewritten to run concurrently. 12 mutations, 12 killed.
P3-10: read() runs on Task.detached(.userInitiated) — a bare Task {} would
  inherit the main actor, which is the bug being avoided. Off-main AX safety was
  probed rather than taken from Task 5's note: identical results and error codes.
P3-10: a refused re-registration restores the previous combination, tested
  against a real -9878. Re-registration is a re-arming withObservationTracking;
  the brief's "compare on each panel show" alternative CANNOT work, because after
  a change the old combination is what is registered, so the press that would
  trigger the comparison never arrives.
P3-10: registration moved BEFORE the warm-up. warmUp() awaits a request with a
  120 s timeout, so registering after it leaves the app's only shortcut dead for
  as long as Ollama takes to answer — two minutes if it accepts and never replies.

P3-10 LIVE RUN — PARTIAL, AND BLOCKED. Verified: no window at launch; ⌥⌘T fires
  and the panel appears at the pointer; the source app stays frontmost across
  every press; the panel floats over other apps; the permission prompt appears at
  press time; the clipboard sentinel survived every press; autoCopy is off by
  default.
  NOT verified and NOT claimed: none of the five checks in their real form, since
  no capture succeeded after the fix; the ⌘W/⌘Q recorder check; «Открыть в окне»;
  live re-registration. The clipboard evidence is NOT a pass of check 3 — the ⌘C
  fallback never ran.
  OBSERVED AND UNEXPLAINED: Esc and Enter did not reach the panel while another
  app was frontmost, two attempts. Flagged, not fixed — a synthetic event may
  route differently from a physical one.
  BLOCKER: the bundle is ad-hoc signed and there are 0 codesigning identities on
  this machine, so every rebuild voids the Accessibility grant. Creating the
  certificate needs Keychain Access and is the user's decision.

P3-11: complete (commit 3c3705f, 279 tests). Spec 8 pairs both failure rows with
  a retry and Plan 2 built the states but never the button. Done by the
  controller directly — five lines, and reachability confirmed by reading
  translate()'s guard rather than assuming.

P3-12: complete (commit cb3e345, 280 tests, clean build 0 warnings)
P3-12: the signing identity the user created is picked up and the script prints
  the stable-identity line. The grant SURVIVED a rebuild — verified properly:
  the first rebuild left the CDHash unchanged, so they rebuilt in release to get
  a genuinely different binary (df2a6681 -> 2786d88e) and the grant held. The DR
  is certificate-based, not cdhash-based. Task 10's blocker is gone.

P3-12 MANUAL PASS — the first successful end-to-end hotkey translation in the
  project, and the hole Task 10 left is closed.
  - Capture works in all three kinds of app, and the paths were separated by
    instrumenting NSPasteboard.changeCount per press rather than assumed:
    TextEdit took the Accessibility path (count unchanged), Safari AND Obsidian
    both fell back to ⌘C (+2 each). Safari falling back is worth knowing.
  - The clipboard test finally ran: marker set, hotkey used on a different
    selection in both fallback apps, real ⌘V — the marker came back exactly. The
    user's real clipboard (a six-type Russian article) was snapshotted as raw
    Data beforehand and restored byte-identically.
  - TASK 10's ESC/ENTER MYSTERY IS SOLVED AND IS NOT A DEFECT. Both reach the
    panel with TextEdit frontmost; Enter copied and closed without the Return
    reaching TextEdit. Task 10 used System Events `key code`, which posts to the
    frontmost APPLICATION; a CGEvent on .cghidEventTap routes to the key WINDOW,
    which is the panel. The panel's comment was correct as written.
  - ⌘W and ⌘Q are captured by the recorder, not routed to the menu — window
    stayed open, app stayed alive. Task 7's performKeyEquivalent works.
  - Bare key refused. Live re-registration works with no relaunch. «Открыть в
    окне» carries both texts.
  - The real grant could not be revoked (a system security setting), so they
    substituted a copy under a different bundle identifier — genuinely
    never-granted and unable to touch the real record. First-launch dialog shown,
    panel prompt rendered with its FULL untruncated sentence, button opened the
    right pane. Cleanup verified.

P3-12 TWO DEFECTS FOUND, REPORTED NOT FIXED, both correctly out of scope:
  1. A finished translation with no warnings loses 86pt of a 260pt panel — 9
     visible lines while running, 4½ when finished. Cause PROVEN rather than
     guessed: patching out the warnings block temporarily restored all 9 lines.
     WarningsView renders empty but the ViewThatFits/frame(maxHeight: 120) slot
     still claims height. The fix carries a design choice.
  2. NSApp.activate does not activate — after «Открыть в окне» the window is
     front and AXMain but the app is not frontmost, so typing still goes
     elsewhere. Same root cause makes the Settings window swallow its first
     click. Needs cooperative activation.
P3-12: not reached — an Electron app besides Obsidian, a sub-100 ms timing
  figure, multi-monitor behaviour.

PLAN 3 COMPLETE. 280 tests, swift build and swift build --build-tests both at
zero warnings. All three plans done.
