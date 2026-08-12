# Thinking control («think») Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user stop a reasoning-capable model from reasoning, so the app stops paying for a trace it already discards.

**Architecture:** A new `ThinkRequest` value in `TranslationCore` reaches Ollama through `ChatOptions`; `ModelPolicy` decides which of its forms a given model may be sent; `AppSettings` holds the user's two choices and is the only place in the app that builds `ChatOptions`. There is no «on» case and no `/api/show` call — the app cannot construct a request Ollama would reject.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)` on every target), SwiftUI, Swift Testing, no external dependencies.

**Design:** `docs/superpowers/specs/2026-08-11-thinking-control-design.md`. Where this plan and the spec disagree, the spec is right and the plan has a bug.

## Global Constraints

- Swift 6 language mode, platform floor macOS 14. No new targets, no new dependencies.
- `swift build --build-tests` must stay at **zero warnings** — a standing rule with a CI gate.
- `swift test` is offline and must stay so; it takes ~2.8 s and 685 tests pass today (baseline taken 2026-08-11 before this work).
- Tests are Swift Testing (`@Test`, `#expect`), named as sentences describing the behaviour pinned. `UserDefaults`-backed tests use `InMemoryDefaults`, never a real suite.
- All user-facing strings are Russian, «guillemets» and «ё». No backticks inside `Text(String)`. Russian labels for a domain enum live in `RussianCopy.swift`, exhaustive, no `default:`.
- `TranslationCore` imports Foundation and NaturalLanguage only — no `os`, no AppKit.
- Comments carry *why* and the measurement behind it. «Measured» and «load-bearing» are a contract: a figure quoted must be one from `docs/PLATFORM-TRAPS.md`'s sweep of 2026-08-11.
- Commit messages: conventional, scoped — `feat(ollama):`, `feat(app):`, `docs(app):`.
- UI is verified by hand; GUI automation is unavailable. Never describe UI behaviour that was not observed.

---

### Task 1: The value and the wire

