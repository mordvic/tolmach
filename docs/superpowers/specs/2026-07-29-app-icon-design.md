# App icon — design

Date: 2026-07-29
Status: approved for implementation

## Status of this document

This is the pre-implementation design. It records the mark, the reasoning the mark rests on, and
how the icon is to be produced. Once `Scripts/make-icon.swift` exists, the script is the authority
on geometry and this document is the authority on *why* the geometry is what it is.

---

## 1. What is missing today

`Sources/TranslatorApp/Info.plist` declares no `CFBundleIconFile`, and `Scripts/make-app-bundle.sh`
never creates `Contents/Resources`. The assembled bundle therefore has no icon at all: the app shows
as a blank sheet in Finder, in Spotlight, and — the one that matters — in the
System Settings → Privacy & Security → Accessibility list, where the user has to identify this
application by name alone in order to grant it the permission the hotkey path depends on.

The menu-bar glyph is a separate thing and is not missing: `TranslatorApp.swift` renders the SF
Symbol `character.bubble`. It stays. See section 8.

## 2. The mark

### 2.1 What the name dictates

«Толмач» is not a generic word for translator, and the icon should not be generic either.

- **Etymology.** On the accepted derivation the word is a Turkic borrowing (*tïlmač*, from *til*
  «tongue»); German *Dolmetscher*, Hungarian *tolmács* and Polish *tłumacz* come from the same
  source. The word for a translator is itself a word that crossed languages.
- **Office.** In the Посольский приказ, толмачи and переводчики were separate staff positions: the
  толмач interpreted **orally**, at negotiations; the переводчик worked on documents. The толмач
  stood between two parties and carried **someone else's speech**, never speaking as himself.

That second fact decides the mark, and it disqualifies the obvious choice: a Cyrillic **Я** reads
equally as the first-person pronoun, which is precisely what an interpreter is not. An icon for this
name has to say *«I carry what was said»*, not *«I speak»*.

Reported speech in Russian is set in guillemets. In this repository guillemets are not decoration
but a standing rule — CLAUDE.md requires «ёлочки» and «ё» in every user-facing string. A mark built
out of « » is therefore built out of the project's own punctuation.

### 2.2 The mark

**«Т»** — the initial of the Russian name, set between guillemets, on an ink-coloured tile.

A bare Т belongs to nobody. Set in quotation marks it becomes a name being *quoted* — spoken by
someone other than its owner, which is the whole job description.

### 2.3 Orientation is fixed

The guillemets point **outward**: « Т ». Turning them inward to face each other would read better as
a graphic — two arrows meeting in the middle, the interpreter's position — but »…« is the German
convention. A project that insists on «ё» does not get to invert Russian quotation marks for a
prettier arrow. This is a constraint on the design, not a preference.

### 2.4 Palette

From the manuscript tradition the name belongs to: cinnabar was the colour the important letter was
written in.

| Role | sRGB | Where |
|---|---|---|
| Ink | `#1B2430` | tile ground |
| Parchment | `#EFE7D7` | the letter Т |
| Cinnabar | `#D9583F` | the guillemets |

Exactly two archaic signals are permitted: the cinnabar and the seriffed letterform. The tile,
the fills and the geometry are flat and modern — no paper texture, no gradient, no emboss.

The user chose the ink ground over the parchment ground (which was the recommendation) with the
trade-off stated: the dark tile is more severe and separates less well from a dark desktop
background. That is a made decision, not an oversight.

### 2.5 Rejected, and why

| Rejected | Reason |
|---|---|
| Diagonal split with Latin **A** over Cyrillic **Я** | Reads well and scales well, but says only «two alphabets» — true of every translator, specific to none. |
| Speech bubble with **Я** inside | Semantically close (oral interpreting) and a relative of the menu-bar glyph, but carries the Я problem of §2.1 and loses everything but a silhouette at 16 px. |
| **Я** between brackets | Says «offline», reads as a developer utility, and again Я. |
| **Т** split by a vertical seam, inverting across it | The sharpest metaphor for the office — the letter standing exactly on the border between two sides — and the best-looking of the set at full size. Dropped because the seam eats the letter at 16 px, and an app icon lives mostly at small sizes. |

## 3. Geometry

The canvas is 1024×1024. The tile body is the standard macOS app-icon grid: **824×824 centred**,
corner radius **185.4**, i.e. the artwork does not run to the edge of the canvas.

Artwork inside the body is specified in a **100×100 unit box** mapped onto the 824×824 body, so the
numbers below are the same numbers the approved sketch was drawn with.

- Guillemets — four chevrons, stroke width 5, miter joins, butt caps:
  - left: `M22 40 L14 50 L22 60` and `M32 40 L24 50 L32 60`
  - right: `M68 40 L76 50 L68 60` and `M78 40 L86 50 L78 60`
- Letter Т — a system serif (New York; Georgia if unavailable), centred at x = 50, baseline at
  y = 66. **Its size is derived from cap height, not from a point size**: the font size is computed
  so the cap height comes to 31 units. A point size hardcoded against one font silently changes the
  mark if the font is substituted; a cap-height target does not.

### 3.1 The two small sizes are a separate drawing

