# Intent and change artifacts

Default home: `intent/<change-id>/`. Create a stable unique ID per change, then create `intent.md`, `spec.md`, and `plan.md` as their stages are reached. Do not reuse a single root plan for unrelated changes. Optional `verification.md` and `review.md` index evidence when CI/PR does not already provide a sufficient record.

Use `docs/sdlc/templates/`. Follow `docs/sdlc/workflow.md` for acceptance, authoritative systems, version linkage and update rules. Authoritative approvals refer to real human decisions and reviewed revisions. A draft file or commit is not acceptance. Preserve finished records and their links; do not delete the audit history during cleanup.

The guide recommends an `intent/` home for a single product. The per-change subdirectory convention is this kit's addition to avoid collisions. Reuse an established equivalent home rather than maintaining two competing records.
