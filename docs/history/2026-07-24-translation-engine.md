> Historical record of the build. Where this and the code disagree, the code is right.
>
> Copied verbatim from the session ledger that was written while the plan was executed.
> It records what was found, what was ruled, and what was rejected — including defects in
> the plan itself. It is not maintained: it is the account of a build that has finished.

# SDD ledger — plan: docs/design/plans/2026-07-24-translation-engine.md

Branch: feat/translation-engine
Started: 2026-07-25

Task 1: implemented (commit aebcb47), review found 1 Important
Task 1: finding — Package.swift declares OllamaKit/translate-cli/OllamaKitTests
  with no committed sources; empty dirs are untracked by git, so a fresh
  checkout errors. Conflicts with plan text (Task 1 mandates the full manifest).
  Escalated to human.
Task 1: fix round 1/5 (1 addressed, 0 open — Package.swift trimmed to two
  targets, empty dirs removed, build warning-free; commits aebcb47..41b8bf5)
Task 1: complete (commits 7fae77f..41b8bf5, review clean)
Task 1: minor (deferred): detectReturnsNilForUnsupportedOrEmpty covers only the
  empty-string branch, never an unsupported language
Task 1: minor (deferred): toneInstructionsAreNonEmptyAndDistinct asserts
  distinctness but never non-emptiness
Task 1: note — controller's plan edits were swept into commit 41b8bf5 by the
  implementer; content correct, history left as-is

Task 2: implemented (commit a2efbf3), review Approved with 1 Important
Task 2: finding (plan-mandated) — Chunker.swift:39-41 fallback branch is
  unreachable; brief prose claims whitespace-only input yields one chunk but
  the guard can never fire. Controller ruling: the plan is internally
  inconsistent (prose vs its own reference code), not a design choice —
  returning no chunks for whitespace-only input is correct, since the
  alternative sends whitespace to the model. Removing dead code + correcting
  the prose, not escalating.
Task 2: folding in one Minor deliberately — a regression test for the
  unterminated-fence path, which guards this task's core guarantee and was
  verified only by the reviewer's hand-trace.
Task 2: fix round 1/5 (3 addressed, 0 open — dead branch removed, whitespace
  contract pinned, unterminated-fence regression test added; commits
  a2efbf3..00057c6)
Task 2: complete (commits 41b8bf5..00057c6, review clean)
Task 2: minor (deferred): local `blocks` shadows the static method of the same
  name in chunk(_:maxCharacters:)
Task 2: minor (deferred): 4+ backtick fences and nested triple-backtick content
  are not handled (CommonMark allows them)

Task 3: implemented (commit bb3d8ce), review Needs fixes, 1 Important
Task 3: finding (plan-mandated) — relevantEntries uses naive substring match,
  so "ID" matches inside "valid". Escalated: human ruled keep substring.
  Rationale: a false positive costs one extra prompt line, not a wrong
  translation; and word-boundary matching breaks for zh/ja, which have no
  spaces and are in our target set. Limitation to be pinned by comment + test.
Task 3: fix round 1/5 (2 addressed, 0 open — substring decision documented in
  code, limitation pinned by test, doNotTranslate precedence tested; commits
  bb3d8ce..f92cbab)
Task 3: complete (commits 8ea2bed..f92cbab, review clean)
Task 3: minor (deferred): term.lowercased() recomputed per call in
  relevantEntries; trivial today, precompute if it ever becomes hot

Task 4: implemented (commit 37e1258), review Approved with 1 Important
Task 4: finding (plan-mandated) — phrase-level stop-word filter is inert:
  stopWords holds single words but the phrase key is space-joined, so
  "same resource" never matches. Controller ruling: this is a bug in the
  reference code, not a design choice — the plan plainly intends stop-word
  filtering and the code fails to deliver it for phrases. Fixing with
  any-component exclusion: our stop set is 60 generic function words, a
  technical term rarely depends on one, and the task's own framing puts
  precision above recall because these terms become forced terminology.
