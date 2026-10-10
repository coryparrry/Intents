# Intents telemetry repair

> Historical source/fixture qualification from the earlier dirty checkout. Current PR archive, uploaded-symbol verification and local-Mac exclusion are recorded in [Telemetry PR qualification](../TelemetryPR-20261010/README.md).


Intents supports native macOS. Its iPhone/simulator automation targets do not represent iPhone installations of Intents. The connected EU project **266962** matches the bundled ingestion token; credentials are omitted from this evidence.

## Measurement contract

| Question | Signal | Actual Mac call site | Saved analysis | Evidence |
|---|---|---|---|---|
| Which installations use the app? | `foundation_evals_app_opened`, stable anonymous SDK ID | Recorder called from key workspace/settings windows; rechecks capture-driven session rotation | Daily active installations by build | SDK transport, session rotation and identity tests |
| Does observed first use reach a core workflow? | `intents_first_use` → successful `intents_feature_used` | First enabled use persisted by recorder; evaluation/scenario/automation completions | Ordered seven-day activation funnel | Consent and completion tests; not downloads or per-attempt conversion |
| Which features are completed? | Fixed `feature` category | Existing evaluation/scenario/suite/MCP service spans; newly wired automation executor result | Distinct installations per feature | Actual MCP success/failure and automation cleanup integration tests |
| Do installations return to core value? | First use → recurring successful evaluation/scenario/automation | Same successful service outcomes | Six-week calendar retention | Saved native retention query; recent cells may be incomplete |
| Where do sessions navigate? | Manual `$screen` and safe `$session_id` | `ContentView` selection/key state and `AppSettingsView` page/key state | Session paths, fixed names, five steps | Mapping/dedup/session tests; owning-window review |
| Which operations fail or cancel? | Started/finished/issue; fixed outcome/category | EvaluationStore, ScenarioCoordinator, MCPSettingsController, AppAutomationStore | Outcomes, failed operations, issue categories | Existing diagnostics and failure/cancellation regressions |
| Which operations are slow? | Monotonic `duration_ms` on completion | Actual service/executor boundaries; not time on screen | Successful-operation p95 by operation | Exactly-once, consent generation, invalid duration tests |

No account, purchase/restore or recording workflow is introduced by this repair. Raw AI traces, prompts/responses, names, URLs, evidence, recordings, hardware identifiers and raw errors are excluded. The original repair excluded native crash stacks. The subsequent [automatic crash extension](../CrashReporting-20261010/README.md) adds opt-in privacy-filtered native stacks; delayed CPU/memory/hang reports remain excluded.

## Source and privacy

- Usage remains on by default; diagnostics remain separately off by default. Existing opt-outs are respected.
- Fixed usage events work without diagnostic sharing. No diagnostic properties are attached to feature adoption.
- Debug, simulator, tests, previews, demo and verification/fixture launches cannot use the bundled production recorder.
- Both final filters retain safe SDK session/library metadata and app/environment/platform/version/build/schema dimensions. Unknown events and private properties are rejected.
- Consent changes cancel the transport and revoke queued events with persisted epochs. Queue cleanup preserves anonymous SDK identity. In-flight measurements do not cross consent generations.
- The local native manifest and consent documentation describe installation-linked analytics. Website privacy, store disclosures, releases and public policy publication were not changed.

## PostHog evidence