**Files:**
- Modify: `Sources/TranslationCore/LLMClient.swift:10-17` (`ChatOptions`)
- Create: `Sources/OllamaKit/OllamaChatBody.swift`
- Modify: `Sources/OllamaKit/OllamaClient.swift:140-152` (`chat`'s inline body)
- Test: `Tests/OllamaKitTests/OllamaChatBodyTests.swift` (create)

**Interfaces:**
- Produces: `TranslationCore.ThinkRequest` with cases `.off` and `.level(ThinkRequest.Level)`, `Level` being a `String`-raw enum of `low`/`medium`/`high`; `ChatOptions.think: ThinkRequest?` defaulted to `nil` in the initialiser; `OllamaKit.OllamaChatBody.json(messages:options:) -> [String: Any]` (internal, reached by `@testable import`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/OllamaKitTests/OllamaChatBodyTests.swift`:

```swift
// Tests/OllamaKitTests/OllamaChatBodyTests.swift
import Testing
@testable import OllamaKit
@testable import TranslationCore

private let messages = [ChatMessage(role: "user", content: "Он ждёт результата.")]

@Test func aRequestWithNoThinkSettingCarriesNoThinkKeyAtAll() {
    let body = OllamaChatBody.json(messages: messages, options: ChatOptions(model: "aya-expanse:8b"))
    #expect(body["think"] == nil)
}

@Test func disablingThinkingWritesAJSONBooleanAndNotTheStringFalse() {
    let body = OllamaChatBody.json(messages: messages,
                                   options: ChatOptions(model: "qwen3:8b", think: .off))
    #expect(body["think"] as? Bool == false)
    // The whole reason this function exists: Ollama reads `think` as a level when it is a
    // string, so `"false"` would ask for a *level named false* rather than for silence.
    #expect(body["think"] as? String == nil)
}

@Test func aThinkingLevelIsWrittenAsItsRawString() {
    for level in ThinkRequest.Level.allCases {
        let body = OllamaChatBody.json(messages: messages,
                                       options: ChatOptions(model: "gpt-oss:20b", think: .level(level)))
        #expect(body["think"] as? String == level.rawValue)
        #expect(body["think"] as? Bool == nil)
    }
}

@Test func theThinkFieldChangesNothingElseInTheBody() {
    let options = ChatOptions(model: "qwen3:8b", temperature: 0.35, keepAlive: "5m", think: .off)
    let body = OllamaChatBody.json(messages: messages, options: options)
    #expect(body["model"] as? String == "qwen3:8b")
    #expect(body["stream"] as? Bool == true)
    #expect(body["keep_alive"] as? String == "5m")
    #expect((body["options"] as? [String: Any])?["temperature"] as? Double == 0.35)
    let sent = body["messages"] as? [[String: String]]
    #expect(sent?.count == 1)
    #expect(sent?.first?["role"] == "user")
    #expect(sent?.first?["content"] == "Он ждёт результата.")
}

@Test func theBodyIsSerialisableAsJSON() {
    // `JSONSerialization` throws on a dictionary holding a non-JSON value, and `chat` builds
    // its request with `try`. A body that cannot be serialised would surface as a failed
    // translation with a transport error, which is the least diagnosable shape this can take.
    let body = OllamaChatBody.json(messages: messages,
                                   options: ChatOptions(model: "gpt-oss:20b", think: .level(.high)))
    #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: body) }
}
```

Add `import Foundation` at the top of that file for `JSONSerialization`.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --filter OllamaChatBodyTests`
Expected: compile failure — `cannot find 'OllamaChatBody' in scope`, and `ChatOptions` has no `think` parameter.

- [ ] **Step 3: Add `ThinkRequest` and the `ChatOptions` field**

In `Sources/TranslationCore/LLMClient.swift`, above `ChatOptions`:

```swift
/// Whether to ask a model *not* to reason, and how — the request side of Ollama's `think`.
///
/// **There is deliberately no «on» case, and that absence is a safety property.** Measured
/// 2026-08-11 across all eight installed models (`docs/PLATFORM-TRAPS.md`): `false` is accepted
/// by every model, including the four whose `/api/show` capabilities lack `thinking`, while
/// `true` or a level sent to one of those four answers **HTTP 400** — a failed translation, not
/// a degraded one. With no way to spell «on», no value this app can construct can fail the
/// request, which is why nothing here needs a capability probe. Adding a case removes that
/// property and must bring `/api/show` with it.
public enum ThinkRequest: Sendable, Equatable {
    /// `"think": false`. Silences `qwen3:8b` and `gemma4:26b` completely; ignored by
    /// `gpt-oss:20b`; puts the reasoning into the translation on `qwen3:30b`. Which models may
    /// be sent this is `ModelPolicy.thinkRequest(for:quiet:level:)`, not a caller's judgement.
    case off
    /// `"think": "low" | "medium" | "high"`. Grades `gpt-oss:20b` — 15 / 441 / 889 characters of
    /// trace at 0.49 / 1.99 / 3.77 s to first token, warm — and means no more than «on»
    /// elsewhere.
    case level(Level)

    public enum Level: String, Sendable, Equatable, CaseIterable { case low, medium, high }
}
```

Then extend `ChatOptions`:

```swift
public struct ChatOptions: Sendable {
    public let model: String
    public let temperature: Double
    public let keepAlive: String
    /// `nil` writes no `think` key at all, which is not the same as `.off`: absent leaves the
    /// model's own default in place — and Ollama's default for a capable model is to reason.
    public let think: ThinkRequest?
    public init(model: String, temperature: Double = 0.2, keepAlive: String = "30m",
                think: ThinkRequest? = nil) {
        self.model = model; self.temperature = temperature; self.keepAlive = keepAlive
        self.think = think
    }
}
```

- [ ] **Step 4: Write `OllamaChatBody`**

Create `Sources/OllamaKit/OllamaChatBody.swift`:

```swift
// Sources/OllamaKit/OllamaChatBody.swift
import Foundation
import TranslationCore

/// The `/api/chat` request body, built as a value rather than inline inside `chat`.
///
/// It was inline until `think` arrived, and nothing in this package could say what went on the
/// wire — the only way to see the body was a live server. That is affordable for fields whose
/// JSON type is obvious and not for this one: `think` is a **boolean** when it disables
/// reasoning and a **string** when it grades it, and Ollama reads the string `"false"` as a
/// level rather than as silence. A pure function is what lets a test hold that distinction.
enum OllamaChatBody {
    static func json(messages: [ChatMessage], options: ChatOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model, "stream": true, "keep_alive": options.keepAlive,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "options": ["temperature": options.temperature],
        ]
        switch options.think {
        case nil: break   // absent, not false — see `ChatOptions.think`
        case .off: body["think"] = false
        case .level(let level): body["think"] = level.rawValue
        }
        return body
    }
}
```

- [ ] **Step 5: Point `chat` at it**

In `Sources/OllamaKit/OllamaClient.swift`, inside `chat`, replace the inline dictionary:

```swift
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: OllamaChatBody.json(messages: messages, options: options))
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter OllamaChatBodyTests`
Expected: 5 tests pass.

Run: `swift build --build-tests 2>&1 | grep -c warning:`
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslationCore/LLMClient.swift Sources/OllamaKit/OllamaChatBody.swift \
        Sources/OllamaKit/OllamaClient.swift Tests/OllamaKitTests/OllamaChatBodyTests.swift
git commit -m "feat(ollama): carry a think request, and make the chat body testable"
```

---

### Task 2: The policy

**Files:**
- Modify: `Sources/TranslationCore/ModelPolicy.swift`
- Test: `Tests/TranslationCoreTests/ModelPolicyTests.swift` (extend)

**Interfaces:**
- Consumes: `ThinkRequest`, `ThinkRequest.Level` from Task 1.
- Produces: `ModelPolicy.thinkingLevelsOnly: [String]`, `ModelPolicy.thinkingDisableLeaks: [String: String]`, and `ModelPolicy.thinkRequest(for model: String, quiet: Bool, level: ThinkRequest.Level) -> ThinkRequest?`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslationCoreTests/ModelPolicyTests.swift`:

```swift
@Test func aQuietRunAsksAnOrdinaryModelToStopReasoning() {
    #expect(ModelPolicy.thinkRequest(for: "qwen3:8b", quiet: true, level: .low) == .off)
    #expect(ModelPolicy.thinkRequest(for: "gemma4:26b", quiet: true, level: .low) == .off)
    // A model that cannot reason at all is sent `false` too: measured HTTP 200 on all four
    // such models, and no branch is cheaper than a branch that has to be kept true.
    #expect(ModelPolicy.thinkRequest(for: "aya-expanse:8b", quiet: true, level: .low) == .off)
}

@Test func aQuietRunAsksGptOssForALevelBecauseGptOssIgnoresBeingSwitchedOff() {
    #expect(ModelPolicy.thinkRequest(for: "gpt-oss:20b", quiet: true, level: .low) == .level(.low))
    #expect(ModelPolicy.thinkRequest(for: "gpt-oss:120b", quiet: true, level: .high) == .level(.high))
}

@Test func aQuietRunLeavesAModelAloneWhenDisablingWouldPutTheReasoningInTheTranslation() {
    #expect(ModelPolicy.thinkRequest(for: "qwen3:30b", quiet: true, level: .low) == nil)
    // The neighbouring tag must not be caught by the same prefix.
    #expect(ModelPolicy.thinkRequest(for: "qwen3:8b", quiet: true, level: .low) == .off)
}

@Test func aModelInBothTablesIsAskedForALevelRatherThanLeftAlone() {
    // Nothing is in both today. The order is pinned anyway, because the two rules answer
    // differently and only one of them produces a working instruction.
    #expect(ModelPolicy.thinkingLevelsOnly.contains("gpt-oss"))
    #expect(ModelPolicy.thinkingDisableLeaks["qwen3:30b"] != nil)
}

@Test func anUnquietRunSendsNothingWhateverTheModelAndWhateverTheLevel() {
    for model in ["qwen3:8b", "gpt-oss:20b", "qwen3:30b", "aya-expanse:8b"] {
        for level in ThinkRequest.Level.allCases {
            #expect(ModelPolicy.thinkRequest(for: model, quiet: false, level: level) == nil)
        }
    }
}

@Test func everyReasonInTheDisableLeaksTableIsWorthReading() {
    // Same contract as the blacklist: a table of bare prefixes is a table nobody dares change.
    for (prefix, reason) in ModelPolicy.thinkingDisableLeaks {
        #expect(!prefix.isEmpty)
        #expect(reason.count > 40)
    }
}
```

Note on the first test: the spec's §10 says a test pinning «the interactive *default* model
produces `.off`» must not be written, because `aya-expanse:8b` cannot reason and the assertion
would pass for the wrong reason. That exclusion is about phrasing the assertion through
`ModelPolicy.defaultModel(for: .interactive)` — a lookup that could change. Naming the model
literally, as above, pins a different and real fact: a model without the capability is still sent
`false`, measured HTTP 200. Do not replace the literal with the lookup.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --filter ModelPolicyTests`
Expected: compile failure — `type 'ModelPolicy' has no member 'thinkRequest'`.

- [ ] **Step 3: Implement the tables and the rule**

Append inside `enum ModelPolicy` in `Sources/TranslationCore/ModelPolicy.swift`:

```swift
    /// Model-name prefixes that **ignore** `"think": false` and can only be graded by level.
    ///
    /// Measured 2026-08-11: `gpt-oss:20b` kept 563 characters of trace under `false` — more
    /// than the 478 it produces when nothing is sent — against 15 / 441 / 889 for
    /// `low` / `medium` / `high`. Ollama's documentation says the same for the family, which is
    /// why this is a prefix rather than the one tag that was measured.
    public static let thinkingLevelsOnly: [String] = ["gpt-oss"]

    /// Model-name prefix → why switching reasoning off on it is worse than leaving it on.
    ///
    /// Unlike `blacklist`, these strings reach no user interface: they are for the next reader
    /// of this file. They are here rather than in a comment because a table of bare prefixes is
    /// a table nobody dares change.
    public static let thinkingDisableLeaks: [String: String] = [
        "qwen3:30b": "«think: false» moves the reasoning out of message.thinking and into message.content, i.e. into the translation itself. Measured 2026-08-11: 2798 characters of Russian reasoning in place of a one-sentence answer.",
    ]

    /// What to put in `ChatOptions.think` for one model, given what the user asked for.
    ///
    /// The order of the two tables is load-bearing: a model in both must be *graded*, because
    /// that is the branch that produces a working instruction, while «leave it alone» produces
    /// none. Nothing is in both today; the order is what keeps that safe if something ever is.
    public static func thinkRequest(for model: String,
                                    quiet: Bool,
                                    level: ThinkRequest.Level) -> ThinkRequest? {
        guard quiet else { return nil }
        if thinkingLevelsOnly.contains(where: { model.hasPrefix($0) }) { return .level(level) }
        if thinkingDisableLeaks.keys.contains(where: { model.hasPrefix($0) }) { return nil }
        return .off
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ModelPolicyTests`
Expected: all pass, including the three that existed before.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/ModelPolicy.swift Tests/TranslationCoreTests/ModelPolicyTests.swift
git commit -m "feat(core): decide the think request per model, from the measured sweep"
```

---

### Task 3: The setting, and one place that builds `ChatOptions`

**Files:**
- Modify: `Sources/TranslatorApp/AppSettings.swift` (add two properties, `usesGptOss`, `chatOptions(model:)`)
- Modify: `Sources/TranslatorApp/TranslatorApp.swift:605-607`
- Modify: `Sources/TranslatorApp/TranslationViewModel.swift:302-304` and `:400-402`
- Modify: `Sources/TranslatorApp/FileQueueModel.swift:573-575`
- Test: `Tests/TranslatorAppTests/AppSettingsTests.swift` (extend)

**Interfaces:**
- Consumes: `ModelPolicy.thinkRequest(for:quiet:level:)` from Task 2.
- Produces: `AppSettings.quietThinking: Bool` (key `"quietThinking"`, default `true`), `AppSettings.gptOssThinkingLevel: ThinkRequest.Level` (key `"gptOssThinkingLevel"`, default `.low`), `AppSettings.usesGptOss: Bool`, `AppSettings.chatOptions(model: String) -> ChatOptions`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/AppSettingsTests.swift`:

```swift
@Test func thinkingIsQuietOnAFreshInstall() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.quietThinking == true)
    #expect(settings.gptOssThinkingLevel == .low)
}

@Test func aStoredThinkingLevelSurvivesAReloadAndAnUnrecognisedOneReadsBackAsLow() {
    let defaults = freshDefaults()
    let first = AppSettings(defaults: defaults)
    first.gptOssThinkingLevel = .high
    #expect(AppSettings(defaults: defaults).gptOssThinkingLevel == .high)

    // Hand-edited or written by a future version: a raw value this build does not know must
    // not trap and must not silently mean «high».
    defaults.set("exhaustive", forKey: "gptOssThinkingLevel")
    #expect(AppSettings(defaults: defaults).gptOssThinkingLevel == .low)
}

@Test func chatOptionsCarryTheThinkDecisionForWhicheverModelIsAskedFor() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "qwen3:8b"
    settings.batchModel = "gpt-oss:20b"
    #expect(settings.chatOptions(model: settings.interactiveModel).think == .off)
    #expect(settings.chatOptions(model: settings.resolvedBatchModel).think == .level(.low))

    settings.quietThinking = false
    #expect(settings.chatOptions(model: settings.interactiveModel).think == nil)
    #expect(settings.chatOptions(model: settings.resolvedBatchModel).think == nil)
}

