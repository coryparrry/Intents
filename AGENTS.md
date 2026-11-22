# Intents repository working agreements

## Before drafting, editing, or building

Read [the workflow](docs/sdlc/workflow.md), [contribution rules](docs/contributing.md), applicable scoped instructions, and the current change record. Ordinary requests use these files directly.

Check Git status and protect unrelated work, saved evaluations, credentials, and local configuration. Trace the affected entry point through owning code, tests, and CI. Read relevant Git and PR decisions. For existing behavior or resumed work, find and open relevant prior project chat turns when access is authorized, including owner corrections. Reconcile decisions with the current checkout and actual evidence. Before writing or building, summarize findings, sources, and material gaps. Scale discovery to the task. Read-only work needs no new artifacts.

## Source and commands

- The macOS app and native tests live in `FoundationEvals/`. `Sources/`, `Packages/ProductionEvals/`, and `Package.swift` define Swift libraries and CLIs. The standalone plugin lives in `plugins/apple-foundation-evals/` and the publishable website in `website/dist/`.
- For shared app/plugin code, edit the canonical paths in `script/shared_app_sources.json`, refresh current provenance hashes, and verify both consumers. Keep source membership, test discovery, and CI dependency maps aligned.
- From the root, the development entry point is `./script/build_and_run.sh`. See [README build and test instructions](README.md#build-from-source), [CI coverage](docs/ci.md), and [manual qualification](docs/ci-manual-tests.md). Before every push, follow the [complete diff validation gate](docs/contributing.md#validation-before-pushing). Workflow definitions and scripts govern what runs.

## Plan, prove, and maintain

Resume the authoritative record or start `intent/<change-id>/` for new work. The maintainer delegates in-scope intent, spec, and plan acceptance to a separate independent agent. Have a separate independent agent challenge and accept the exact plan before implementation. Record each acceptance and its evidence before advancing. Renew review for material deviations and bring scope changes or reserved decisions to the appropriate owner.

For bugs, demonstrate and checkpoint the failing regression before fixing the code. Preserve the checkpointed test, verify the fix with the same test, and use integration tests where needed. Document changed functions. Inspect running UI changes. Record actual verification and distinguish local, current-head CI, live, and release evidence.

Update affected docs and change records with the work. On the second confirmed occurrence of a mistake, propose the smallest durable correction. On pause, record progress, remaining checks, and the next step in the active record. Use isolated fixtures and keep private data out of shared evidence.

## Review and handoff

Read [REVIEW.md](REVIEW.md). Obtain independent subagent review for substantial code changes. Follow [PR metadata](docs/contributing.md#pull-request-metadata), review-thread resolution, current-head CI, human merge approval, and [release authorization](docs/releasing.md). Report the stage, changes, evidence, documentation updates, blockers, and next required decision.
