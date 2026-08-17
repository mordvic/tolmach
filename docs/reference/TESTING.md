# Testing

`CLAUDE.md` covers the mechanics — Swift Testing rather than XCTest, sentence-shaped test
names, `InMemoryDefaults` instead of a real `UserDefaults` suite. This document covers the
part that is not mechanical and that gets violated by default.

---

## The rule: a test you have not seen fail is not a test

**Break the thing the test pins, run it, watch it go red, restore.** Every test added to this
project was put through that, and it is the only reason the shapes below were caught rather
than shipped.

This is not a counsel of perfection. It is the cheapest available check on the one failure a
test suite cannot report about itself: that it is green for the wrong reason. A suite of 285
tests that would stay green under the defect they exist to prevent is worth less than five
tests that have each been watched to fail.

Two habits that make it cheap:

- Mutate the **implementation**, not the test. If you find yourself editing the assertion to
  make it fail, the assertion was never about the implementation.
- Mutate what the test's *name* claims. A test called
  `carbonModifiersTranslateEachFlagSeparately` should die when two flags are swapped. If it
  does not, the name is a lie and the name is the part everyone reads.

---

## Nine shapes that were caught this way

Every one of these was written by someone competent, looked correct in review, and did not
fail under the defect it named. They are listed because they are counter-intuitive: none of
them looks weak until you try to kill it.

**1. Asserting the cleared state instead of the behaviour.**
A test named "a statusless line must not reset the progress bar" asserted that
`pullProgress` was `nil` *after the loop had ended and cleared it*. Deleting the guard it
named changed nothing. The interesting behaviour happened **between** lines, and a test that
can only look after the stream ends cannot see it. Fixed by extracting the per-line fold into
a directly callable `apply(_:)`.

**2. Flags OR'd together, where the mutation is a no-op.**
`carbonModifiersTranslateEachFlagSeparately` asserted all four modifiers combined, plus
command alone. Swapping `optionKey` and `controlKey` is a no-op in the combined value
(`a | b == b | a`), so the test passed under exactly the swap its name promised to catch.
Assert each flag separately, or assert a golden literal.

**3. One-sided bounds.**
A placement test asserted `frame.minX >= screen.minX` and `frame.maxY <= screen.maxY`. The
mutation moved the panel 1886 pt *inward*, to the far edge of the display — and `0 >= -1920`
still held. A bound that only catches outward movement cannot see inward movement. Pin the
exact value when the exact value is what you mean.

**4. An unfalsifiable environment property.**
`showingThePanelDoesNotChangeWhichApplicationIsFrontmost` passed with `.nonactivatingPanel`
deleted — and worse, it was shown that **no** code change could make it fail: a test process
driven to `.regular` policy and activated still read another app as frontmost. Replaced with
`panel.isKeyWindow`, which reads true with the style bit and false without it, in a process
where activation is impossible — so the assertion has exactly one cause.

**5. Testing the builder while claiming to test the wiring.**
A test asserted `trustOptions(prompting:)` produced the right dictionary, under a comment
about `isTrusted()` never prompting. It never called `isTrusted()`. Pointing that function at
the wrong argument left the test green. Sometimes this is the honest best available — but say
so in the test, rather than letting the name imply coverage that is not there.

**6. A tautology.**
`#expect(type(of: reader) == SelectionReader.self)`. It cannot fail. The test's real value was
that the line above it compiled; the assertion was noise that read as coverage. Deleted, and
the compile-time value stated in a comment instead.

**7. A timing assertion both branches satisfy.**
Fifty calls asserted to finish under a second, on the theory that a prompting variant would
block. `AXIsProcessTrustedWithOptions` returns immediately either way and posts its dialog
asynchronously, so the bug would have passed.

**8. A fixture that hides the property.**
An ordering test streamed 400 identical characters and asserted the result was a prefix of
the reply. Any permutation of identical characters is byte-identical, so it pinned reversal
and nothing else. Varied the tail to cycling digits and position became observable.

**9. A test whose input was already normalised.**
A `UserDefaults` round-trip test claimed to prove that decoding applies the modifier mask —
but its input had been masked on the way *in*, so it was vacuous with respect to the
invariant. Decode literal unmasked JSON instead.

There is a tenth worth knowing that is not a test shape but a measurement shape: a **cached
build reports zero warnings because nothing recompiled**. Check warnings with a clean build
or after touching the file, never from cache.

---

## What cannot be tested here

The agent environment has no GUI automation. Accept it and say so rather than writing
something that looks like coverage:

- **Anything drawn.** Layout, truncation, colour, whether a control is visible. `swift test`
  can construct a SwiftUI view; it cannot tell you what it looks like.
- **Real key presses.** Carbon delivers hot-key events through the main run loop, and a test
  process has none. `SendEventToEventTarget` drives the handler and proves the `userData`
  bridge and the closure — it proves nothing about the OS noticing the key.
- **Live Accessibility.** `AXUIElementCreateSystemWide` answers `kAXErrorCannotComplete` in
  any process without an `NSApplication`, so a test process gets nil from
  `accessibilityText()` no matter what is selected on screen.
- **The synthetic ⌘C.** Posted from a test process it goes nowhere; posted from a trusted one
  it lands in whatever the developer has in front of them, which is not a test's business.

### What stands in for it: the standalone probe

The technique that established most of this project's macOS findings, and the reason they are
measurements rather than guesses. Build a small executable **outside the repository**,
`swiftc` it directly, and have it do the one thing a test cannot:

- Bring up a real `NSApplication` so Accessibility answers at all, then query
  `kAXFocusedUIElement` with and without the panel on screen — this is how "AX focus follows
  the *key* window" was established, and it is why the panel is hidden during a capture.
- Install a passive `CGEvent` tap, hold modifiers, post the synthetic ⌘C and read what the tap
  sees — this is how the modifier-bleed hazard was measured, and it is why the explicit
  `flags` assignment in `SelectionReader` is labelled load-bearing.
- Run N threads against one API and count aborts — this is where "10 out of 10, and 0 out of
  10 for distinct names" comes from.

Two rules for probes: never write into the developer's documents or clipboard without
restoring, and put the result **into a code comment at the site it justifies**, because the
probe itself is throwaway and the measurement is not.

---

## Where the evidence goes

A measurement belongs in a comment at the code it justifies — that is the house style, and
`CLAUDE.md` states the contract that comes with it. This document holds only what has no
single site: the shapes above, which are about how tests fail rather than about any one test.

Acceptance-run numbers go in `docs/reference/BASELINE.md`. Things a human still has to look at go in
`docs/reference/OPEN-ITEMS.md`.
