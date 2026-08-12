# No external dependencies

`Package.swift` declares no package dependencies and will not. The app builds against
Foundation, NaturalLanguage, SwiftUI, AppKit, Observation, ApplicationServices, CoreGraphics,
Carbon and Swift Testing, and nothing else.

## Why, for a project that would obviously benefit

Three of the things this app does have well-known packages behind them — a global-hotkey
recorder, a Markdown parser, an HTTP client — and each was written by hand instead.

- **The hotkey.** Every Swift hotkey library wraps `RegisterEventHotKey`. What matters about
  that API is the property recorded in `docs/adr/0002`, and a wrapper would hide it behind a
  convenience type at exactly the moment someone needs to know it.
- **The HTTP client.** `OllamaKit` is one endpoint family over `URLSession` with NDJSON
  streaming. The two rules that make it correct — discard `message.thinking`, and treat `think`
  as per-model rather than per-protocol (`docs/PLATFORM-TRAPS.md` has the sweep) — are empirical
  facts about particular models that no general client would encode.
- **Markup handling.** `MarkupSkeleton` does not parse Markdown; it extracts the structural
  tokens the model is allowed to change and compares before against after. A real parser would
  do far more, and none of the more is wanted.

## The reason underneath

This is a **privacy-positioned** app: the claim on the box is that text never leaves the
machine. That claim is only as strong as the smallest dependency nobody has read. A package
that phones home for analytics, or a transitive dependency that does, falsifies the one thing
the product asserts — and no amount of code review of *our* code catches it.

The secondary reasons matter less but point the same way: the project is a single package with
no CI, so `swift build` from a clone must simply work; and every fragile behaviour this app
depends on is a measured platform quirk, which means the code needs to sit close enough to the
platform to see them.

## Consequences

- More code, and more of it is ours to be wrong about. Roughly nine hundred lines across
  `TextCapture` and `OllamaKit` that a dependency would have supplied.
- Version churn in the SDK lands on us directly, with no library between. That has already
  happened once: `NSApp.activate(ignoringOtherApps:)` stopped working at macOS 14.
- **Swift Testing is the one exception in spirit** — it ships with the toolchain rather than as
  a package, so it costs nothing at the supply-chain boundary.
- If this rule is ever relaxed, relax it for something that cannot reach the network, and say
  so here.

## Where the code is

`Package.swift` — the absence is the artefact. `CLAUDE.md` states the rule for anyone about to
add one.