@Test func chatOptionsStillCarryTheTemperatureAndKeepAliveTheUserSet() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.temperature = 0.45
    settings.keepAlive = "5m"
    let options = settings.chatOptions(model: "aya-expanse:8b")
    #expect(options.model == "aya-expanse:8b")
    #expect(options.temperature == 0.45)
    #expect(options.keepAlive == "5m")
}

@Test func theDepthRowIsOfferedOnlyWhileAGptOssModelIsSelectedOnEitherPath() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "aya-expanse:8b"
    settings.batchModel = nil
    #expect(settings.usesGptOss == false)

    settings.batchModel = "gpt-oss:20b"
    #expect(settings.usesGptOss == true)

    settings.batchModel = nil
    settings.interactiveModel = "gpt-oss:20b"
    #expect(settings.usesGptOss == true)
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --filter AppSettingsTests`
Expected: compile failure — `value of type 'AppSettings' has no member 'quietThinking'`.

- [ ] **Step 3: Add the two properties**

In `Sources/TranslatorApp/AppSettings.swift`, beside `batchModel`:

```swift
    /// Whether the app asks a model not to reason.
    ///
    /// **On by default, which is a change in what the app does and is meant to be.** Ollama
    /// turns reasoning on by default for a capable model and `OllamaStreamParser` discards
    /// `message.thinking` by standing rule, so before this setting existed the app paid for a
    /// trace it threw away: measured 2026-08-11, `qwen3:8b` produced 2621 characters of it
    /// before the first character of translation. Which models may actually be told, and how,
    /// is `ModelPolicy.thinkRequest(for:quiet:level:)`.
    var quietThinking: Bool {
        get {
            access(keyPath: \.quietThinking)
            return bool("quietThinking", true)
        }
        set { withMutation(keyPath: \.quietThinking) { defaults.set(newValue, forKey: "quietThinking") } }
    }

    /// How much reasoning `gpt-oss` is allowed, for the one family that cannot be switched off.
    ///
    /// Defaults to `.low` rather than to the model's own default for the same reason
    /// `quietThinking` defaults to on: measured 15 characters of trace at 0.49 s to first token
    /// against 478 characters when nothing is sent.
    var gptOssThinkingLevel: ThinkRequest.Level {
        get {
            access(keyPath: \.gptOssThinkingLevel)
            return ThinkRequest.Level(rawValue: string("gptOssThinkingLevel", "low")) ?? .low
        }
        set {
            withMutation(keyPath: \.gptOssThinkingLevel) {
                defaults.set(newValue.rawValue, forKey: "gptOssThinkingLevel")
            }
        }
    }

    /// Whether either path would run a `gpt-oss` model — i.e. whether the depth control has
    /// anything to govern.
    ///
    /// A derived property rather than a comparison written in the pane, for
    /// `batchModelDiffersFromInteractive`'s stated reason: a view that restated the prefix rule
    /// would go on drawing the row after the rule changed.
    var usesGptOss: Bool {
        ModelPolicy.thinkingLevelsOnly.contains { interactiveModel.hasPrefix($0) || resolvedBatchModel.hasPrefix($0) }
    }