[Intents — usage & diagnostics](https://eu.posthog.com/project/266962/dashboard/998410) reuses the existing dashboard and its five native insights, adding completed-feature adoption, activation, retention and session navigation. Every relevant query explicitly filters `app=intents`, `environment=production`, `platform=macOS`, `schema_version=2`.

All **nine saved native queries executed without warnings** on 10 October 2026. Eight return no eligible data; retention returns empty cohort cells. They are correctly labeled as awaiting an updated release. Definitions of the two new app-specific event names are unverified pending ingestion. No governed telemetry metric matched the catalog; these analyses are labeled noncanonical.

Earlier app-open events are live, but contain only app version and OS major version, without environment/build labels. They cannot prove release-only usage. They were retained and excluded from the new analyses. No fake production events, forced crashes or history deletion were performed.

Dashboard rendering could not be visually inspected: the available in-app browser requires PostHog login. The temporary tab was closed. Saved query execution and grid-layout validation are separate from this missing UI evidence.

## Tests, interface and delivery

The final run passed **44 tests across six suites**, including real SDK serialization/transport, persisted identity across queue cleanup, session rotation, privacy/consent gates and the actual automation-controller success/cleanup-failure integration. Result bundle: `/tmp/intents-ui-polish-20261009/DerivedData/Logs/Test/Test-FoundationEvals-2026.10.10_12-26-40-+0100.xcresult`.

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/intents-ui-polish-20261009/DerivedData \
  -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO \
  -only-testing:FoundationEvalsTests/TelemetryControllerTests \
  -only-testing:FoundationEvalsTests/TelemetryTransportTests \
  -only-testing:FoundationEvalsTests/TelemetryDiagnosticsTests \
  -only-testing:FoundationEvalsTests/TelemetryUsageTests \
  -only-testing:FoundationEvalsTests/TelemetryPayloadFilterTests \
  -only-testing:FoundationEvalsTests/AutomationMCPTests test
```

Independent Sol 6.1 review found and rechecked two fixes: capture-driven SDK session rotation and screen attribution to the key window. It then reviewed the saved automation integration test without finding a material issue.

The Debug app was opened from a temporary copy with isolated workspace storage. The actual Privacy interface was inspected at the top and bottom: text wraps, scrolling exposes the complete disclosure, sharing switches are disabled, uploads are not queued, and local reports remain available. Workspace navigation, hiding and returning to Settings also worked. The app was then closed. This interface check does **not** verify production screen-event delivery or background-session ingestion because Debug capture is deliberately blocked.

`git diff --check` and `plutil -lint FoundationEvals/FoundationEvals/PrivacyInfo.xcprivacy` passed. The manifest is present in the Debug app's `Contents/Resources/PrivacyInfo.xcprivacy`. The local **arm64 Release build passed** with signing disabled. Its packaged privacy manifest passes lint and matches the source byte-for-byte.

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/intents-ui-polish-20261009/DerivedData \
  -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 \
  CODE_SIGNING_ALLOWED=NO build
```

Build log: `/tmp/intents-telemetry-release-20261010.log`. Test log: `/tmp/intents-telemetry-tests-final-20261010.log`. Existing macOS 27 MultipeerConnectivity deprecation warnings remain outside this telemetry change.

Signed release delivery and live schema-2 ingestion are not qualified by a local test or a dashboard query. No release was published or installed over the user's app. The next authorized release must confirm actual session/screens, identity, values and consent in PostHog.

## Research reviewed on 10 October 2026

Current official PostHog pages were fetched outside the repository; only applicable sections were reviewed. The pinned **3.71.4** SDK source was inspected for session lookup/rotation, lifecycle notifications, opt-out/close, storage names, batch serialization and before-send callbacks. This is not a whole-site review.

| Official source | Reviewed area / decision |
|---|---|
| [Swift configuration](https://posthog.com/docs/libraries/ios/configuration) | Swizzling/activity tradeoff, batching, property filtering, collector defaults |
| [Swift usage](https://posthog.com/docs/libraries/ios/usage) | Anonymous events/person profiles and fixed manual screen names |
| [Privacy](https://posthog.com/docs/product-analytics/privacy) | IP processing and privacy controls |
| [Identity](https://posthog.com/docs/product-analytics/identity-resolution) | Stable anonymous IDs; no account or cross-device linking |
| [Capture events](https://posthog.com/docs/product-analytics/capture-events) | Fixed event/property contract |
| [Native errors](https://posthog.com/docs/error-tracking/installation/ios) | Separate crash collection; not enabled by this repair |
| [Funnels](https://posthog.com/docs/product-analytics/funnels) | Sequential conversion, seven-day window and incomplete cohorts |
| [Retention](https://posthog.com/docs/product-analytics/retention) | Initial cohorts, returning action and calendar periods |
| [Apple manifest details](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest) | Data categories, linking, tracking and analytics purposes |
| [Apple API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons) | UserDefaults CA92.1; elapsed time between app events 35F9.1 |

The connector's current query/metadata schemas and product-analytics reference template were consulted. No person-profile, replay, survey, AI-content or crash collection was added.
