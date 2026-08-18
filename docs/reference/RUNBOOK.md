# Runbook

Getting from a clone to a working hotkey, and the operational facts that are not obvious.

---

## 1. Ollama and a model

```bash
brew install ollama
ollama serve                      # or let the app's «Запустить Ollama» button prompt you
ollama pull aya-expanse:8b        # the interactive model — required
```

`aya-expanse:8b` is the interactive default and is what the acceptance harness measures
against unless told otherwise (`--model`, §5). The choice is not a preference: it is the model that met the sub-second
time-to-first-token requirement without corrupting identifiers — see `ModelPolicy.swift` and
`docs/reference/MEASUREMENTS.md`.

The app never starts Ollama for you. If it is not running, the window says so and offers a
button; the design decision is that a translator does not silently launch a server.

Everything speaks to `http://127.0.0.1:11434`. Nothing leaves the machine.

---

## 2. Build and run

```bash
swift build                       # library and executables
swift test                        # ~341 tests, entirely offline, a few seconds
./Scripts/make-app-bundle.sh      # assembles build/LocalTranslator.app (debug)
./Scripts/make-app-bundle.sh release
swift Scripts/make-icon.swift build/AppIcon.icns   # only to look at the icon on its own
open build/LocalTranslator.app
```

The icon is drawn by `Scripts/make-icon.swift`, not stored as a file. `make-app-bundle.sh` runs it
by itself whenever `build/AppIcon.icns` is missing or older than the generator — missing is the
common case on a fresh clone, since `build/` is git-ignored — so the command above is only needed
to inspect the rasters; it leaves `build/AppIcon.iconset/` behind for exactly that. Why the
mark is what it is, and why the 16 and 32 px rasters are a different drawing rather than a
downscale, is in `docs/design/specs/2026-07-29-app-icon-design.md`.

The app is `LSUIElement`: no Dock icon, no window at launch, just the menu-bar item. That is
deliberate and the scene order in `TranslatorApp.swift` is what enforces it — the comment there
says why, and it is load-bearing.

Two harnesses need a live Ollama and are not part of `swift test`:

```bash
swift run translate-cli --to ru --tone technical "text to translate"
swift run acceptance              # MUST run from the package root — it reads ./corpus
```

---

## 3. The signing identity — read this before the first rebuild

**macOS keys the Accessibility grant to the code signature.** Ad-hoc signing re-keys the bundle
on every build, so macOS treats each rebuild as a different program and asks for the permission
again — which makes the whole hotkey path unverifiable, because it is never granted for long
enough to test. This was the single biggest obstacle to finishing Plan 3.

A stable self-signed identity fixes it permanently. Create one once:

> Keychain Access → Certificate Assistant → Create a Certificate…
> Name: `LocalTranslator Dev` · Identity Type: Self Signed Root · Certificate Type: Code Signing

`Scripts/make-app-bundle.sh` picks it up by name and tells you which branch it took:

```
signed with LocalTranslator Dev — the Accessibility grant survives rebuilds
ad-hoc signed — macOS will ask for Accessibility again after each rebuild
```

Override with `CODESIGN_IDENTITY=… ./Scripts/make-app-bundle.sh` to use an identity you already
have. If the certificate is ever deleted the script falls back to ad-hoc **silently apart from
that line**, and the grant starts dying again.

Verified: with a stable identity the grant survives a genuine rebuild — checked with a release
build that produced a different CDHash, since a debug rebuild can leave the hash unchanged and
prove nothing.

---

## 4. The Accessibility permission

The app asks once at first launch. If you decline, or if you want to grant it later:

> System Settings → Privacy & Security → Accessibility

The permission lives under **Privacy & Security**, not under the Accessibility pane of the same
name that holds the accessibility *features* — a distinction the app's own prompt spells out,
because a user sent to the wrong one finds nothing and concludes the app is broken.

What needs it and what does not:

- **The hotkey itself does not.** It is registered through Carbon, which needs no grant, so
  ⌥⌘T fires on a fresh install. See `docs/adr/0002`.
- **Reading the selection does.** Both paths — the Accessibility read and the synthetic ⌘C
  fallback — are privileged. Without the grant the shortcut fires and the panel explains what
  is missing, which is the whole reason the Carbon choice matters.
- **The main window does not.** It works fully without any permission.

---

## 5. Running acceptance and reading it

```bash
cd /path/to/local-translator
swift run acceptance                                   # ModelPolicy's interactive model, 900-character chunks
swift run acceptance --model translategemma:12b        # any installed Ollama model
swift run acceptance --model translategemma:12b --chunk 4000   # and the app's chunk budget you actually run
```

It translates `corpus/` three times per file against a live model and prints per-file lines,
then ACCEPTED or FAILED, exiting 1 on regression. It is **not in CI** — deliberately, because it
needs a resident model — so it is run by hand before anything that touches the engine.

The first line of the output names the configuration it measured — model, chunk budget, and
whether each gate applies — so an entry pasted into `docs/reference/BASELINE.md` cannot describe
a different configuration than its heading claims.

Two gates: single-chunk time to first token under 1000 ms, and average cross-chunk terminology
adherence at or above 80 %. Multi-chunk TTFT figures are printed for information and not
asserted, because a multi-chunk run pays for the term-list call first. **The TTFT gate applies
only to the model `ModelPolicy` pins for the interactive path** — the sub-second requirement is
a property of that path and was measured on that model. Any other `--model` is being measured,
not certified: its single-chunk TTFT is printed with an `info only` suffix and recorded, never
failed. Likewise the `known` / `known-limitation` sets were measured on `aya-expanse:8b` and
name it in their reasons, so for any other model every markup diff is reported as unaccepted —
a new model's first entry shows what it actually does, and accepting one of its limitations
is a decision recorded in BASELINE.md, not something a reason string about a different model
can confer.

`known` and `known-limitation` lines are expected diffs, not warnings.

Record every run in `docs/reference/BASELINE.md` — that file explains how to read the output in full and
what a regression looks like. A run whose numbers nobody wrote down cannot be compared to
anything.

---

## 6. Where the user's data lives

- `~/Library/Application Support/LocalTranslator/glossary.json` — the user glossary and muted
  warnings. Hand-editable and git-trackable by design. The app refuses to overwrite it if it
  changed on disk since it was read, and refuses to write it at all if it was never
  successfully read. Settings → «Глоссарий» has a «Перечитать файл» button, which is the way
  out of that refusal after you edit it by hand.
- `UserDefaults` under `com.mordvic.localtranslator` — every scalar setting, including the
  hotkey as a single JSON value.

Nothing else is persisted. There is no translation history, by design.

---

## 7. When something is wrong

| Symptom | First thing to check |
|---|---|
| The hotkey does nothing at all | Is another app holding ⌥⌘T? Carbon refuses a combination already registered in the process, but not one held by another app — the OS gives it to whoever asked first. |
| The panel says «выделите текст» on a real selection | The app is probably not trusted. Check Settings → «Основные» for the standing warning. |
| The first press after login is slow | The warm-up may have failed, or `keep_alive` has expired. Cold load is about 2000 ms against 155 ms warm. |
| Accessibility keeps being asked for | Ad-hoc signing — see §3. |
| `swift run acceptance` crashes on startup | Run it from the package root; it reads `./corpus` relative to the working directory. |
