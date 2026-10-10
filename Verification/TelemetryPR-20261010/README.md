# Telemetry PR qualification

The PR is isolated from current main and preserves unrelated dirty work. No app release was published or distributed.

- **Source:** signed candidate built from `81b6b414673bae9f3aa4efd2a2d32bb04db09f47`; production telemetry source hashes in `source-hashes.json`. Final follow-up changes only the upload helper's codesign verbosity, its test fixture and evidence/docs, not app code.
- **Source and interaction tests:** 52 focused tests in 8 suites passed, including real automation execution/cleanup, MCP and storage boundaries, SDK payload/crash replay filtering and consent epochs. Six archive upload helper tests passed. Native Privacy UI inspected at both scroll positions, showing disabled sharing/retry and readable local-policy copy; temporary app closed.
- **Local Mac:** host-specific exclusion provisioned, legacy sharing preferences disabled and pending Intents crash directory purged. A Release-mode Swift process verified the local policy blocks production capture. Debug/test/preview/demo exclusions remain independent.
- **Artifact:** Developer ID signed ARM64 candidate, version `1.0`, build `2026101001`; app and dSYM share UUID `369C06FB-C5A2-3A45-8D1F-E990F7424825`. Packaged privacy manifest lint and strict deep signature verification passed. Candidate remains a verification artifact, not a distributed release.
- **PostHog symbols:** EU project `266962`, symbol set `01a1261e-aabe-0000-b989-361aef550662`, uploaded file present and no failure reason. Downloaded DWARF bytes exactly match the archive; `atos` resolves `TelemetryController.appBecameActive()` with source line 166. See `symbol-proof.json`. Source files were not uploaded.
- **Live qualification:** the saved native fatal crash query returns no data. Hosted native crash delivery and readable UI stacks must still be verified from a consented crash on an eligible machine after relaunch. No production crash was deliberately generated and no tracked activity was created on this excluded Mac. A later distributed archive needs its own matching symbols.

The earlier network-free native crash/relaunch/opt-out fixture is historical supporting evidence, not proof of a shipped app or live ingestion. Store privacy disclosures must be reconciled before any release.

[PostHog native symbol upload documentation](https://posthog.com/docs/error-tracking/upload-source-maps/ios) · [Native fatal crash analysis](https://eu.posthog.com/project/266962/insights/pv2qBZ2F)