```

- [ ] **Step 4: Add the one builder**

Append to `Sources/TranslatorApp/AppSettings.swift`, after the type:

```swift
extension AppSettings {
    /// The only place in the app that builds `ChatOptions`.
    ///
    /// It was four places, all passing the identical triple of model, temperature and
    /// keep-alive. Collapsing them is not tidying: after it, an app-layer `ChatOptions` cannot
    /// be built without the think decision having been made, so a fifth call site added later
    /// cannot silently opt out of the setting.
    func chatOptions(model: String) -> ChatOptions {
        ChatOptions(model: model, temperature: temperature, keepAlive: keepAlive,
                    think: ModelPolicy.thinkRequest(for: model, quiet: quietThinking,
                                                    level: gptOssThinkingLevel))
    }
}
```

- [ ] **Step 5: Route the four call sites through it**

`Sources/TranslatorApp/TranslatorApp.swift`, in `warmUp` — the warm-up must reason exactly as a real run would, or it loads the model under a regime nothing else uses:

```swift
        let options = settings.chatOptions(model: settings.interactiveModel)
```

`Sources/TranslatorApp/TranslationViewModel.swift`, both sites (translate and proofread):

```swift
        let options = settings.chatOptions(model: settings.interactiveModel)
```

`Sources/TranslatorApp/FileQueueModel.swift`:

```swift
        let options = settings.chatOptions(model: settings.resolvedBatchModel)
