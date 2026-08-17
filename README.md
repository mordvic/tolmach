# Толмач

A macOS translator that runs entirely on local language models. Select text anywhere, press
⌥⌘T, and the translation appears in a panel beside the cursor. Nothing leaves the machine.

Built for technical documentation and business correspondence: it keeps Markdown structure
intact, keeps terminology consistent across a long document, and tells you when it could not.

**Status:** v1 complete and working — hotkey capture, translation window, four settings tabs.
Batch file translation is v2. The interface is Russian.

---

## Requirements

- macOS 14 or later
- [Ollama](https://ollama.com) running locally
- One model pulled: `aya-expanse:8b`

No other dependencies — the app builds against Foundation, SwiftUI, AppKit and the system
frameworks, and nothing else.

---

## Quick start

```bash
ollama pull aya-expanse:8b
git clone https://github.com/mordvic/tolmach.git
cd tolmach
./Scripts/make-app-bundle.sh
open build/LocalTranslator.app
```

Then, in order:

1. **Create a signing certificate first if you plan to rebuild.** macOS ties the Accessibility
   permission to the code signature, so an ad-hoc-signed build asks for it again after every
   rebuild. Keychain Access → Certificate Assistant → Create a Certificate, name it
   `LocalTranslator Dev`, type Code Signing, self-signed. The build script finds it by name and
   tells you which branch it took.
2. **Grant Accessibility** when asked, or later in System Settings → Privacy & Security →
   Accessibility. The hotkey fires without it; reading your selection does not.
3. **Select some text and press ⌥⌘T.**

The app lives in the menu bar — no Dock icon, and no window until you ask for one.

Full detail, including what to check when something misbehaves:
[`docs/RUNBOOK.md`](docs/RUNBOOK.md).

---

## What it does that a translation box does not

- **Keeps terminology consistent across a long document.** Before translating, it extracts the
  terms that recur, translates that list once, and holds every chunk to it. Worth about twenty
  points of cross-chunk consistency, measured.
- **Leaves code alone.** Fenced blocks are never split across chunks, and inline code, links
  and URLs are compared before and after, so you are told if the model rewrote one.
- **Says when it is unsure.** Glossary terms it could not honour and structure that changed are
  listed under the result, in Russian, without hashes or developer jargon.
- **Never takes your clipboard.** Where it has to fall back to a synthetic ⌘C to read a
  selection, it snapshots the whole pasteboard first and puts it back — every type, every item,
  byte for byte.

---

## Documentation

| Document | Read it when |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | You are about to change anything. Commands, architecture, and the facts that bite. |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Building, signing, permissions, running the acceptance harness. |
| [`docs/OPEN-ITEMS.md`](docs/OPEN-ITEMS.md) | You want to know what is unfinished, what is deliberate, and what is still an open question. |
| [`docs/PLATFORM-TRAPS.md`](docs/PLATFORM-TRAPS.md) | You are writing a new call into `NSPasteboard`, Accessibility, Carbon or `NSPanel`. |
| [`docs/TESTING.md`](docs/TESTING.md) | You are writing a test. Especially then. |
| [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md) | You want to know where a number came from. |
| [`docs/BASELINE.md`](docs/BASELINE.md) | You ran the acceptance harness and want to know whether the result is normal. |
| [`docs/adr/`](docs/adr/) | The code looks inconsistent and you want to know whether it is deliberate. |
| [`docs/design/specs/`](docs/design/specs/) | You are changing engine behaviour. Note its status header: where it and the code disagree, the code is right. |
| [`docs/history/`](docs/history/) | You want the account of how it was built, and what was tried and rejected. |
| [`CONTEXT.md`](CONTEXT.md) | You are writing UI copy or naming something. |

---

## Development

```bash
swift build
swift test                        # ~289 tests, fully offline
swift run acceptance              # needs a live Ollama; run from the package root
```

There is no CI, deliberately: the acceptance harness measures a real model against a corpus and
cannot run on a runner without one.