Task 4: note — NLTagger on this build produced ["resource", "profile",
  "server", "validation", "profile server"] for the test corpus
Task 4: fix round 1/5 (2 addressed, 0 open — any-component stop-word guard in
  the phrase loop, two non-vacuous exclusion tests; commits 37e1258..024d369)
Task 4: complete (commits f92cbab..024d369, review clean)
Task 4: minor (deferred): isContent checks at the two loop sites are always
  true by construction; harmless but misleading
Task 4: minor (deferred): no test pins surface-casing-of-first-occurrence

Task 5: complete (commit b84f539, review clean, no Critical/Important)
Task 5: note — Russian genitive «руководства» lemmatised correctly to
  «руководство»; matchesAcrossRussianCase returned true, not nil, on this build
Task 5: minor (deferred): lemma-or-surface fallback one-liner is duplicated
  verbatim between LemmaMatcher:15 and TermExtractor:38
Task 5: minor (carried into Task 6): nil/unverifiable path has no test; covering
  it at the GlossaryVerifier layer instead, where it is user-visible behaviour

Task 6: complete (commit 8191165, review clean, no Critical/Important)
Task 6: note — .unverifiable path now genuinely exercised: NLTagger yields zero
  lemmas for the punctuation-only string "-->", so the nil branch is reached
Task 6: minor (deferred): onlyMissingIsAWarning asserts only that distinct enum
  cases differ, which the compiler already guarantees — it exercises no
  verifier behaviour. Controller's own dictated test; candidate for removal at
  final review.
Task 6: minor (deferred): new public types carry no doc comments, unlike
  Glossary.swift

Task 7: complete (commit 3df3199, review clean, no Critical/Important)
Task 7: minor (deferred): no committed regression test for a multi-"=>" line;
  behaviour verified correct by reasoning (parts.count != 2 drops it)
Task 7: note — implementer caught a stale test count in the plan (step said 3,
  file had 5). Swept the whole plan: tasks 7, 8 and 10 all had stale counts
  from the revision; corrected before tasks 8 and 10 run.

Task 8: implemented (commit 1a5409a), review Needs fixes, 1 Important
Task 8: finding (plan-mandated) — the terminology header is gated on the entry
  list being non-empty, but bullets are only emitted for entries that resolve
  for the target language, so a glossary entry matched by substring but lacking
  a translation for that target yields a dangling header. Controller ruling:
  a bug in the reference code with no design fork — build the bullets first,
  emit the header only if any exist. Not escalating.
Task 8: fix round 1/5 (1 addressed, 0 open — bullets built first, header gated
  on bullets existing, positive case pinned; commits 1a5409a..417b332)
Task 8: complete (commits 3bf9077..417b332, review clean)

Task 9: implemented (commit 43fcb46), DONE_WITH_CONCERNS — implementer
  empirically confirmed a content-loss path: a document whose first line is
  exactly "Перевод" or "Translation" has that line stripped as preamble.
Task 9: controller ruling — tighten before review. The costs are asymmetric:
  failing to strip a preamble is cosmetic, stripping a real heading is silent
  data loss. New rule: a candidate line must be multi-word OR end in preamble
  punctuation. Catches every realistic preamble form, spares a bare one-word
  heading.
Task 9: complete (commits 417b332..3d13eb6, review clean, no Critical/Important)
Task 9: note — reviewer independently verified all five rows of the tightened
  preamble table, and that preamble-strip plus fence-unwrap cannot compound to
  destroy more than either alone
Task 9: minor (deferred): only Russian is covered by a committed bare-word-kept
  test; EN/DE/FR/ES verified only in the report's manual probes
Task 9: minor (deferred): preamblePatterns has no multi-word German form
  ("hier ist die übersetzung"), unlike EN/RU/FR/ES
Task 9: minor (deferred): preamblePunctuation CharacterSet built per call rather
  than hoisted to a static let

