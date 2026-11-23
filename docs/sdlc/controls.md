# Workflow control register

The maintainer identified in [CODEOWNERS](../../.github/CODEOWNERS) owns these controls. Assess current platform settings and exact-revision results when relying on a GitHub gate.

| Objective | Enforcement point | Required evidence | Status |
| --- | --- | --- | --- |
| Run the required checks for the complete diff | [CI workflow](../../.github/workflows/ci.yml), [router](../../script/ci_routes.py), and [terminal CI gate](../../script/ci_gate.py) | Exact-head route selection, test results, and required check completion | Existing CI |
| Validate PR release metadata | [PR metadata workflow](../../.github/workflows/pr-metadata.yml) and [validator](../../script/release_notes.py) | The current PR body passes validation | Existing CI |
| Preserve shared engine ownership and provenance | [Source map](../../script/shared_app_sources.json), [shared-source tests](../../script/tests/test_shared_app_sources.py), and consumer CI | Current hashes and both affected consumers verified | Existing CI when selected |
| Review and approve a change | [Review policy](../../REVIEW.md), PR decisions and threads, and [contribution rules](../contributing.md#pull-request-completion-and-merge-requirements) | Maintainer approval, resolved threads, and passing applicable checks at the current head | Manual approval backed by configured GitHub gates |
| Accept the intent, spec, and plan | [Delegated review](workflow.md#who-can-accept-intent-spec-and-plan) within the maintainer's authorized scope | Independent reviewer, decision, review time, durable evidence reference, and the exact revision | Recorded review procedure |
| Preserve the regression checkpoint | [Development workflow](workflow.md#4-test-the-result) and review of the fix diff | Pre-fix checkpoint revision, the failing result recorded before the fix, and the same test passing with the fix | Review procedure |
| Verify an immutable release source and installer | [Installer workflow](../../.github/workflows/package-installer.yml), [source verifier](../../script/verify_release_source.sh), and [release procedure](../releasing.md) | Release authorization, exact-source CI, signing, notarization, and download and upgrade evidence | Existing packaging gates and manual qualification |
| Enforce local edit boundaries, agent evals, or automated response tiers | Scope, authority, and tests to be recorded when adopted | Independent negative tests, approved bounds, and recovery evidence | Pending adoption |

Repository instructions establish obligations. Required CI, platform controls, and documented human approvals each apply at their own boundary. Before adopting an automatic action, record its owner, allowed actions, version, success and failure tests, and the recovery procedure.
