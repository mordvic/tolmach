# Controlling a model's reasoning («think») — design

Date: 2026-08-11
Status: designed, not implemented

## Status of this document

This is the pre-implementation design for one setting: whether the app asks a reasoning-capable
model not to reason. Once the code exists, **the code is the authority on behaviour and this
document is the authority on why**.

Every figure below is **measured** — the sweep of 2026-08-11 recorded in `docs/PLATFORM-TRAPS.md`,
Ollama server 0.31.1, all eight locally installed models. Nothing here is inferred from Ollama's
documentation, though §2 notes where the two agree.

---

## 1. Vocabulary

`CONTEXT.md` owns the app's words and gains these.

| Word | Means | Never |
|---|---|---|
| **рассуждение** | what a model emits into `message.thinking` before its answer | «размышление», «мышление», «thinking» |
| **глубина** | how long a `gpt-oss` trace is allowed to be: «Кратко» / «Средне» / «Подробно» | «уровень» (that word belongs to правка's «степень»), «длина» |

«Глубина» is deliberately not «степень»: `docs/superpowers/specs/2026-08-10-proofreading-design.md`
has already spent that word on how freely wording may change, and two settings sharing one noun is
how a pane stops being readable.

---

## 2. What this rests on

The three outcomes of one parameter, from the sweep:

| | `"think": false` does | so the app must |
|---|---|---|
| `qwen3:8b`, `gemma4:26b` | silence the trace completely (2621 → 0, 721 → 0 characters) | send it — this is the whole feature |
| `gpt-oss:20b` | nothing; the trace stays (563 characters) | send a level instead: 15 / 441 / 889 characters at 0.49 / 1.99 / 3.77 s to first token |
| `qwen3:30b` | move 2798 characters of reasoning into `message.content` | send nothing at all |

And the asymmetry that shapes the design: `false` was accepted by **all eight** models with HTTP
200, including the four whose `/api/show` capabilities lack `thinking`; `true` or a level sent to
one of those four is **HTTP 400** `"<model>" does not support thinking`, i.e. a failed translation.

Ollama's own documentation agrees on the parts it covers — «GPT-OSS requires `think` to be set to
`low`/`medium`/`high`. Passing `true`/`false` is ignored for that model», and «Thinking is enabled
by default in the CLI and API for supported models». It says nothing about the `qwen3:30b` leak,
which is why the sweep and not the documentation is what this design cites.

The consequence worth stating plainly: **today the app pays for a trace it throws away.** Ollama
turns reasoning on by default for a capable model and `OllamaStreamParser` discards
`message.thinking` by standing rule. The pinned interactive model `aya-expanse:8b` cannot reason,
so the panel is unaffected; the recommended background model `gpt-oss:20b` can.

---

## 3. What the user gets

One section in Settings → «Модели», below «Качество перевода»:

```
☑ Отключать рассуждение модели
   Рассуждение не попадает в перевод — приложение его отбрасывает, —
   но тратит время до первого слова.

Глубина у gpt-oss:  [ Кратко ⌄ ]
   gpt-oss не умеет выключать рассуждение, только укоротить.
```

The checkbox is **on by default**. That is a behaviour change for anyone whose chosen model can
reason, and it is the right default for the reason in §2: the trace is discarded either way, so
its only effect on this app is delay.

The «Глубина» row is drawn only when `interactiveModel` or `resolvedBatchModel` has the `gpt-oss`
prefix, and is enabled only while the checkbox is on. Nothing in the pane mentions `qwen3:30b` or
any other model the policy treats specially — like the blacklist, that is a rule of the engine
rather than a choice offered to the user.

---

## 4. Engine — `TranslationCore`

### 4.1 The request value

In `LLMClient.swift`, beside `ChatOptions`:

```swift
public enum ThinkRequest: Sendable, Equatable {
    case off                    // "think": false
    case level(Level)           // "think": "low" | "medium" | "high"
    public enum Level: String, Sendable, Equatable, CaseIterable { case low, medium, high }
}
```

`ChatOptions` gains `public let think: ThinkRequest?`, defaulted to `nil` in the initialiser so
every existing call site keeps compiling and keeps today's behaviour. **`nil` means the key is not
written**, which is not the same as `.off` and must never be conflated with it: `nil` is «let the
model do what it does», `.off` is an instruction.

There is no `.on` case, and that absence is the capability gate. `true` and a level sent to a model
without the `thinking` capability are the only values measured to return 400; `false` is safe on
every model measured, and a level is only ever produced for `gpt-oss`, which has the capability. So
no value this app can construct can fail the request — **protection by construction**, the same
shape as fenced-code pass-through, and the reason no `/api/show` call is needed. Adding an «enable
reasoning» option later breaks that property and would have to bring a capability probe with it.

### 4.2 The policy

`ModelPolicy` gains two prefix-matched tables, the mechanism `blacklist` already uses, and one
function over them:

```swift
/// Prefixes that ignore `false` and grade only by level. Measured 2026-08-11: `gpt-oss:20b`
/// keeps 563 characters of trace under `false`, against 15 / 441 / 889 for low / medium / high.
public static let thinkingLevelsOnly: [String] = ["gpt-oss"]

/// Prefix → why disabling reasoning on it is worse than leaving it alone.
public static let thinkingDisableLeaks: [String: String] = [
    "qwen3:30b": "«think: false» moves the reasoning into message.content, i.e. into the translation itself. Measured 2026-08-11: 2798 characters.",
]

public static func thinkRequest(for model: String,
                                quiet: Bool,
                                level: ThinkRequest.Level) -> ThinkRequest?
```

The rule, in order:

1. `quiet == false` → `nil`. The user asked for nothing to be sent, and nothing is.
2. prefix in `thinkingLevelsOnly` → `.level(level)`.
3. prefix in `thinkingDisableLeaks` → `nil`. Leaving the model reasoning costs time; disabling it
   costs the translation, and the trace at least lands in the field the parser discards.
4. otherwise → `.off`.

Order 2 before 3 is not arbitrary: a model could plausibly appear in both tables one day, and the
one that answers with a *working* instruction has to win.

`thinkingDisableLeaks` carries a reason per prefix for the same reason `blacklist` does — a table of
bare prefixes is a table nobody dares change. Unlike `blacklist`'s, these reasons reach no user
interface at all; they are there for the next reader of the file, so they need no `RussianCopy`
counterpart. `thinkingLevelsOnly` needs no reasons because it has one entry and a doc comment.

---

## 5. Transport — `OllamaKit`

`OllamaClient.chat` builds its JSON body inline today, which is why nothing tests it. The body
moves into a pure function beside `OllamaStreamParser`:

```swift
enum OllamaChatBody {
    static func json(messages: [ChatMessage], options: ChatOptions) -> [String: Any]
}
```

`chat` calls it and serialises the result; the function is what the tests read. Serialisation of
the new field:

| `options.think` | body |
|---|---|
| `nil` | no `"think"` key at all |
| `.off` | `"think": false` — a JSON boolean, not the string `"false"` |
| `.level(.low)` | `"think": "low"` |

Nothing else about the body changes, and `OllamaStreamParser` does not change at all:
`message.thinking` is still read and discarded, because a level still produces a trace.

---

## 6. Settings, and where the decision is made

`AppSettings` gains two properties in the established shape — no stored properties,
`access(keyPath:)` / `withMutation(keyPath:_:)` by hand:

| Property | Key | Default |
|---|---|---|
| `quietThinking: Bool` | `"quietThinking"` | `true` |
| `gptOssThinkingLevel: ThinkRequest.Level` | `"gptOssThinkingLevel"` | `.low` |

`gptOssThinkingLevel` stores its `rawValue` and reads back through `Level(rawValue:) ?? .low`, so a
hand-edited or future-written value cannot crash the app.

All four places that build `ChatOptions` today — `TranslatorApp.warmUp`, `TranslationViewModel`
twice, `FileQueueModel` — pass the identical triple of model, `settings.temperature` and
`settings.keepAlive`. They collapse into one method:

```swift
extension AppSettings {
    func chatOptions(model: String) -> ChatOptions
}
```

which fills in temperature, keep-alive, and `ModelPolicy.thinkRequest(for: model, quiet:
quietThinking, level: gptOssThinkingLevel)`. This is the point of the refactor rather than a tidy-up:
after it, an app-layer `ChatOptions` cannot be built without the think decision having been made,
so a fifth call site added later cannot silently opt out of the setting.

`warmUp` gets the same options as a real run, deliberately — a warm-up that reasoned while the run
did not would load the same model under a different regime and measure nothing useful.

`acceptance` keeps building `ChatOptions(model:)` with the default `nil`: it measures the engine
against fixed thresholds, and a harness that silently followed a user setting would move its own
baseline.

---

## 7. The pane

`SettingsModelsView`'s «Качество перевода» section gains the checkbox and the picker described in
§3. Two constraints from `CLAUDE.md` apply and neither is negotiable:

- the pane keeps `settingsPane()`'s 560 × 480 frame, and `.formStyle(.grouped)` installs its own
  `NSScrollView`, so the section cannot clip. **That it still reads well at that height is a manual
  check**, and this design does not claim it — `docs/OPEN-ITEMS.md` §1 gains the line.
- Russian labels for a domain enum live in `RussianCopy`, exhaustive with no `default:`. So
  `ThinkRequest.Level` gets «Кратко» / «Средне» / «Подробно» there, not in the view.

The row is disabled — not hidden — while the checkbox is off, because a control that vanished when
an unrelated switch moved would read as a bug rather than as a dependency.

The «Глубина» row's visibility reads `settings.usesGptOss` — a derived property on `AppSettings`
next to `batchModelDiffersFromInteractive`, for that property's stated reason: a view that restated
the prefix comparison would keep drawing the row after the rule changed.

---

## 8. `translate-cli`

One flag, `--think off|low|medium|high`, defaulting to «not passed», mapping straight onto
`ThinkRequest?` and bypassing `AppSettings` entirely — the CLI has no settings and should not grow
one. It exists so the sweep in §2 can be re-run by hand against a real document rather than the
one-sentence prompt it used, which is the measurement `docs/MEASUREMENTS.md` still owes for the
`qwen3:30b` blacklist entry.

`--think` must reject an unknown value with the usage text rather than falling back to a default:
a silent fallback would make a mistyped flag look like a measurement.

It also **bypasses `ModelPolicy.thinkRequest` and goes straight into `ChatOptions`**, which is the
one place in this codebase where that is correct: the flag exists to reproduce measurements, and a
harness that refused to send `false` to `qwen3:30b` could not reproduce the very leak the policy is
built around. The app is where the policy is enforced, because the app is where a user is protected.

---

## 9. What does not change

- `message.thinking` is still read and discarded. A level shortens the trace; it does not remove it.
- No `/api/show`, no `capabilities`, no `true` on the wire. §4.1 says why.
- No per-role settings. One checkbox governs the hotkey, the window and the queue; the level applies
  to whichever request happens to run a `gpt-oss` model, whatever role it is playing.
- The blacklist is untouched. `qwen3:30b` stays blacklisted for the interactive path; the new table
  is about a different failure and must not be folded into it.
- Nothing measures whether reasoning improves translation *quality*. That question is
  `swift run acceptance` on a live Ollama, and it is out of scope here.

---

## 10. Testing

Offline, Swift Testing, sentence-named, per `docs/TESTING.md`. Each of these fails under the defect
it names:

**`OllamaKitTests`** — the first tests this project has of the request body.
- a nil think produces a body with no «think» key at all
- disabling thinking writes a JSON boolean rather than the string false
- a thinking level is written as its raw string
- the rest of the body is unchanged by the think field (model, stream, keep_alive, messages, options)

**`TranslationCoreTests`** — the policy table.
- a quiet run asks a plain model to stop reasoning
- a quiet run asks gpt-oss for a level, because gpt-oss ignores being switched off
- a quiet run leaves qwen3:30b alone, because disabling its reasoning puts it in the translation
- a model matching both tables is asked for a level rather than left alone
- an unquiet run sends nothing, whatever the model and whatever the level

**`TranslatorAppTests`** — settings and pane, `InMemoryDefaults` only.
- thinking is quiet on a fresh install
- a stored thinking level survives a read, and an unrecognised one reads back as low
- chat options carry the think decision for the interactive model and for the batch model
- the depth row is offered only while a gpt-oss model is selected on either path

A test that pins «the interactive default model produces `.off`» is deliberately **not** written:
`aya-expanse:8b` cannot reason, so that assertion would pass for the wrong reason and go on passing
if the policy inverted.

---

## 11. Documentation shipped with the code

- `CLAUDE.md` — the «Ollama rules» section already carries the corrected measurement; it gains the
  control itself, and `AppSettings`' paragraph gains the two keys.
- `docs/PLATFORM-TRAPS.md` — the Ollama entries gain the pointer to the new owning code.
- `docs/MEASUREMENTS.md` — the think row's owner moves from this documentation to `ModelPolicy`'s
  doc comment, per that file's own rule that a figure is owned by the code it constrains.
- `CONTEXT.md` — the two words in §1.
- `docs/OPEN-ITEMS.md` — the manual check in §7.
