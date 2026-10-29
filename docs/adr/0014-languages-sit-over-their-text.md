# The languages sit over their text; the window is two sheets on a frame

Date: 2026-10-29. Status: accepted. Chosen by the user from three variants rendered on real
AppKit (the «framed sheet» one); the other two were a quieter version of the old split, and
that split with an inspector column for правка's changes.

## Context

The main window's toolbar carried the direction of a translation as a sentence: «Из Определить
⇄ В По правилу», then «Тон», then the primary action. Each half of that sentence describes one
of the two panes below it, and neither sat over the pane it described. The «Из» and «В» were
there only because the position did not say which side was which. The left pane's header held
the «Текст | Файлы» switch, the right one a caption, both on a grey band over a rule. In
перевод the toolbar was the widest row in the window: it wanted 750–780 pt on macOS 27 against
the window's 700 pt minimum, so «Тон» went into ».

DeepL and Google Translate lay out the same two texts the other way round. The kind of input
(text or files) is chosen above both texts. Each text has its language over it, and ⇄ sits
between the two languages.

## Decision

1. **Each pane is a sheet**: a bordered, rounded surface in the text ground, on a frame one
   tone off it (`PaneSheet`, `.paneSheet()`). The status row lies on the frame under them and
   has no band of its own.
2. **The languages sit in the sheets' headers** (`LanguageMenu`), with no «Из» and «В» because
   the position says it. With nothing chosen, a header names the language its text is in,
   plainly, as the design draws it: the target the rule chose over the перевод, and over the
   исходник the language the last run detected — only while that text is unchanged, because a
   header naming the language of a text that is gone is worse than «Определить язык». The menu's
   check mark is what says a name was not picked by hand. Under правка, which has no languages,
   the headers name the sheets instead: «Оригинал» (not «Исходник», which is the raw-Markdown
   view, `CONTEXT.md`) and «Правка». The исходник header also carries «207 символов».
3. **⇄ sits on the gap between the headers**, and **the gap is the divider** (`PaneSplit`).
   `HSplitView` draws its own hairline between the panes in a colour SwiftUI does not expose.
   Between two bordered sheets that hairline made three parallel lines four points apart.
4. **The toolbar holds what the whole window does**: «Текст | Файлы», «Перевод | Правка»,
   «Тон» or «Степень · Стиль», and the primary action at the trailing edge.
5. **«Локально · Ollama · модель»** ends the status row. This is the one promise the app makes
   that a cloud translator cannot, and it is true by construction (`docs/adr/0009`).

## Consequences

- The перевод row now fits from 590 pt, so it fits the window's 700 pt minimum. The правка row
  fits from 810 pt (830 with the longest names), because it gained the mode switch and lost
  nothing, and «Степень» and «Стиль» are titled by their value. Below that, «Степень · Стиль»
  go into » and «Исправить» stays. The window opens at 900 pt.
- The перевод sheet keeps its 360 pt floor: its narrowest header, the queue's with a file name,
  fits from 340. The sheets, the gap and the frame want 664 of the window's 700 pt.
- The design's own figures were adopted where the first build had its own: the header is 40 pt
  with the text 6 pt below it, the status band 8 + 18 + 6 pt, the language in the body size and
  the sheet titles in the subheadline semibold. Not adopted: the picture's language labels 8 and
  21 pt right of the text and ⇄ 3.5 pt off the gap's centre (its own text asks for one edge), its
  third view segment over plain text (`PaneViewChoice` offers «Исходник» only over Markdown), and
  its tighter paragraphs (it drew both texts through the Markdown renderer; the editor shows the
  text as typed). «Перевести» keeps the app's teal, `PrimaryButtonColour`.
- The divider is now custom code: a drag gesture, a pointer style and an accessibility
  adjustment. `HSplitView` gave all three for free. In return the window has no stray hairline,
  and ⇄ follows the boundary when it moves.
- `renderWindowPreview` draws an inactive window, in every state. The installed app was captured
  live only empty, light and active, and matched the render to half a point and to the pixel
  colour; the other states on the live app are owed to a pair of eyes
  (`docs/reference/OPEN-ITEMS.md`).
