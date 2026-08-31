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
  as per-model rather than per-protocol (`docs/reference/PLATFORM-TRAPS.md` has the sweep) — are empirical
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

## Amendment, 2026-08-31: where AppKit may be imported

The list above already held AppKit; what changed is that `MarkupKit` — the Markdown →
`NSAttributedString` converter behind the rendered перевод pane — imports it, and it is the
first target below `TranslatorApp` to do so.

It is an edit to this decision rather than an exception to it, for the reason the «Markup
handling» bullet gives in reverse. That bullet is still true: `MarkupSkeleton` does not parse
Markdown and no parser was added for the *pipeline*. The rendered pane does need one, and it
still is not a dependency — `MarkdownBlockScanner` is ours, the inline half is Foundation's own
`AttributedString(markdown:)`, and the attributed string it all produces is an AppKit type by
nature. Putting the converter in the app instead would have cost a second serialiser for the
rich «Скопировать» flavour, which is the shape this repo already names as how two surfaces come
to disagree.

The supply-chain reasoning underneath is untouched: no package, nothing that can reach the
network, and `swift build` from a clone still simply works.
