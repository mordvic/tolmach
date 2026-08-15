# The panel and the window own separate view models

`TranslationViewModel` is instantiated twice: once by `TranslatorApp` for the main window, and
once by `HotkeyCoordinator` for the floating panel. They share the `AppSettings`, the
`GlossaryStore` and the `OllamaClient`; only the view model is separate.

## Why not one

**A hotkey translation must not overwrite what is in the window.** The window is a document the
user is working in; the panel is a glance at something they selected elsewhere. One model means
every press replaces the window's contents.

**The re-entrancy guard is per instance.** `translate()` opens with `guard state != .running`,
so a shared model would make a hotkey press during a window translation do nothing at all —
silently, with no way for the user to tell the press was dropped rather than lost.

## The cost, and how it is paid

Two models mean two copies of the same run state, and the hand-off between them —
«Открыть в окне» — has to move all of it. Moving only the visible text is exactly the defect
that occurred: the window kept the previous run's `outcome` and `.finished` state, so it
rendered that run's elapsed time and that run's markup and glossary warnings underneath the
text it had just been handed.

The hand-off is therefore `TranslationViewModel.adopt(from:)`, which moves the run as a unit and
refuses when either model is mid-translation.

> **The list has grown three times since this was written, and the rule is what to read, not
> the count.** It said «five values — source, translation, `outcome`, `resolvedTarget`,
> `state`». Правка added `operation`, `resolvedOperation` and `resolvedProofreadingLevel`; the
> terms gate added `documentTermsUnavailable`; and 2026-08-15 added the правка pair —
> `proofreadingLevelOverride` and `rewriteStyleOverride`, pinned to what the adopted run
> *resolved* — whose absence was a defect of exactly the kind this ADR exists to describe: the
> window offered «Ещё вариант» for an adopted правка and ran it under its own toolbar's
> степень.
>
> **The rule is «anything that describes the run moves with it», and «Из», «В» and «Тон» turn
> out not to describe the run.** They configure the *queue*: `MainWindowView` starts one with
> `queue.run(source:target:tone:)` read off this same model, because the toolbar binds to one
> owner across both of the window's modes. Moving them would have made a hand-off silently
> reset a queue's language, so they stay — the one place where this model holds something that
> is not about its own translation. `adopt(from:)` is the list, and it is the only place the
> list should be written. It refuses on the source side too: `state` can move but the `Task` behind it
cannot, so adopting `.running` would hand a model a state it has no way to leave.

`adoptionRefusal(from:)` returns *why* rather than a Bool, because the panel needs two answers
from one rule: whether to offer the button, and what to say when it does not.

## Consequences

- Anything that must be true of "the current translation" has to say *which* one.
- The two share one `OllamaClient`, which is what holds the `URLSession`. `Translator` is a
  value with no state beyond the client, so two of those cost nothing.
- A future third surface — batch translation is v2 — gets a third model, not a shared one.

## Where the code is

`Sources/TranslatorApp/HotkeyCoordinator.swift` (the `panelModel` comment),
`Sources/TranslatorApp/TranslationViewModel.swift` (`adopt(from:)` and `adoptionRefusal(from:)`).
