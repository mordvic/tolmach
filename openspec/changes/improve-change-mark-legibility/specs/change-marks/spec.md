# Spec Delta

## Purpose

Shows the reader of a правка result what changed, where, and in which form, in the window's перевод pane and in the hotkey panel. The marks must stay legible in both appearances and under Increase Contrast, and must never become part of the text the user copies or writes back.

## ADDED Requirements

### Requirement: Grounds the marks are held against
Every contrast figure in this capability SHALL be met against each ground of the appearance in use.

- Light: #ffffff (window), #edebea and #f1f0ee (hotkey panel material), #f5f5f5 (change card).
- Dark: #31302d (window), #494845 and #3c3937 (hotkey panel material), #4d4c48 (change card).

These are measured on screen. When a re-measurement finds a ground outside these values, the list SHALL be updated before any floor is relaxed.

#### Scenario: A colour passes on the window but fails on the panel
- **WHEN** a mark colour reaches 3.5:1 against #31302d but not against #494845
- **THEN** the colour does not meet this capability

### Requirement: Inserted text is marked with a dotted underline
Text a правка inserted or substituted SHALL carry a dotted underline. The underline SHALL be thin when the content font is below 17 pt and thick at 17 pt and above. Its pattern SHALL differ from the solid underline of a link.

#### Scenario: A corrected word at the default size
- **WHEN** «отчет» was corrected to «отчёт» and the content font is 13 pt
- **THEN** «отчёт» carries a thin dotted underline

#### Scenario: A corrected word at a large size
- **WHEN** the same correction is shown with the content font at 22 pt
- **THEN** «отчёт» carries a thick dotted underline

#### Scenario: A link beside a change
- **WHEN** an unchanged link and a changed word sit in one sentence
- **THEN** the link keeps its solid underline and the changed word carries the dotted one

### Requirement: Mark colour follows the accent and clears its floor
The mark colour SHALL be the system accent, moved toward the text colour (black in the light appearance, white in the dark) only as far as needed to reach 3.5:1 against every ground of that appearance. An accent that already reaches 3.5:1 SHALL be drawn unchanged.

#### Scenario: The purple accent in the light appearance
- **WHEN** the accent is purple and the appearance is light
- **THEN** the mark is drawn in the accent itself, because it already reaches 3.5:1 against #edebea

#### Scenario: The blue accent on the dark panel
- **WHEN** the accent is #007aff and a правка is shown on the hotkey panel in the dark appearance
- **THEN** the mark is lightened until it reaches at least 3.5:1 against #494845 and #4d4c48

#### Scenario: Every accent macOS offers
- **WHEN** each of the eight accent presets is checked in each appearance against every ground
- **THEN** every mark colour reaches at least 3.5:1

### Requirement: Removed text is struck through in a legible muted colour
In «Изменения», removed text SHALL be struck through and drawn in a colour that reaches at least 4.5:1 against every ground of the appearance and is lighter than the body text. The strike SHALL be drawn in that same colour and follow the underline's weight rule.

#### Scenario: Removed word in the light appearance
- **WHEN** «отчет» is shown as removed on the hotkey panel in the light appearance
- **THEN** its text reaches at least 4.5:1 against #edebea and it is struck through in the same colour

#### Scenario: Removed text at a large size
- **WHEN** the content font is 32 pt
- **THEN** the strike through removed text is thick

### Requirement: Separators around removed text are not struck
The spaces that separate removed text from its neighbours SHALL NOT be struck through. Only the removed words and marks are.

#### Scenario: Removed word before its replacement
- **WHEN** «отчет» is shown before «отчёт» in «Изменения»
- **THEN** the strike ends at the last letter of «отчет» and the space before «отчёт» is not struck

### Requirement: A pure removal is visible in «Результат»
A change that only removed text SHALL show a caret in the mark colour under the gap where the text stood, in «Результат» and «Исходник». It SHALL be reachable by ‹ ›, ⌘G and ⇧⌘G and by a click on the gap, and SHALL be announced to VoiceOver with the removed words.

#### Scenario: A repeated word removed
- **WHEN** «закончили закончили миграцию» became «закончили миграцию» and «Результат» is shown
- **THEN** a caret appears under the gap between «закончили» and «миграцию»

