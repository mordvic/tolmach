## Publishing an implementation guide

The profile server validates every `StructureDefinition` before it is published. Validation runs against the FHIR R4 base specification, and any resource that fails is rejected with a machine-readable report.

Run the publisher locally before opening a pull request:

```bash
profile-server publish --ig ./ig.json --strict --out ./dist
```

If validation fails, the exit code is `2` and the report is written to `./dist/validation-report.json`. See https://build.fhir.org/validation.html for the full list of severity levels.

> **Note:** the `--strict` flag also promotes warnings to errors. Leave it off during early drafting, and add it once the changelog is stable.
