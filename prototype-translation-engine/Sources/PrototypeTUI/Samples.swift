import Foundation
import TranslationEngine

struct Sample {
    let title: String
    let kind: String
    let text: String
}

enum Samples {
    static let glossary = Glossary(entries: [
        GlossaryEntry(term: "FHIR", doNotTranslate: true),
        GlossaryEntry(term: "StructureDefinition", doNotTranslate: true),
        GlossaryEntry(
            term: "profile server",
            translations: ["ru": "сервер профилей", "de": "Profilserver", "fr": "serveur de profils"]
        ),
        GlossaryEntry(
            term: "implementation guide",
            translations: ["ru": "руководство по реализации", "de": "Implementierungsleitfaden", "fr": "guide d'implémentation"]
        ),
        GlossaryEntry(
            term: "changelog",
            translations: ["ru": "журнал изменений", "de": "Änderungsprotokoll", "fr": "journal des modifications"]
        ),
    ])

    static let all: [Sample] = [
        Sample(
            title: "Tech doc with code (EN)",
            kind: "techdoc",
            text: """
            ## Publishing an implementation guide

            The profile server validates every `StructureDefinition` before it is published. \
            Validation runs against the FHIR R4 base specification, and any resource that fails \
            is rejected with a machine-readable report.

            Run the publisher locally before opening a pull request:

            ```bash
            profile-server publish --ig ./ig.json --strict --out ./dist
            ```

            If validation fails, the exit code is `2` and the report is written to \
            `./dist/validation-report.json`. See https://build.fhir.org/validation.html for the \
            full list of severity levels.

            > **Note:** the `--strict` flag also promotes warnings to errors. Leave it off during \
            > early drafting, and add it once the changelog is stable.
            """
        ),
        Sample(
            title: "Техдока с кодом (RU)",
            kind: "techdoc",
            text: """
            ## Синхронизация сессии

            Сервер профилей считается источником истины для состояния сессии. Клиент \
            не должен самостоятельно продлевать срок жизни токена — он обязан дождаться \
            ответа от `/session/sync` и применить полученное состояние целиком.

            ```typescript
            const state = await syncSession({ signal: controller.signal });
            if (state.status === "revoked") {
              await hardLogout({ reason: "server-revoked" });
            }
            ```

            Если запрос завершился таймаутом, повторите его с экспоненциальной задержкой, \
            но не более трёх раз. Подробности — в журнале изменений релиза 19072.
            """
        ),
        Sample(
            title: "Business email (EN)",
            kind: "email",
            text: """
            Hi Anna,

            Thanks for turning the review around so quickly. I've folded in almost all of your \
            comments — the only one I pushed back on is the retry limit, and I've left a note on \
            the thread explaining why three attempts is the ceiling we agreed with the platform team.

            One thing I could use your help with: the changelog entry needs sign-off from someone \
            on the clinical side before Thursday. Would you be able to take a look, or should I \
            route it to Marc instead?

            No rush on the rest — happy to pick it up next week.

            Best,
            Dmitriy
            """
        ),
        Sample(
            title: "Long article, forces chunking (EN)",
            kind: "article",
            text: """
            Local language models have quietly crossed a threshold. Two years ago, running a \
            capable multilingual model on a laptop meant accepting output that was obviously \
            worse than what a cloud service would give you. That gap has narrowed to the point \
            where, for many everyday tasks, it is no longer the deciding factor.

            The shift has less to do with raw parameter counts than with training data curation. \
            A model trained deliberately on balanced multilingual corpora will outperform a much \
            larger model that saw English for ninety percent of its tokens. This is why an \
            eight-billion-parameter model tuned for twenty-three languages can beat a thirty-billion \
            generalist on translation into Portuguese or Turkish, while losing badly to it on \
            mathematical reasoning.

            Latency tells a similar story. The perceived speed of a local translator is dominated \
            not by generation throughput but by whether the model is already resident in memory. \
            A model that has been evicted costs several seconds to load from disk before it emits \
            a single token, which is precisely the delay that makes a keyboard-shortcut workflow \
            feel broken. Keeping the model warm turns the same hardware from unusable into instant.

            The remaining honest weakness is consistency across long documents. A model translating \
            a fifteen-page specification in pieces has no memory of how it rendered a term on page \
            two by the time it reaches page eleven. Cloud services solve this with translation \
            memories and enforced glossaries. Local tooling has to do the same work explicitly, \
            carrying terminology forward between chunks rather than hoping the model remembers.

            None of this makes local translation strictly better. It makes it different, with a \
            trade that many people will take: slightly rougher output, in exchange for text that \
            never leaves the machine.
            """
        ),
        Sample(
            title: "Mixed markup edge cases (EN)",
            kind: "edge",
            text: """
            Set `keep_alive` to `30m` and pass `--num-predict 512`. The endpoint is \
            http://127.0.0.1:11434/api/chat and the fallback is https://example.org/v1/translate.

            ```json
            {
              "model": "aya-expanse:8b",
              "keep_alive": "30m",
              "options": { "temperature": 0.2 }
            }
            ```

            Contact ops@example.org if the load time exceeds 2000 ms on a warm cache.
            """
        ),
    ]
}