```

Leave the comment above the `FileQueueModel` site as it is — it explains why the value is resolved on the main actor, which has not changed.

**`Sources/acceptance/main.swift:109` is not one of these sites and must not be changed.** It
builds `ChatOptions(model:)` with the default `nil`, and that is deliberate: the harness measures
the engine against fixed thresholds, so a run that silently followed a user's setting would move
its own baseline. Same for `Sources/translate-cli` — Task 5 gives it an explicit flag instead.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter AppSettingsTests`
Expected: all pass.

Run: `swift test`
Expected: the whole suite passes — 685 tests plus the ones added in Tasks 1–3.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/AppSettings.swift Sources/TranslatorApp/TranslatorApp.swift \
        Sources/TranslatorApp/TranslationViewModel.swift Sources/TranslatorApp/FileQueueModel.swift \
        Tests/TranslatorAppTests/AppSettingsTests.swift
git commit -m "feat(app): one place builds ChatOptions, and it carries the think decision"
```

---

### Task 4: The pane

**Files:**
- Modify: `Sources/TranslatorApp/RussianCopy.swift`
- Modify: `Sources/TranslatorApp/SettingsModelsView.swift` (the «Качество перевода» section, currently ending at line 207)
- Test: `Tests/TranslatorAppTests/RussianCopyTests.swift` (extend)

**Interfaces:**
- Consumes: `AppSettings.quietThinking`, `AppSettings.gptOssThinkingLevel`, `AppSettings.usesGptOss` from Task 3.
- Produces: `ThinkRequest.Level.russianName: String`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/RussianCopyTests.swift`:

