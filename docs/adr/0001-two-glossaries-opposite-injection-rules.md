# The user and document glossaries are injected by opposite rules

The **пользовательский глоссарий** (user glossary) is filtered by occurrence — only entries
whose term appears in a given чанк reach that chunk's prompt. The **документный глоссарий**
(document glossary) is not filtered at all: every entry goes into every chunk.

The rules are opposite deliberately, because the two solve different problems. A user glossary
may hold hundreds of entries of which a handful are relevant to any one text; injecting the
whole list bloats the prompt and costs quality. A document glossary is extracted from the very
document being translated and is capped at twenty entries — by construction it contains nothing
irrelevant, and filtering it by surface form would drop a term in exactly the chunks where it
appears in another grammatical case, which is precisely where cross-document consistency is
needed.

Measured 2026-07-25: injecting without filtering raised cross-chunk terminology adherence from
64–68 % to 88 % over two runs. The substring-filtered variant was never tried in production,
but it was the reason the previous mechanism — passing the preceding paragraph as context —
failed to hold terminology.

## Consequences

A reader will see one glossary filtered and the other not, and it looks like an inconsistency.
They must not be unified: filtering the document glossary brings back дрейф терминологии
(terminology drift), and removing the filter from the user glossary bloats the prompt.

The price is up to twenty terms in every chunk's prompt. At a chunk size of 900 characters the
glossary can be a noticeable share of the prompt, which is why the cap is twenty rather than the
forty originally intended.