Task 10: implemented (commit 9854585), review Needs fixes, 2 Important
Task 10: findings (plan-mandated) — (a) precededByParen treats any "(" before a
  URL as a markdown link, so a parenthetical bare URL is misclassified and the
  bare-to-link substitution goes undetected; (b) a link whose visible text is
  the URL emits two tokens. Both reproduced concretely by the reviewer.
Task 10: controller ruling — no design fork, the behaviour is simply wrong.
  Fix by parsing markdown links properly, excluding URLs that fall inside a
  link's range, and preserving document order of the emitted tokens.
Task 10: note — reviewer independently re-derived the LCS table by hand and
  confirmed the single-diff result; also confirmed hardLineBreak cannot fire
  inside a fence, and that the empty-input guard is defensive noise
Task 10: fix round 1/5 (3 addressed, 2 new open — the controller-prescribed
  regex regressed titled links [text](url "Title") to bare, and a scheme-less
  target [text](www.example.com) now yields no token at all; commits
  9854585..22afc05)
Task 10: controller note — both regressions trace to the fix instruction I
  wrote, not to the implementer. Root cause is the crude `contains("://")`
  URL-ness test plus a regex that forbids spaces in the target.
Task 10: fix round 2/5 (2 addressed, 0 open — targetIsURL via NSDataDetector,
  regex widened for an optional quoted title; round-1 guarantees re-confirmed
  intact; commits 22afc05..bc03091)