#### Scenario: Stepping to a pure removal
- **WHEN** the reader presses ⌘G and the next change is a pure removal
- **THEN** the gap is selected and the system find indicator points at it
- **AND** VoiceOver announces «Удалено: закончили»

#### Scenario: Clicking a pure removal
- **WHEN** the reader clicks the gap that carries the caret
- **THEN** the change card opens with only «Было»

### Requirement: Inserted punctuation is drawn in the mark colour
A change whose inserted text contains no letter or digit SHALL draw that text in the mark colour, in addition to its underline.

#### Scenario: A comma inserted
- **WHEN** «непонятно пишите» became «непонятно, пишите»
- **THEN** the comma is drawn in the mark colour

### Requirement: A rewritten block is marked by a bar, not an underline
A block-scope change SHALL carry no underline in any view. It SHALL be marked by one continuous change bar beside the whole block. In «Изменения» the removed block SHALL appear struck through above it, with its own bar. In the window, a click on its text SHALL NOT open its card, because its bar does; in the hotkey panel it SHALL.

#### Scenario: A paragraph rewritten under «переписать»
- **WHEN** a paragraph changed past the density threshold and «Результат» is shown
- **THEN** the paragraph's words are not underlined and one continuous bar runs beside all its lines

#### Scenario: The same paragraph in «Изменения»
- **WHEN** «Изменения» is shown
- **THEN** the old paragraph appears struck through above the new one, and each has its own continuous bar

### Requirement: Lines with changes carry a change bar
Every line that holds changed, inserted, struck or caret-marked text SHALL carry a bar in the mark colour at its leading edge, outside the text. The bar SHALL NOT move any text. In the hotkey panel it SHALL sit in the panel's own padding.

#### Scenario: A comma-only change in a long paragraph
- **WHEN** the only change on a line is an inserted comma
- **THEN** that line carries a change bar

#### Scenario: The panel settles on a правка
- **WHEN** a правка reply finishes streaming in the hotkey panel
- **THEN** the change bars appear in the panel's padding and no line of the reply shifts sideways

#### Scenario: Clicking a bar in the window
- **WHEN** the reader clicks the change bar beside a line in the window's pane
- **THEN** the change card opens for the first change on that line

#### Scenario: The panel's bars are not clickable
- **WHEN** the reader clicks beside a line in the hotkey panel's padding
- **THEN** nothing opens, because the bar lies outside the reply's view, and a rewritten block's card opens from a click on its text instead

### Requirement: Every counted change can be reached
Each change in the count shown by the window's status line and the panel's status row SHALL have a visible mark that ‹ ›, ⌘G and ⇧⌘G select, unless the change could not be located in the text. An unlocated change SHALL stay unmarked rather than be guessed.

#### Scenario: Six changes of every shape
- **WHEN** a paragraph holds a substitution, a pure insertion, a pure removal, an inserted comma, a change inside a link and a rewritten block
- **THEN** the status reads «6 изменений» and stepping visits six visible marks

### Requirement: Increase Contrast strengthens every mark
When Increase Contrast is on, every underline and strike SHALL be thick at every size. The mark colour SHALL reach 4.5:1 and removed text 6:1 against every ground. A change of the setting SHALL redraw a result that is already shown.

#### Scenario: The setting is turned on while a правка is shown
- **WHEN** the reader turns on Increase Contrast with a правка result on screen
- **THEN** the marks redraw thick without a new run, and the blue mark reaches at least 4.5:1 against #edebea

### Requirement: No fill behind changes
The system SHALL NOT draw a background colour behind changed, inserted or removed text. Only the system selection draws a background.

#### Scenario: Stepping selects a change
- **WHEN** the reader steps to a change
- **THEN** the only background on screen is the system selection over that change

### Requirement: Marks never reach the pasteboard or the document
«Скопировать», ⇧⌘C and «Заменить» SHALL carry the clean result. They SHALL carry no underline, strike, removed text, caret, bar or colour that the marks added. Bars and carets SHALL NOT be characters of the text, so no copy of any kind can carry them.

#### Scenario: Copying a marked result
- **WHEN** the reader copies a правка result with six changes shown in «Изменения»
- **THEN** the pasteboard holds the result text and its rich flavour without any of the marks or the removed words
