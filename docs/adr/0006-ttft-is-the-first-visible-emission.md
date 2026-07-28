# Time to first token measures the first thing the user could see

`TranslationOutcome.timeToFirstTokenMS` is the interval from the start of the call to the first
`onToken` call carrying actual чанк content — **not** the first raw token off the wire.

This is the number the product's one hard requirement is stated in (under a second for the
hotkey path) and the number `swift run acceptance` gates on at 1000 ms. It is worth being
precise about what it counts.

## Why not the wire

A chunk whose answer shape is undecided is buffered: the cleaner has to see the whole first
line before it can tell a preamble from the translation, and a fenced reply stays buffered to
the end. So the first raw token can arrive hundreds of milliseconds before anything can be put
on screen.

Measuring the wire therefore reports a latency the user never experiences. It was measured that
way once, and the sub-second guarantee it certified was nominal — the acceptance run passed
while the panel stayed blank.

## Why `nil` rather than a sentinel

`timeToFirstTokenMS` is `Double?`, and `nil` means nothing was ever emitted — which is the
signal for an empty model reply, and is what `TranslationViewModel` turns into a failure rather
than a blank success.

The alternative considered and rejected: substituting elapsed time when nothing arrived. That
made TTFT read as roughly equal to `totalMS`, which blames latency for what is actually an
absent response — the two failures then look identical in the harness output.

## Consequences

- The `"\n\n"` chunk separator does not count as a first emission; it goes through `onToken`
  directly rather than through `emit`, so it never stamps the timestamp. A consumer that treats
  any arriving piece as output clears the pane for a run that then reports an empty reply.
- The preparatory term-list call is excluded, consistently with `stats` and with token
  forwarding.
- Multi-chunk TTFT is printed by the harness for information and **not** asserted, because a
  multi-chunk run pays for the term-list call before its first chunk. Only single-chunk files
  gate.
- The design spec said «from the first raw token» until 2026-07-29. An agent trusting it would
  have moved the gate that guards the requirement. The spec now points here.

## Where the code is

`Sources/TranslationCore/Translator.swift` — `TranslationOutcome.timeToFirstTokenMS` and the
`emit` / `streamChunkTranslation` pair. The gate is in `Sources/acceptance/main.swift`.
