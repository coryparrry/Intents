# Intents workflow setup

The repository uses one [AGENTS.md](../../AGENTS.md) as its entry point. It links the [development workflow](workflow.md), [contribution procedures](../contributing.md), and [review policy](../../REVIEW.md). The maintainer in [CODEOWNERS](../../.github/CODEOWNERS) owns the shared guidance and delegates in-scope intent, spec, and plan sign-off to [recorded review](workflow.md#who-can-accept-intent-spec-and-plan).

## Delivery paths

| Surface | Sources and examples | Where to verify |
| --- | --- | --- |
| macOS app | [App entry](../../FoundationEvals/FoundationEvals/FoundationEvalsApp.swift) opens the workspace. [PR #202](https://github.com/coryparrry/Intents/pull/202) shows how saved-draft and release-report regressions were traced through UI, stores, and regression tests. | [CI](../ci.md) selects the native and UI suites. Live and installer checks follow [manual qualification](../ci-manual-tests.md) and the [release guide](../releasing.md). |
| Swift libraries and CLIs | [Package.swift](../../Package.swift) declares the SDK and executables. The [production CLI](../../Sources/ProductionEvalsCLI/main.swift) calls the production package. [PR #201](https://github.com/coryparrry/Intents/pull/201) shows how shared Siri evidence code is covered by portable tests. | Use the routed Swift tests and [production qualification runner](../../script/ci_production_evals.sh). |
| Standalone plugin | The [MCP manifest](../../plugins/apple-foundation-evals/.mcp.json) starts the plugin server. The [shared-source map](../../script/shared_app_sources.json) identifies sources consumed by both the app and plugin. | The [plugin workflow](../../.github/workflows/plugin.yml) checks UI and native paths and produces the ZIP. |
| Website | [website/dist](../../website/dist/) contains the published assets. [PR #193](https://github.com/coryparrry/Intents/pull/193) records a comparison with a deployed Sites revision. | Follow the [website guide](../../website/README.md) and keep local checks and deployed-site evidence tied to their respective revisions. |
| Release | [Release Me](../../.github/workflows/release-me.yml) and [installer packaging](../../.github/workflows/package-installer.yml) implement the [release guide](../releasing.md). | Record exact source CI, signing, download, and upgrade evidence for the relevant release. |

## Records and rollout

Use [`intent/<change-id>/`](../../intent/README.md) for new change records and link any existing authoritative issue or plan. Keep approval and review decisions in their recorded system, with the exact revision and evidence. Keep sensitive working records in their approved private location and link an appropriate shareable reference where needed.

The rollout uses manual stage transitions. See the [control register](controls.md) for enforcement boundaries and the [workflow measures](metrics.md) for proposed tracking. The [release guide](../releasing.md#retry-a-failed-release) covers draft retry. A rehearsed rollback route, real-task agent-eval baseline, and automated incident response remain pending adoption.

## Independent plan review refresh

On 22 November 2026 the owner required a separate independent agent for plan acceptance and delegated development sign-off. The independent policy reviewer challenged the rollout scope and accepted the revised plan `SHA-256 0cb43e8eb07a63c0fd6faa6073d2dc0f9831e285ec63c00bd7c4129e10d48eaa` before target edits. This record describes the manual workflow. Required platform and named human approvals still apply.
