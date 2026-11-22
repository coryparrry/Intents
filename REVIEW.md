# Intents review instructions

[CODEOWNERS](.github/CODEOWNERS) identifies the maintainer. This policy applies to reviews of changes in the app, libraries, CLIs, standalone plugin, website, and repository tooling.

## Inputs and passes

Read [AGENTS.md](AGENTS.md), the exact diff and base, the linked intent/spec/plan and accepted revisions, verification evidence, and relevant policies. Report missing acceptance criteria or approvals as gaps. Review the stable diff independently of its implementation when substantial code changes require a subagent.

1. **Bugs.** Trace the affected entry point, failures, and neighboring behavior. Check persistence, cancellation, backward compatibility, regression coverage, and test discovery where relevant.
2. **Security and privacy.** Check authorization, data exposure, input handling, and boundaries around saved data, providers, credentials, and release permissions. Follow [telemetry policy](docs/telemetry.md) for diagnostics and the actual workflow for release controls.
3. **Spec and plan.** Trace the diff and proof to acceptance criteria. Check scope, plan deviations, approval records, artifact and documentation updates, and claims about local, CI, live, and release verification.

Report a result for each pass, including passes with no findings and any unverified scope. For each finding give its pass, severity, file and line, evidence, consequence, and requested action. Mark unconfirmed hypotheses as questions. An **Important** finding can break intended behavior, expose data, violate applicable policy, or leave an acceptance criterion without adequate proof. A **Nit** is a minor optional improvement. Report at most five nits.

Skip a duplicated mechanical check only when current-head evidence shows that it ran and passed. Trace defects in generated output back to the editable source or generator. Include generated artifacts and provenance where they affect what users receive.

## Plan acceptance evidence

Check that a separate independent agent accepted the exact plan revision before implementation and reviewed any material revisions. Record any missing decision as an Important finding. Apply separately required merge and release approvals through their assigned routes.

## Approval and follow-through

For intent, spec, and plan, check the [delegated acceptance record](docs/sdlc/workflow.md#who-can-accept-intent-spec-and-plan). The PR and its review threads hold the authoritative PR review record. Human merge approval remains a project requirement. Check which controls GitHub actually applies in the [control register](docs/sdlc/controls.md).

Follow the [repository's fix and merge requirements](docs/contributing.md#pull-request-completion-and-merge-requirements). Address and verify material findings, retest affected behavior, reply and resolve threads within authorized PR work, and verify current-head checks and thread state. The authoring agent cannot supply human approval.

On the second confirmed occurrence of a mistake, propose the smallest evidence-backed update to the owning instruction or policy. The maintainer can use the [workflow measures](docs/sdlc/metrics.md) to review findings and tune exclusions.
