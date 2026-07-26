## Publishing an implementation guide

The profile server validates every `StructureDefinition` before it is published. Validation runs against the FHIR R4 base specification, and any resource that fails is rejected with a machine-readable report.

Run the publisher locally before opening a pull request:

```bash
profile-server publish --ig ./ig.json --strict --out ./dist
```

If validation fails, the exit code is `2` and the report is written to `./dist/validation-report.json`. See https://build.fhir.org/validation.html for the full list of severity levels.

> **Note:** the `--strict` flag also promotes warnings to errors. Leave it off during early drafting, and add it once the changelog is stable.

## Reviewing the validation report

Every validation report lists each resource by canonical url, followed by the errors and warnings raised against it. A resource with only warnings still publishes; a resource with even one error blocks the whole guide from being released. Read the report from top to bottom — later resources sometimes fail only because an earlier resource in the same bundle failed first, and fixing the root resource clears the rest.

Reviewers should treat the validation report as the source of truth over local testing. A resource that passes on a developer machine can still fail the shared validator if the two disagree on which version of the base specification to check against. When that happens, trust the report the publisher produced, not the one your local editor shows you.

## Releasing a new version

A release bundles every resource that changed since the last published guide, together with the changelog entry that describes what changed and why. The release process re-runs the same validator that rejected resources during drafting, so a guide that publishes locally without `--strict` can still fail release if a warning was quietly left unresolved.

Tag the release only after the changelog entry has been reviewed:

```bash
git tag -a ig-v1.4.0 -m "See CHANGELOG.md" && git push --tags
```

An unreviewed changelog entry is the single most common reason a release gets rolled back after publishing — reviewers catch resource changes the author considered too minor to mention, and those are exactly the changes downstream implementers need to see.

> **Note:** a rolled-back release still leaves its resources in the validation report history. Do not delete them; mark the release as withdrawn instead.

Withdrawn releases stay visible in the guide's history precisely so a reviewer can tell a resource was intentionally pulled from a later release, not silently dropped from an earlier one. Treat that history as part of the changelog, not a separate report to reconcile by hand — the validation report and the changelog should always agree on which resources shipped in which release.
