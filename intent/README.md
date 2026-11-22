# Intent and change artifacts

Default home: `intent/<change-id>/`. Create a stable unique ID per change, then create `intent.md`, `spec.md`, and `plan.md` as their stages are reached. Do not reuse a single root plan for unrelated changes. Optional `verification.md` and `review.md` index evidence when CI/PR does not already provide a sufficient record.

Use `docs/sdlc/templates/`. Follow the [delegated review rules](../docs/sdlc/workflow.md#who-can-accept-intent-spec-and-plan) for intent, spec, and plan acceptance. Record the actual decision and evidence for each reviewed revision. Preserve finished records and their links during cleanup.

Use one subdirectory per new change. When work is already recorded in an issue, PR, or design document, link and continue that authoritative record under the rules in [the workflow](../docs/sdlc/workflow.md#start-from-the-current-change).