Task 10: complete (commits 3d13eb6..bc03091, review clean, 2 rounds)
Task 10: minor (deferred): a target with trailing punctuation inside the parens,
  e.g. [docs](https://example.com.), yields zero URL tokens — the detector
  matches only part of it and the recorded link range then suppresses the bare
  pass. Narrow, needs malformed markup, and the check is advisory.
Task 10: minor (deferred): a URL containing parens (Wikipedia-style) truncates
  at the inner ")" — pre-existing, untouched by either round
Task 10: minor (deferred): no committed test pins that [text](./file.md) and
  [text](#section) contribute no URL token; verified only by reasoning

Task 11: complete (commit 732f230, review clean, no issues at any severity)

Task 12: NEEDS_CONTEXT — implementer stopped rather than adjust a test.
Task 12: finding — the Task 3 substring-filtering ruling has a consequence the
  controller's rationale missed. relevantEntries over-selects for the prompt
  (accepted, harmless) but the SAME set is handed to GlossaryVerifier, where a
  spurious entry becomes a false "term missing" warning — the cry-wolf failure
  the three-state design exists to prevent. Escalating: this revisits a human
  decision and the controller's stated reasoning for it was incomplete.
Task 12: note — Ukrainian sample detects as uk (weight ~1.0, Russian ~5.85e-11),
  so detectedSource == nil for the right reason; that test is sound.
Task 3 (reopened): word-boundary matching landed (commit 05354cc); plural case
  verified — "profile server" no longer matches "profile servers"
Task 12: residual — the boundary fix does not cover a term inside a URL or
  identifier: "/" and "." ARE boundaries by character class, but NLTagger treats
  "x.org" as one token, so Glossary and LemmaMatcher disagree about what a word
  is. Realistic for technical content (term FHIR, text fhir.org).
Task 12: controller ruling — apply the established principle rather than patch
  the test: GlossaryVerifier must not report .missing when the expected form is
  present as a plain substring. Such a case is ambiguous, so it becomes
  .unverifiable, which shows the user nothing. The change can only ever suppress
  a warning, never add one.
Task 12: complete (commit 1fd790c, review clean, no Critical/Important)
Task 12: note — reviewer independently cross-checked every collaborator
  signature against its real definition, and confirmed no second-pass trace
  survives anywhere via repo-wide grep
Task 12: minor (deferred): a failure of the term-list call aborts the whole
  translation, though the document glossary is an enhancement rather than the
  deliverable. Graceful degradation (glossary fails, translation proceeds) is
  worth considering at final review.
Task 12: minor (deferred): translate() is one ~65-line function; extracting the
  glossary block and final assembly would aid scanning
Task 12: minor (deferred): whole-document relevantEntries for verification vs
  per-chunk for prompting deserves a clarifying comment

Tasks 3+6 (reopened): review returned 2 Critical, both controller design errors
  (a) usesWordSeparation tests the TERM's script, not the text's. A Latin term
      inside unspaced CJK takes the boundary path, CJK chars are letters, so the
      boundary never opens and the entry vanishes from prompt AND verification.
      Strictly worse than the substring behaviour it replaced.
  (b) the verifier's substring suppression is unbounded, so "ID" matching inside
      "valid" in the TRANSLATION downgrades a real .missing to .unverifiable —
      the same defect commit 1 fixed, reintroduced on the other side.
Tasks 3+6: controller ruling — fix both as the reviewer proposes. Treat CJK
  characters as non-word in isWordCharacter, and replace the verifier's raw
  contains with the boundary-aware Glossary.occurs. Traced: FHIR/fhir.org still
  suppresses, ID/valid correctly still warns.
Tasks 3+6: critical fixes landed (commit d237c6e) — CJK treated as non-word in
  isWordCharacter, verifier suppression now uses boundary-aware Glossary.occurs,
  scalar ranges widened to Compatibility Ideographs and supplementary planes.
  Both traced cases confirmed by implementer: FHIR/fhir.org suppresses,
  ID/valid still warns. 77 tests green. Re-review dispatched.
Task 13: implemented (commit 368eb43), fresh-clone build verified by
  implementer; review dispatched
Tasks 3+6: re-review clean — both Criticals addressed, no new breakage. Filter
  and verifier now call the same Glossary.occurs, so the differing notions of
  "word" that caused the whole cross-component defect are unified rather than
  patched on each side. usesWordSeparation and isWordCharacter both delegate to
  one isWordSeparationless, so they cannot drift apart.
Tasks 3+6: minor (deferred): extended CJK scalar ranges (Compatibility
  Ideographs, supplementary planes) have no pinning test
Tasks 3+6: minor (deferred): Thai and other scriptio-continua languages still
  take the boundary path rather than the substring fallback
Tasks 3+6: minor (deferred): CJK-target verifier suppression still relies on raw
  substring containment, so a CJK form inside a larger compound could under-warn

Task 13: review Needs fixes, 1 Important (plan-mandated)
Task 13: finding — OllamaError.notRunning is unreachable for the case it exists
  to serve. URLSession throws a connection-level URLError before the
  HTTPURLResponse guard runs, so "Ollama is not reachable" never surfaces and a
  raw system error propagates instead. Spec section 8 requires that message.
  Controller ruling: no design fork, fix by remapping connection-level URLErrors.
Task 13: fix round 1/5 (2 addressed, 0 open — mapTransportError applied at both
  call sites including mid-stream, timeouts deliberately excluded, explicit
  TranslationCore test dependency; commits 368eb43..c564a6a)
Task 13: complete (commits 1fd790c..c564a6a, review clean)
Task 13: minor (deferred): chat() reports "see ollama logs" on non-200 rather
  than the body, since the streaming API has no up-front buffer

Task 14: implemented (commit 8782ceb), DONE_WITH_CONCERNS — first live-model
  runs in the project found a real defect in Task 12 that no unit test caught.
Task 14: finding (Critical, belongs to Task 12) — Translator.stream forwards
  onToken unconditionally, so the internal term-list call streams raw
  "term => translation" lines onto stdout ahead of the translation. Reproduced
  live. Breaks the CLI's core contract. Note: the Task 12 review verified that
  timeToFirstTokenMS is NOT contaminated by that call — because I asked about
  timing specifically. Token forwarding went unchecked because I did not name it.
Task 14: finding (for Task 15 corpus) — aya-expanse:8b translates technical
  identifiers like StructureDefinition when outside a code fence and not marked
  doNotTranslate
Task 14: finding — rejoining chunks with "\n\n" can manufacture spurious markup
  diff counts on unstructured input
Task 12: fix round 2/5 (1 addressed, 0 open — isTranslationOutput now gates both
  forwarding and timing, buffering stays unconditional so the glossary is still
  built; onTokenNeverReceivesTermListOutput proves the glossary was built AND
  its tokens never reached the consumer; commits 8782ceb..9df26d4)

Task 14: review Needs fixes — 4 Important, all plan-mandated, all in the brief's
  hand-rolled parser: text equal to a default value is dropped; text starting
  with "--" is dropped; unquoted multi-word text truncates to the last token;
  non-numeric --chunk silently falls back. Stream separation and exit codes are
  correct. Reviewer also answered the direct question: the CLI's own structure
  would NOT have contained the glossary leak — stdout purity rests entirely on
  Translator's contract.
Task 15: acceptance run RED (commit fb5514e). Three findings, and all three are
  threshold-design errors of the controller's, not engine regressions:
  1. adherence 80.6% on the official run, but 86.1% and 91.7% on re-runs of the
     same input — the metric is noisy at this sample size; all runs sit far above
     the 64-68% no-glossary baseline
  2. TTFT 3283ms vs <1000ms — structural: timeToFirstTokenMS spans the
     document-glossary call, which completes before the first translation token.
     The <1s claim belongs to the hotkey path (single chunk, no glossary); the
     harness applies it to a chunked document. Wrong shape, not slow code.
  3. 3 markup diffs on techdoc-en. One is REAL and is the checker succeeding:
     aya-expanse rewrote a bare URL as a markdown link — the exact defect
     MarkupSkeleton was built for, and which the prototype README already
     records. The "0 diffs" threshold contradicts that recorded measurement.
     Remaining diffs are a trailing-newline false positive worth fixing.
Task 14: fix round 1/5 (4 addressed, 0 open — parser rewritten as a single
  consuming pass; all five live commands verified; commit 55fd6cd). Note: the
  controller's snippet used Result<Options, String>, which does not compile
  since String is not Error — implementer substituted a ParseFailure struct.
Task 15: human ruling on recalibration — measure by shape. TTFT only on a
  single-chunk (hotkey-shaped) file; markup compared against a recorded list of
  known model behaviours with anything new failing; adherence averaged over
  three runs against an 80% floor.
Task 15: ACCEPTED on the recalibrated harness (commit e82d5a7), first and only
  run of the new code.
  - TTFT asserted on four single-chunk files: 162/222/320/341 ms, all well under
    1000 ms and in line with the prototype's 330-570 ms
  - markup: 2 diffs on techdoc-en, both tolerated as the recorded aya-expanse
    bare-URL-to-link rewrite; zero elsewhere; the trailing-newline phantom is
    gone, confirming cc0d1a0
  - adherence: article-en averaged 81.9% over three runs (80.6/77.8/87.5)
    against the 80% floor
Task 15: WEAKNESS — only article-en actually chunks, so the document glossary is
  exercised by exactly one file. Its margin is ~2 points over the floor with a
  10-point spread, and run 3 even had a different applicable-pair count (32 vs
  36), so the glossary's own composition varies. The other four files report
  "100% (n/a, single chunk)", which is honest labelling but measures nothing.
  A real 10-point regression might not reliably trip this; a noisy run might
  trip it spuriously.
Task 14: fix round 1 re-review clean (2nd attempt — the controller's first
  attempt supplied a diff range that excluded the very commit under review, so
  its conclusions rested on command output alone; the reviewer flagged that
  rather than passing it). All four findings addressed at code level; index
  arithmetic of the consuming loop traced correct in both directions; stdout
  contract enumerated write-by-write and intact.
Task 14: complete (commits c564a6a..55fd6cd, review clean)
Task 14: minor (deferred): --model/--from have no parse-time validation and
  greedily consume the next token, so "--model --to" absorbs the flag; fails
  safe but reports late. Pre-existing, not a regression.
Task 15: complete (commit e82d5a7, ACCEPTED)

Task 15: FINAL — ACCEPTED (commits 2b0546d prompt, 2b6e119 harness+corpus)
  adherence averages: article-en 83.8%, techdoc-en 88.4%, techdoc-ru 93.2%
  TTFT asserted on single-chunk files: 152 ms, 184 ms — well under 1000 ms
  markup: 2 known (URL rewrite) + 2 known-limitation (code-block string) on
  techdoc-en, all tolerated and printed; none elsewhere
Prompt experiment result: sharpening two rules fixed the blockquote-marker
  defect entirely and did not move the code-block string translation. No
  dilution — adherence rose on two files, unchanged on the third, no new diffs.
  One considered attempt was the agreed protocol; no second attempt made.
Known model limitation recorded: aya-expanse:8b translates human-readable
  strings inside code blocks. Allowance scoped by file AND token kind, never
  added to the global allowlist, because a codeBlock token carries only a
  per-process-seeded hash and blanket tolerance would mask a rewritten command.
Harness crash on transport failure fixed and verified against a dead port.
ALL 15 TASKS COMPLETE. Dispatching final whole-branch review.

FINAL BRANCH REVIEW: NOT READY. All findings reproduced by executing real code.
  CC-1 Critical: onToken streams RAW tokens, final is CLEANED — they diverge
    exactly when ResponseCleaner does its job. Third recurrence of the same
    stream-vs-final class on this branch.
  CC-2 Critical: cancellation does not cancel. AsyncThrowingStream finishes
    rather than throwing, so the chunk loop issues fresh requests for every
    remaining chunk and returns a TRUNCATED document as success. Spec 4.9 and
    plan claim this works; it does not.
  CC-3 Important: Chunker normalises whitespace, MarkupSkeleton diffs against
    the un-normalised source — a perfect echo yields phantom diffs, and
    hardLineBreak is genuinely destroyed. Corpus is green only by accident of
    its own formatting.
  CC-4 Important: user glossary occurrence check runs over raw chunk text
    including code, so a term inside a fence produces a prompt that both forbids
    and demands translation. Document glossary strips code; user glossary does
    not. ADR does not cover this drift.
  CC-5 Important: TermExtractor cannot produce terms for zh/ja — every Japanese
    token tags OtherWord, and key.count > 2 drops most Chinese terms. The
    document glossary is silently inert for CJK sources.
  CC-6 Minor: ignoredTerms matching is case-sensitive while every other term
    comparison is not.
  Readiness: Translator is not Sendable — a Swift 6 consumer fails to compile.

FIX WAVE (commit b804240): all final-review findings addressed, 97 tests green.
  CC-4 turned out to be TWO call sites, not the one the finding named — the
  per-chunk prompt filter and the final verifier check. Implementer caught it.
Fix-wave re-review: all findings ADDRESSED, no new Critical/Important breakage
  in production code. One Important TEST-COVERAGE gap parked:
  PARKED — the new CC-2 cancellation test cancels 80ms in, while the term-list
    reply takes ~700ms to stream, so cancellation always lands in the term-list
    call and the per-chunk-loop checks are never exercised. Those checks are
    correct by direct inspection, but a future change removing only them would
    keep the suite green. Ruling: real, not load-bearing for merge (production
    code verified correct); surfaced to the human rather than triggering a
    second fix wave, per the skill's one-wave rule.
Acceptance after fixes: ACCEPTED. article-en 86.1% (identical all three runs),
  techdoc-en 88.4%, techdoc-ru 93.8%; TTFT 224/344 ms asserted; markup diffs
  only the two known + two known-limitation on techdoc-en.

Cancellation test gap CLOSED (commit 749d3c4, 98 tests). FakeLLMClient gained a
  per-call-start signal so the test cancels deterministically inside the chunk
  loop rather than racing sleep durations. Verified by removing ONLY the
  per-chunk checks: the test failed with translatedChunks ["", ""] returned as
  success and 3 calls instead of 2 — the original defect, caught.
  Honest finding surfaced rather than forced: removing only the term-list checks
  does NOT fail, because Swift cancellation is sticky and the loop's first check
  catches it one statement later with identical observable behaviour. Those
  checks are defence-in-depth, not independently observable. Not a defect.
Spec brought into line with the engine (commit 0f59de3): corrector references
  removed from the component table and the plan's file map; section 10 thresholds
  rewritten to measure by shape with the rationale; section 4.9 rewritten for
  chunk-level delivery and explicit cancellation; new section 11a records five
  measured, unfixed limitations.
BRANCH COMPLETE.

CODE REVIEW (7 findings) FIXED — commit e9c5bb0, 110 tests green.
  1. fence-only chunk lost its ``` markers: ResponseCleaner.clean gained
     allowFenceUnwrap, Translator passes !chunk.containsCodeFence. The data was
     already there since Task 2 — only the wiring was missing.
  2. inline code always preceded URLs: both kinds now collected with UTF-16
     positions into one array and sorted together.
  3. ordered-list heuristic accepted any digit-led line containing ". ".
  4. timeToFirstTokenMS is Double? — an empty reply no longer reports the whole
     run as latency; acceptance treats nil as its own failure, CLI prints em dash.
  5. stats append gated on isTranslationOutput, consistent with tokens and timing.
  6. acceptance adherence pct is Double?; average over non-nil only.
  7. OllamaStreamParser.parse returns [ChatEvent] so a combined content+done
     frame loses neither.
  Revert evidence obtained for 1, 2, 3 and 7.
  GAP surfaced honestly by the implementer: finding 6 has no test, because the
  acceptance target is an executable with no test target — the harness that
  checks the engine is itself unchecked. Verified by hand-trace instead.
Acceptance after the seven fixes: ACCEPTED. article-en 82.4% (77.8-86.1 spread),
  techdoc-en 88.4%, techdoc-ru 94.4%; TTFT 220/348 ms asserted; markup diffs
  unchanged — same two known + two known-limitation on techdoc-en, none new.
  The altered markup tokenisation did not shift the harness's verdict.

SECOND CODE REVIEW (4 findings) FIXED — commits 391958f, f77ffdf, c038b89,
  fa908f8; 115 tests. Fix 1 restored incremental delivery and redefined TTFT to
  stamp the first consumer-visible emission.
  Implementer caught a false green in their own first draft: the new tests
  checked only stream==final, which held against the reverted code too. They
  redesigned around call count and a timing gap before committing.
ACCEPTANCE AFTER: RED, and correctly so — snippet-en.md TTFT 1307 ms >= 1000 ms.
  Diagnosis: the buffer-until-newline rule I specified degenerates for a reply
  with no newline at all. email-en (453 ms) opens with a greeting line so the
  newline arrives early; snippet-en is a single paragraph, so it falls to the
  buffered path and TTFT equals full generation. The most hotkey-like input —
  a short selection with no line breaks — got the worst behaviour, which is
  precisely the shape the requirement describes.
  Threshold is right; my design was wrong. Refining: flush also when the
  NORMALISED buffer length passes 60, the same ceiling isPreambleLine uses.
  Normalisation only removes characters, so normalised length is monotonically
  non-decreasing — once past 60 no continuation can make the line a preamble,
  and emitting immediately is provably safe.
Refinement landed (commit 30e1567, 118 tests). The 60-char ceiling now exists in
  exactly one place — ResponseCleaner.preambleLineMaxLength, with normalisation
  factored into a shared helper used by both isPreambleLine and the flush
  condition, so the two cannot drift.
ACCEPTANCE: ACCEPTED. snippet-en TTFT 1307 -> 464 ms, email-en 453 ms — both now
  measuring first CONSUMER-VISIBLE output, not a wire event. Adherence rose too:
  article-en 85.6%, techdoc-en 87.8%, techdoc-ru 94.4%.
  The sub-second hotkey guarantee is now real rather than nominal.
