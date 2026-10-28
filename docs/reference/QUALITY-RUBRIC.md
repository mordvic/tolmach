# The judging rubric

**Rubric version: 1**

This line is held to `Rubric.version` by a test. Change anything a judge would decide
differently because of — an axis, a category, a tie rule — and the version changes with it:
verdicts given under two versions are never tallied together, because a changed rubric is a
changed instrument.

A judge — a fresh Claude sub-agent, or a person in `quality judge --human` — is handed a
**пакет**: a source text, what was asked of the model (the степень and the стиль), the facts
that had to survive, and two replies called **X** and **Y**. Which configuration produced which
is in a key the judge never sees. Every pair is judged twice with X and Y swapped; a preference
that does not survive the swap is recorded as «равны».

## Three axes, judged separately

For each axis answer **x**, **y** or **tie**. «Tie» is a real answer and the right one
whenever the difference is one you would not defend to the author. Do not balance the axes
against each other and do not produce an overall winner — there isn't one.

### смысл — meaning

Does the reply say what the source says: nothing lost, nothing added, nothing turned around?

Go through the packet's facts one by one, for X and then for Y, and list the id of every fact a
reply **lost or changed** in `lostFacts`. A fact survives when a reader of the reply alone would
still learn it; it does not have to be worded the same way. A number, a date, a name, an address,
who does what by when, and *which of two things* («before the trip, not after») are the usual
casualties. Then choose: the reply that lost fewer or lesser things wins; if neither lost
anything, **tie** — do not award смысл for style.

Смысл is a veto. A win on another axis by the side that lost a fact the other side kept is
reported apart and counts for nobody.

### стиль — the register that was asked for

Does the reply read as the **requested** style?

| asked for | reads as |
|---|---|
| `original` | the author's own register, kept. A reply that formalised a chatty note or loosened a formal one **missed**. |
| `friendly` | warm and informal, the way one writes to a colleague one knows well — not gushing, not a greeting card |
| `business` | formal and polite: letters, applications, official correspondence — and still readable, not bureaucratese |
| `professional` | a precise working register: documentation, reports; established terms, no bureaucratese, no familiarity |
| `plain` | short sentences, simple words, maximum readability — and nothing else about the register changed |

Judge against what was asked, never against which text you like more. A beautiful formal letter
is the *worse* reply when «дружеский» was asked. If both replies are in the source's register
untouched, that is a **tie** with `styleNotApplied` recorded for both.

Under the level «ошибки и стиль» the move is expected to be gentler than under «переписать»;
judge the direction, not the distance.

### естественность — does a native speaker write like this

Read each reply as its reader would, in its own language, without the source. Calques from the
other language, bureaucratic knots, wrong collocations, a sentence nobody would say aloud — and
the opposite failure, **text that sounds like a language model**: «I hope this message finds you
well», «Надеюсь, у вас всё хорошо!», an exclamation mark on every line, thanks for nothing in
particular, a closing offer to help further that the author never made. Those are `llmCliche`.

## Failure categories — a closed list

Record a failure only with a **verbatim quotation from the reply it is about**. A failure whose
quotation is not found in that reply's text is discarded by the scorer, so copy, do not
paraphrase, and keep it short — the phrase that shows the problem, not the paragraph.

| category | axis | it means |
|---|---|---|
| `factLost` | смысл | something the source states is gone — quote where it should have been, or the sentence that now lacks it |
| `factInvented` | смысл | the reply states something the source does not |
| `meaningDistorted` | смысл | present, but changed: the wrong party, the wrong direction, a condition turned into a fact |
| `answeredInstead` | смысл | the reply answers, obeys or comments on the text instead of editing or translating it |
| `styleNotApplied` | стиль | the requested style left no trace |
| `registerMissed` | стиль | a style was applied, and it is the wrong one or overshoots — slang in «дружеский», bureaucratese in «деловой» |
| `calque` | естественность | wording carried over from another language |
| `llmCliche` | естественность | a stock phrase of generated text |
| `grammar` | естественность | an error in the reply's own language |
| `needlessEdit` | правка | a change the level did not license — rewording under «только ошибки» |
| `errorLeft` | правка | an error in the source the reply was asked to fix and did not |
| `untranslated` | перевод | a fragment left in the source language |

If what is wrong is not on the list, say so in `note` and record no failure: a category invented
on the spot cannot be counted next to the others.

## What a verdict looks like

One JSON file per packet, named after it, under `verdicts/claude/` or `verdicts/human/`:

```json
{
  "packet": "p0007",
  "rubric": "1",
  "judge": "claude",
  "meaning": "y",
  "style": "x",
  "naturalness": "tie",
  "lostFacts": { "x": ["memo-before"], "y": [] },
  "failures": [
    { "side": "x", "category": "factLost", "quote": "при наличии служебной записки" },
    { "side": "y", "category": "styleNotApplied", "quote": "Лимит на оплату проживания составляет" }
  ],
  "note": null
}
```

## Calibration

A judge is calibrated **per axis** when it agrees with a person on at least 80 % of the pairs
neither called a tie, over at least 20 such pairs, reported as «N of M» (`JudgedReport`). Until
then every judged table opens with «JUDGE UNCALIBRATED». If agreement is below the bar the
*rubric* is what changes — and the calibration is then repeated **on new pairs**, because the
old ones have seen the answer.
