# Structure is recovered by construction where it exists, and by a gated enquiry where it does not

Date: 2026-09-02. Status: accepted. Spec: GitHub issue #72.

## Context

A user's text reaches this app in one of three states: with its structure intact (a `.md` file,
a README pasted into «Текст»); with its structure *present on the pasteboard but absent from the
plain flavour* (a table copied out of a browser or Word arrives flat in `.string` and whole in
`.html`); or with no structure left anywhere (a mail, a chat message, a PDF export). The user
sees a hosted assistant render all three as documents and asks for the same.

The formatting design of 2026-08-31 measured the one route everyone reaches for first — asking
the model to *preserve* markers alongside its translation — and found it harmful on the models
this install runs: bold degraded to italic 5/5 on translategemma:12b, emphasis invented 2/3 on
aya-expanse:32b (series B). Asking a 12–27B model to *reconstruct* structure inside the same
call it translates in would be the same instruction with more to get wrong.

## Decision

Two rules, and the boundary between them is whether the structure still exists anywhere.

1. **Where it exists, it is recovered deterministically and never by a model.** The pasteboard's
   HTML (then RTF) is converted to Markdown by a closed-tag scanner, and the conversion is kept
   only when it *gains a block form* the plain flavour lacks — the improvement-or-no-op gate
   (`RichMarkdown`). Both entry points read the board through that one gate: the hotkey's ⌘C
   fallback and, since this decision, ⌘V into the исходник pane.
2. **Where it does not exist, a model may propose structure, in a call of its own, and a
   deterministic gate decides.** The «Оформить» pass (`Translator.format`) asks for headings,
   tables, lists and code only, on the source text, before перевод or правка; the reply is
   accepted only if, with its markers taken back off and whitespace collapsed, it is the same
   text word for word and every table's rows have equal cell counts (`FormattingGate`). A
   refused reply costs nothing: the operation runs on the text as it was, and the user is told
   why. The pass is off by default until the measurement `Scripts/format-loss.sh` takes passes
   the threshold spec #72 names.

What the model returns is never trusted for its *content* in either rule. In the first it never
sees the structure at all; in the second it may move only the markers, and the gate is what
proves that.

## Consequences

- `MarkdownPlainText` moved from `MarkupKit` into `TranslationCore`, because the gate needs
  «the words without the syntax» and the domain module may not import AppKit. It is Foundation
  only and always was; `MarkupKit` keeps using it from its new home. `MarkdownOutputBlock` moved
  with it, and became public, for the same reason.
- `Translator` has three routes and still one pipeline: the pass shares `ResponseCleaner`, the
  cancellation discipline and the client, and adds no glossary stage and no markup diff.
- A reconstructed source is *synthesised Markdown* in the sense `HotkeyCoordinator` already
  tracks, so «Заменить» strips its markers before writing back — the same rule the rich capture
  established, now with a second producer.
- The panel keeps its «first token in under a second» contract by default: the pass runs there
  only under a second checkbox.
- Emphasis and links stay outside both rules on purpose. The first gate refuses a conversion
  whose only gain is inline; the second forbids them in the prompt and strips any that arrive.
  That is the series B measurement, applied twice.

## Rejected

- **Reconstruction inside the translation prompt.** Series B, above.
- **Heuristic reconstruction of tables from flat text without a model.** Choosing the column
  count from a run of short lines is a guess about meaning; the model is better placed to make
  it, and the gate makes its guess safe. The one heuristic kept — «•» and «–» drawn as a list —
  is display-only and touches no text the model or «Заменить» sees.
- **Accepting a reply with a changed word when the table is good.** A translator that edits the
  source before translating it is a different product.
