# Intents development workflow

This is the manual rollout of Louis Claxton's *The AI-Native SDLC Playbook*. [AGENTS.md](../../AGENTS.md) starts the workflow from ordinary requests. [Contribution rules](../contributing.md) govern implementation, validation before pushing, PR metadata, and merges. [Setup evidence](setup.md) explains how this workflow fits the repo. [Controls](controls.md) records where enforcement exists.

## Start from the current change

Before drafting anything, inspect the checkout and scope. Follow the affected caller or user journey through the implementation, its storage and shared contracts, the relevant tests and their runner, and any generated or distributed copies. For a doc correction, trace the claim to its owning source and check affected references.

Read linked decisions and focused Git, PR, or issue history. For existing behavior or resumed work, look up relevant prior project chats by feature, PR, artifact, or branch and open the owner decisions and corrections. If access is unavailable, record the gap and use the repo and PR evidence. Current code establishes behavior, accepted decisions define intent, and results tied to the tested revision establish proof. Summarize these findings and any conflicts before drafting, editing, or building. Put durable findings and shareable references in the active artifact. Keep private transcripts and private data out of the repository.

Use [`intent/<change-id>/`](../../intent/README.md) for new work, with a stable issue ID or date and slug. Create files as each stage begins using [the templates](templates/). When work already has an authoritative ticket, design, or plan, resume it and link its revision and the associated PR. If a copy is needed, identify the authority and synchronize both links through the authorized tools. Flag unsynchronized records. Read-only requests require no artifact chain.

## 1. Plan the change

Capture the originator's problem, affected people, expected outcome, scope, constraints, and questions in [`intent.md`](templates/intent.md). Include the author, time, and evidence. The product owner accepts, revises, or rejects the intent. For every stage gate, record who decided, when, the reviewed revision, and the authoritative comment, review, or other decision reference. A file status and a checkpoint commit document progress. Advance on the human decision for that revision.

## 2. Design the behavior

Use the accepted intent to draft [`spec.md`](templates/spec.md) with testable acceptance criteria, design and interface decisions, relevant policy sources and versions, the generating prompt or a safe equivalent, and open concerns. Use repo-owned privacy, interface, UI, and release guidance where it applies. Route policy conflicts to the corresponding owners. The product owner reviews the outcome and resolves concerns with the technical or policy owner before the spec is approved.

## 3. Plan and build

Refresh discovery against the approved spec and current source. Write [`plan.md`](templates/plan.md) with the actual entry points and evidence, exact files, ordered steps, risky cases and recovery implications, and a proof method for every criterion. Use read-only exploration for planning. An accountable engineer accepts the plan before implementation. The maintainer can fill several roles. Record deviations in the plan with the change, and get renewed acceptance for material scope, design, or risk changes.

Keep changes focused and use repo conventions. Isolate independent write scopes when parallel work is authorized, and serialize overlapping edits. Use the established local checkpoint process. Before pausing, put progress, unfinished checks, blockers, and the next step in the active record.

## 4. Test the result

Work against agreed, observable outcomes and run focused checks during implementation. For a bug fix, reproduce it with a regression test and verify the test fails for the intended reason. Preserve the test in a checkpoint before changing implementation. Keep it fixed while repairing the code. A genuinely incorrect test requires separate review with recorded rationale. Apply the existing CI rules for discovered tests and failing checks.

Use isolated fixtures and storage. Run the affected flows and inspect screenshots for UI changes. Check neighboring flows that rely on the same contract. For substantial code changes, get an independent subagent review of the stable scope. For a push, follow [the full pre-push procedure](../contributing.md#validation-before-pushing) and run the always-on and selected checks. A selected suite must execute eligible tests. For native and product runtime prerequisites, see [CI](../ci.md) and [manual qualification](../ci-manual-tests.md).

Record the tested revision, command, result, and relevant artifacts in the PR or [`verification.md`](templates/verification.md). Link real output and safe screenshots, and record every failure or blocked check. GitHub checks belong to their exact head. Fixture coverage, live-provider/device behavior, signed installer verification, and installed upgrade behavior each need corresponding proof.

## 5. Review and release

Explicitly read [REVIEW.md](../../REVIEW.md) for bug, security, and spec/plan passes. Put review findings and decisions in the PR, or use [`review.md`](templates/review.md) to prepare a review before there is a PR. Follow the existing metadata validator and release-note rules. Confirm the maintainer's approval, resolved review threads, and applicable green checks on the current head before an authorized merge. Repository guidance and platform gates are tracked separately in [controls](controls.md).

Release authorization follows [the release procedure](../releasing.md). A release PR merge can start packaging and publication. Verify exact source CI, signing, notarization, artifact verification, update feed and Homebrew as applicable, and the installed upgrade. For the standalone plugin, qualify the distribution ZIP separately. For the website, compare the actual Sites deployment with the intended source. Keep CI permissions scoped to each job and use the existing controlled release route.

Before adding automated deploy or rollback, require a maintainer-approved route, least-privilege scoped identity, explicit environment boundaries, and a rehearsal with evidence. Follow the existing [draft retry procedure](../releasing.md#retry-a-failed-release) for failed unpublished installers. Current rollback readiness is recorded in [setup](setup.md).

## 6. Maintain and learn

Report an incident with actual impact, timestamps, evidence, and action authorization. The maintainer triages it for immediate fix, scheduled work, or dismissal. A follow-up that changes behavior enters the same intent-to-release chain. Confirm recovery with the relevant metric or user journey. Record the [versioned lesson](../../lessons/README.md), link the follow-up and product regression, and track its permanent [agent-configuration eval](../../evals/README.md).

When the maintainer adopts automated detection, use a versioned, unit-tested rule with a measured baseline. Record the metric, detector version, and response tier. Keep diagnostic runs read-only and bounded by budget, time, and retries. Any tier that proposes a patch or invokes an operational action needs a separately approved scope, escalation rule, and tested authorization boundary. Alert severity alone grants no permission to act.

## Update documentation as part of the change

| When this changes | Update in the same change |
| --- | --- |
| Scope, requirements, or implementation decisions | The active intent, spec, plan, and proof or approval references |
| User flow, prerequisites, or distributed interface | The affected [README](../../README.md), [wiki](../wiki/Home.md), [integration guide](../DEVELOPER_SWIFT_INTEGRATION.md), [production guide](../PRODUCTION_EVALS_GUIDE.md), [MCP guide](../MCP_CONTROL_GUIDE.md), [plugin guide](../../plugins/apple-foundation-evals/README.md), or [website guide](../../website/README.md) |
| Tests, commands, or release operation | The applicable [CI guide](../ci.md), [coverage guide](../DOCSTRING_COVERAGE.md), [release guide](../releasing.md), or contribution rules |
| A second confirmed mistake or a production incident | The owning guidance or policy, with evidence and maintainer review. For incidents, also link the lesson, follow-up, recovery proof, and permanent eval. |

At handoff, report the change ID and stage, what changed, the exact evidence available, which docs were updated, any unresolved findings or checks, and the next human decision. Keep task history in the active record.
