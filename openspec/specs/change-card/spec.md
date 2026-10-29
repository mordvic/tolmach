# change-card Specification

## Purpose

Shows one change of a правка as «было → стало» when the reader clicks its mark, with the single action «Вернуть». The words must be readable at a glance and the card must fit on screen whatever the change's length.

## Requirements

### Requirement: The card shows the sides the change has
The card SHALL show «Было» with the removed text when the change removed something, and «Стало» with the inserted text when it inserted something. A pure removal SHALL show only «Было», a pure insertion only «Стало». No empty side SHALL be drawn.

#### Scenario: A substitution
- **WHEN** the reader clicks the mark on «отчёт», which replaced «отчет»
- **THEN** the card shows «Было» with «отчет» and «Стало» with «отчёт»

#### Scenario: A pure removal
- **WHEN** the reader clicks the caret of a removed «закончили»
- **THEN** the card shows only «Было» with «закончили»

### Requirement: The card's words are set at the system body size
The changed words SHALL be set at the system body size in the content font's family, and the «Было» and «Стало» labels at the system caption size. Neither SHALL follow the «Шрифт текста» size setting.

#### Scenario: The content font is 32 pt
- **WHEN** the reader has set «Шрифт текста» to 32 pt and opens a card
- **THEN** the card's words are at the system body size, not at 32 pt

### Requirement: The card draws the same marks as the text
In the card, removed words SHALL be struck through in the removed-text colour of `change-marks`. Inserted words SHALL carry the same dotted underline in the mark colour. Removed words SHALL reach at least 4.5:1 against the card's ground: #f5f5f5 in the light appearance, #4d4c48 in the dark.

#### Scenario: Removed words in the light appearance
- **WHEN** a card shows removed words in the light appearance
- **THEN** they reach at least 4.5:1 against #f5f5f5 and are struck through

#### Scenario: Inserted words
- **WHEN** a card shows inserted words
- **THEN** they carry a dotted underline in the mark colour

### Requirement: The card's width is bounded
The card SHALL be no wider than 320 pt of text and SHALL wrap longer text onto further lines, growing in height instead of width.

#### Scenario: A rewritten paragraph
- **WHEN** the reader opens the card of a 400-character rewritten paragraph
- **THEN** the card's text column is at most 320 pt wide and the paragraph wraps onto several lines

### Requirement: «Вернуть» is offered only where it cannot guess
«Вернуть» SHALL be enabled only for a substitution that can be located in the result. For a pure removal, a pure insertion or an unlocated change it SHALL be disabled, and its help text SHALL give the reason.

#### Scenario: A pure insertion
- **WHEN** the reader opens the card of an inserted «всей»
- **THEN** «Вернуть» is disabled and its help text says why