At a 16 px raster the body is ≈12.9 px across, so a 5-unit stroke lands on **0.64 px** — it aliases
into a grey smear and the two chevrons of each guillemet merge. Downscaling the full mark is
therefore not acceptable at the bottom of the range.

- **Rasters 64 px and up** — the mark as specified above.
- **Rasters 16 px and 32 px** — the simplified mark:
  - **one** chevron per side instead of two: `M28 40 L20 50 L28 60` and `M72 40 L80 50 L72 60`,
    stroke width **9**;
  - the Т drops to a cap height of **27** units with its baseline at **y = 64**.

  Both halves of that are forced by the same measurement. Widening the stroke to 9 pushes the
  chevron's miter edge out to x ≈ 35.5 while the Т's left sidebearing sits at x ≈ 36.5 — a gap of
  1.5 units, which is **0.19 px** at a 16 px raster, i.e. the chevron and the letter fuse into one
  blob. Moving the chevrons outward and shrinking the letter opens the gap to ≈ 6.7 units (0.86 px
  at 16 px, 1.7 px at 32 px). The baseline moves from 66 to 64 so the smaller letter stays
  optically centred on the chevrons at y = 50.5.

  At the full mark's stroke width of 5 the same gap is ≈ 2.5 units and needs no adjustment.

## 4. How the icon is produced

**The icon is code, not a committed binary.** `Scripts/make-icon.swift` draws every raster with
Core Graphics and hands the set to the system `iconutil`:

```bash
swift Scripts/make-icon.swift build/AppIcon.icns
```

- Run with `swift <file>`, not as a SwiftPM target. A new target would have to repeat
  `.swiftLanguageMode(.v5)` and the platform floor, and would put a drawing tool into the shipped
  package graph for no benefit.
- Imports AppKit / CoreGraphics only — the no-external-dependencies rule holds.
- Writes the ten `AppIcon.iconset` members (`icon_16x16`, `icon_16x16@2x`, `icon_32x32`,
  `icon_32x32@2x`, `icon_128x128`, `icon_128x128@2x`, `icon_256x256`, `icon_256x256@2x`,
  `icon_512x512`, `icon_512x512@2x` — rasters 16 through 1024), then invokes `iconutil -c icns`.
- Exits non-zero if `iconutil` fails. A bundle without an icon must fail loudly, not quietly ship.

The alternative — draw it once by hand and commit an `.icns` — was rejected: a binary in the tree
has no reviewable diff, and in six months nothing records where it came from or how to change the
red.

## 5. Bundle integration

In `Scripts/make-app-bundle.sh`:

1. `mkdir -p "$APP/Contents/Resources"`.
2. Regenerate `build/AppIcon.icns` when `Scripts/make-icon.swift` is newer than it (a `-nt` test —
   the script takes a few seconds to compile and every bundle build should not pay it).
3. Copy it to `$APP/Contents/Resources/AppIcon.icns`.
4. **All of the above before `codesign`.** The signature covers `Contents/Resources`; a resource
   added afterwards leaves the bundle's seal broken, and on this project a broken seal costs the
   Accessibility grant the script exists to preserve.

In `Info.plist`: `<key>CFBundleIconFile</key><string>AppIcon</string>` — the name without the
extension. `CFBundleIconName` is the asset-catalog key and does not apply to a hand-assembled
bundle; it is not added.

## 6. Verification

There is no unit test. The generator is a script, not a target, so `swift test` cannot reach it, and
`swift test` is required to stay offline and fast. What is checked instead:

| Check | How |
|---|---|
| Every raster exists at the right pixel size | `sips -g pixelWidth -g pixelHeight` over the iconset |
| The `.icns` is well-formed | `iconutil -c iconset` round-trips it back to a directory |
| The artwork is actually right, not merely present | the generated PNGs are opened and looked at — at 1024, and at 32 and 16 where the simplified drawing of §3.1 has to be confirmed as a *different* drawing |
| The signature covers the resource | `codesign --verify --deep --strict build/LocalTranslator.app` |

**What no automated check can establish**, and what therefore goes to `docs/OPEN-ITEMS.md` §1 as
owed to a human: how the icon reads in Finder, in Spotlight, in the Accessibility list, and against
a dark desktop background — the last one being the specific risk the user accepted in §2.4. Note for
whoever looks: Finder caches icons aggressively, so a stale blank sheet after the first build is a
cache artefact, not a failure.

## 7. Accepted limitations

- **No drop shadow.** System icons have one; this will sit slightly flatter beside them. Adding it
  means a second render pass and a shadow that has to be re-tuned per raster size, for an effect
  that is nearly invisible at 32 px. Out of scope for v1.
- **`.icns`, not the macOS 26 `.icon` format.** The platform floor is macOS 14; `.icns` is correct
  and current for every supported version. Revisit only if the floor rises.
- No installer, DMG or App Store artwork — nothing in this project produces them.

## 8. Out of scope: the menu-bar glyph

`character.bubble` stays. A custom template image would have to be drawn at three sizes and would
lose the automatic adaptation to menu-bar height and to the light/dark menu bar that the SF Symbol
gets for free. The mark of §2.2 is pure geometry plus one letter, so it can be reduced to a
monochrome template later without redesign — but that is a separate decision with its own manual
verification, and it is not taken here.