```swift
@Test func everyThinkingLevelHasARussianName() {
    #expect(ThinkRequest.Level.low.russianName == "Кратко")
    #expect(ThinkRequest.Level.medium.russianName == "Средне")
    #expect(ThinkRequest.Level.high.russianName == "Подробно")
    // No `default:` anywhere in the switch, so a new case is a compile error rather than a
    // row rendering as its raw English value.
    #expect(Set(ThinkRequest.Level.allCases.map(\.russianName)).count == ThinkRequest.Level.allCases.count)
}
```

Add `@testable import TranslationCore` to that file if it is not already there.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter everyThinkingLevelHasARussianName`
Expected: compile failure — `value of type 'ThinkRequest.Level' has no member 'russianName'`.

- [ ] **Step 3: Add the copy**

In `Sources/TranslatorApp/RussianCopy.swift`, beside the other domain-enum extensions:

```swift
extension ThinkRequest.Level {
    /// «Глубина», not «степень»: правка has already spent that word on how freely wording may
    /// change, and two settings sharing one noun is how a pane stops being readable.
    var russianName: String {
        switch self {
        case .low: "Кратко"
        case .medium: "Средне"
        case .high: "Подробно"
        }
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter everyThinkingLevelHasARussianName`
Expected: PASS.

- [ ] **Step 5: Add the controls to the pane**

In `Sources/TranslatorApp/SettingsModelsView.swift`, at the end of the `Section("Качество перевода")` block — after the temperature caption, before the closing brace:

```swift
                Toggle("Отключать рассуждение модели", isOn: $settings.quietThinking)
                // The caption says what the app does with the trace, because that is the fact
                // that makes the default defensible: a discarded trace costs only time.
                // Measured 2026-08-11: qwen3:8b writes 2621 characters of it before the first
                // character of translation.
                Text("Некоторые модели сначала рассуждают вслух. В перевод это не попадает — "
                     + "приложение отбрасывает такой текст, — но тратит время до первого слова.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.usesGptOss {
                    Picker("Глубина у gpt-oss:", selection: $settings.gptOssThinkingLevel) {
                        ForEach(ThinkRequest.Level.allCases, id: \.self) { level in
                            Text(level.russianName).tag(level)
                        }
                    }
                    // Disabled rather than hidden: a control that vanished when an unrelated
                    // switch moved would read as a bug rather than as a dependency.
                    .disabled(!settings.quietThinking)
                    Text("gpt-oss не умеет выключать рассуждение — только укоротить.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

Add `import TranslationCore` at the top of the file — it currently imports `SwiftUI` and `OllamaKit` only.

- [ ] **Step 6: Build and run the whole suite**

Run: `swift build --build-tests 2>&1 | grep -c warning:`
Expected: `0`.

Run: `swift test`
Expected: all pass.

- [ ] **Step 7: Check the pane by hand**

Run: `./Scripts/make-app-bundle.sh && open build/LocalTranslator.app`

Open Settings → «Модели» and confirm, without describing anything not seen:
1. the new checkbox is on, and «Глубина у gpt-oss» is absent while «Модель для перевода» is `aya-expanse:8b` and no batch model is set;
2. selecting `gpt-oss:20b` as either model makes the depth row appear, and unticking the checkbox greys it out;
3. the section still fits — `.formStyle(.grouped)` scrolls, so the question is whether it reads well at 560 × 480, not whether it clips.

Record what was observed in the commit message. If any of the three does not hold, stop and report rather than adjusting the frame — `settingsPane()`'s fixed frame is load-bearing.

- [ ] **Step 8: Commit**

```bash
git add Sources/TranslatorApp/RussianCopy.swift Sources/TranslatorApp/SettingsModelsView.swift \
        Tests/TranslatorAppTests/RussianCopyTests.swift
git commit -m "feat(app): a switch for the model's reasoning, and a depth for gpt-oss"
```

---

### Task 5: `translate-cli --think`

**Files:**
- Modify: `Sources/translate-cli/main.swift` (`Options`, `parse`, the usage string at line 62, the `ChatOptions` construction at line 109)

**Interfaces:**
- Consumes: `ThinkRequest` from Task 1. Deliberately **not** `ModelPolicy.thinkRequest` — see the comment in the code below.

- [ ] **Step 1: Add the flag to `Options` and `parse`**

There is no test target for `translate-cli` — it is top-level code in `main.swift` and nothing can import it. This task is verified by building and running it, and the plan says so rather than pretending otherwise.

In `struct Options`, beside `chunk`:

```swift
    var think: ThinkRequest?
```

In `parse`, beside the `--chunk` case:

```swift
        case "--think":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--think needs a value")) }
            if value == "off" {
                options.think = .off
            } else if let level = ThinkRequest.Level(rawValue: value) {
                options.think = .level(level)
            } else {
                // Rejected rather than defaulted, for `--chunk`'s reason: a silent fallback
                // would make a mistyped flag look like a measurement.
                return .failure(ParseFailure(message: "--think needs one of off|low|medium|high, got \"\(value)\""))
            }
```

Reading the level through `Level(rawValue:)` rather than matching the three strings twice is what keeps the flag and the enum from drifting apart: a fourth level added to `ThinkRequest` becomes accepted here without an edit.

- [ ] **Step 2: Extend the usage string**

Line 62 becomes:

```swift
let usage = "usage: translate-cli --to <ru|en|de|fr|es|pt|it|zh|ja> [--from L] [--tone neutral|formal|casual|technical|literal] [--model NAME] [--chunk N] [--think off|low|medium|high] [text]\n"
```

- [ ] **Step 3: Pass it through**

Line 109 becomes:

```swift
// Straight into `ChatOptions`, deliberately bypassing `ModelPolicy.thinkRequest`: this flag
// exists to reproduce measurements, and a harness that refused to send `false` to `qwen3:30b`
// could not reproduce the leak the policy is built around. The app is where a user is
// protected; this is where a measurement is taken.
let chatOptions = ChatOptions(model: model, temperature: 0.2, keepAlive: "30m", think: parsed.think)
```

- [ ] **Step 4: Build and check the flag by hand**

Run: `swift build 2>&1 | grep -c warning:`
Expected: `0`.

Run: `swift run translate-cli --to en --think nonsense "тест"`
Expected: exits non-zero, printing `--think needs one of off|low|medium|high, got "nonsense"` followed by the usage line.

With a live Ollama, run: `swift run translate-cli --to en --model qwen3:8b --think off "Он ждёт результата."`
Expected: an English sentence and a TTFT in the footer noticeably below the same command without the flag. Record both figures in the commit message; if Ollama is not running, say so instead of guessing.

- [ ] **Step 5: Commit**

```bash
git add Sources/translate-cli/main.swift
git commit -m "feat(cli): --think, for re-measuring what the setting does"
```

---

### Task 6: The documentation the code now owns

**Files:**
- Modify: `CLAUDE.md` (the «Ollama rules» section, and `AppSettings`' paragraph in «The app layer»)
- Modify: `docs/PLATFORM-TRAPS.md` (the three Ollama entries' `→` pointers)
- Modify: `docs/MEASUREMENTS.md` (the think row's owner)
- Modify: `CONTEXT.md` (two words)
- Modify: `docs/OPEN-ITEMS.md` (§1, the manual check)

The measurement itself is already recorded — that landed in commit `766ef85` with the design. This task records only what the *code* now does.

- [ ] **Step 1: `CLAUDE.md`**

In «Ollama rules», after the three think bullets, add:

```markdown
- **The control over it is `AppSettings.quietThinking` plus `gptOssThinkingLevel`, and the
  decision is `ModelPolicy.thinkRequest(for:quiet:level:)`.** `AppSettings.chatOptions(model:)`
  is the only place in the app that builds `ChatOptions`, precisely so a new call site cannot
  opt out of it. `ThinkRequest` has no «on» case: that is what makes every request the app can
  build one Ollama accepts, and it is why there is still no `/api/show` call.
```

In «The app layer», at the end of the `AppSettings` bullet, add:

```markdown
  Two of its keys are `"quietThinking"` (default **true** — a deliberate change to what the app
  does, see the Ollama rules above) and `"gptOssThinkingLevel"` (default `low`).
```

- [ ] **Step 2: `docs/PLATFORM-TRAPS.md`**

Change the `→` line under «Turning reasoning on is capability-gated…» to:

```markdown
→ `Sources/TranslationCore/ThinkRequest` in `LLMClient.swift`, `ModelPolicy.thinkRequest`,
  `Sources/OllamaKit/OllamaChatBody.swift`
```

- [ ] **Step 3: `docs/MEASUREMENTS.md`**

In the «Durable — the models» table, change the owner cell of the **0 / 2798 / 563** row from
`docs/PLATFORM-TRAPS.md`, `CLAUDE.md` to `ModelPolicy.swift`, `docs/PLATFORM-TRAPS.md` — the file's
own rule is that a figure is owned by the code it constrains, and it now constrains code.

- [ ] **Step 4: `CONTEXT.md`**

Add to the vocabulary: **рассуждение** (what a model emits into `message.thinking` before its
answer; never «размышление», «мышление», «thinking») and **глубина** (how long a `gpt-oss` trace
may be: «Кратко» / «Средне» / «Подробно»; never «степень», which правка owns, and never «уровень»).
Match the surrounding table's shape rather than inventing a section.

- [ ] **Step 5: `docs/OPEN-ITEMS.md`**

Add to §1's list of manual checks: whether the «Модели» pane still reads well at 560 × 480 with the
two new controls, and — if a `gpt-oss` model is installed — whether the depth row's four states
(absent, present, enabled, greyed) behave as Task 4 Step 7 describes. Record the result of that
check if it was already done in Task 4, rather than listing it as still owed.

- [ ] **Step 6: Run the documentation tests**

Run: `swift test --filter DocumentationTests`
Expected: pass — these assert `CLAUDE.md`'s target list against `Package.swift`, which this work
does not touch, and a failure here means something else was edited by accident.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/PLATFORM-TRAPS.md docs/MEASUREMENTS.md CONTEXT.md docs/OPEN-ITEMS.md
git commit -m "docs(app): record the think control the code now owns"
```

---

## Done when

- `swift test` passes with no failures and `swift build --build-tests` emits zero warnings.
- Settings → «Модели» shows the checkbox on a fresh install, and the depth row appears only with a `gpt-oss` model selected — **observed on the bundle**, not inferred.
- `swift run translate-cli --to en --think off "…"` against a live Ollama returns a translation, and `--think nonsense` is rejected.
- The five documents in Task 6 describe the code that exists.
