# Usage statistics and diagnostics

Intents has two independent switches in **Settings → Privacy**:

- **Share usage statistics** is on by default. It sends app sessions, first observed analytics-enabled use, fixed screen names, completed features, app/build/platform and macOS versions, and random installation/session identifiers. Existing opt-outs are preserved.
- **Share diagnostic statistics** is off by default. It adds content-free operation events and automatic native crash reports so failures, slow operations and crashes can be investigated. Existing usage consent does not enable it.

No name, email, Apple account, prompts, responses, scores, suite/scenario names,
file paths, hardware identifiers, user-assigned device names, provider addresses, credentials, raw error messages,
or evaluation evidence enter these events. Random installation, session and operation
identifiers permit correlation; this is pseudonymous telemetry, not proof that every
installation is unlinkable. Session replay, person profiles, automatic interaction
tracking and network tracing remain disabled. Native crash capture is enabled only in eligible production builds with diagnostic sharing on; exception breadcrumbs remain disabled. IP geolocation
is disabled; PostHog still handles the source network address.

## What diagnostics collect

| Signal | Purpose | Fields |
|---|---|---|
| Operation started/finished | Find failed or unfinished workflows and slow operations | Fixed operation name, generated operation ID, outcome, elapsed milliseconds |
| Native fatal crash, sent on the next launch | Investigate crashes and symbolicate native stacks | Fixed error type and placeholder message, bounded code addresses, referenced Mach-O UUIDs/sizes/architecture, crashed build and session |
| Diagnostic issue | Identify failures outside a completed operation or a subsidiary failure | Fixed operation and error category; parent operation ID when available |
| Release/environment | Compare affected builds and platforms | App version/build, full macOS version, processor architecture, schema version, generated diagnostic session ID |
| Upload result, on this Mac | Distinguish missing instrumentation from delivery problems | Last upload queued, accepted, failed or sharing off |

Instrumented boundaries include workspace loading and suite saving, evaluation
execution, result persistence/checkpoints, Core AI loading, Private Cloud Compute
metadata, Intent Lab scenario storage/execution/semantic assessment, and Codex
connector startup/installation/removal. Timings use a monotonic clock and are bounded
to 24 hours. Categories include timeout, network, permission, storage, unavailable
model/device, build, invalid evidence, provider, generation and judge errors.
Unknown categories become `unexpected`; their original text is never uploaded.
Cancellation is a separate outcome. A failed model assertion is evidence about the
subject being evaluated and does not automatically become an app runtime error.

The three diagnostic event names are:

- `foundation_evals_operation_started`
- `foundation_evals_operation_finished`
- `foundation_evals_diagnostic_issue`

Usage events are `foundation_evals_app_opened`, `intents_first_use`,
`intents_feature_used`, and manual `$screen` events. Screen and feature values come
from fixed enums. The first-use event means the first observed use with analytics
on; it is not an installation or download count. Successful feature events carry
only a fixed feature category, not results or diagnostic error details. Legacy
evaluation telemetry names and automatic SDK events are rejected.

Every shared event has `app=intents`, `environment=production`, `platform=macOS`,
`schema_version=2`, app version/build, OS version and processor architecture. Safe
SDK session IDs and library/version fields are retained; content-bearing SDK
properties are removed. Intents is a Mac app. Testing an iPhone through its
automation tools is a Mac workflow, not an iPhone installation of Intents.

Debug builds, simulators, tests, previews, demos and verification/fixture launches
cannot initialize the bundled production recorder. No verification argument can
reopen that capture gate. Network-free tests inject a fake destination instead.

## Diagnosing an issue

1. Open **Settings → Privacy**. Recent errors and the last upload result are visible.
2. Use **Copy diagnostic report** to copy the latest 100 safe events from this
   process. The local report works even when both sharing switches are off or the
   build has no PostHog configuration. It contains timestamps, operation IDs,
   outcomes, categories and release information. The in-memory history ends when
   the app closes; it is not a durable crash report.
3. Open the [Intents diagnostics dashboard](https://eu.posthog.com/project/266962/dashboard/998410). Its charts cover active installations, completed features, activation, weekly return usage, screen paths, operation outcomes, issues and successful-operation p95 duration. All require production Mac schema 2. They are expected to be empty until an updated release supplies eligible data; diagnostic charts also require diagnostic sharing. Historical unlabeled opens are retained but excluded from these charts. For shared diagnostics, enable **Share diagnostic statistics**, reproduce the
   problem, then filter PostHog events by the diagnostic prefix, app build, operation
   or error category. A start with no finish is a clue requiring investigation,
   not proof of a crash; offline delivery, cancellation, and shutdown can also cause it.
4. On the Mac, filter Console by subsystem `com.coryparry.FoundationEvals` and
   category `Diagnostics` or `TelemetryDelivery`. The same fixed categories appear
   through Apple's unified logging system.

An accepted upload means the server returned a successful HTTP response. It does
not guarantee the event is already queryable. Delivery is asynchronous and best effort.
Diagnostic sharing covers handled workflow failures and fatal Mach/signal/NSException crashes. Hangs, memory pressure and system-wide performance reports are not collected. Native crash reports upload on the next eligible launch; abrupt termination before capture or a launch with sharing off can leave no report. Apple crash reports/Xcode Organizer remain useful for those investigations.

## Consent and delivery

Either sharing switch can be turned off at any time. A change cancels active uploads,
revokes unsent events and pending native crashes, attempts to remove only this project’s SDK queues, and retains the persisted anonymous installation
identifier. A sharing toggle does not create a new installation. A persistent consent
epoch rotates before saving the changed preference. Events from an earlier epoch
cannot be uploaded later, even if deleting the queue fails and sharing is re-enabled.
This internal marker is removed before network transmission. Related operation
completion/issues also respect the consent generation at their start. Enabling
sharing midway through an operation does not upload that earlier operation's details.
Turning one switch off leaves the other switch's chosen setting intact.
Changing diagnostics sharing alone rebuilds the SDK and revokes old queues, but
does not count another app open or repeat the current screen while the observed
usage session remains active. SDK session tokens can change during this reset;
normal SDK session rotation and usage opt-out/re-enable still count new opens.
Already-received PostHog data is not deleted by an app preference change.

The pinned Swift SDK maintains a bounded queue of 50 events across launches while
consent remains unchanged. Events trigger an immediate asynchronous flush, with a
10-second periodic flush. Queue retention improves short-session/offline delivery;
it is not a delivery guarantee. The final transport gate rechecks every batch against
current consent and a property/value allowlist, including batches loaded from disk
that bypass the SDK's `beforeSend` callback. Gzip decoding and JSON batches are bounded
to 256 KiB; malformed batches fail closed. Fully revoked batches are acknowledged
locally and discarded without an upload, so they cannot block newer authorized events. Only HTTPS POSTs to the configured host,
port and `/batch` path are allowed. The SDK’s empty trailing query is accepted;
query parameters, redirects and remote configuration are blocked.

## Configuration and validation

Intents uses EU PostHog **Default project (266962)**. The public ingestion token and
host are in `FoundationEvals/Configuration/AppInfo.plist`; this token cannot read
analytics. Development, verification and hosted native tests do not initialize the app’s production telemetry client.
The SDK transport integration tests use a fake HTTPS destination and intercept it
locally; they do not upload fixture prompts, responses or credentials. The real SDK
fixture disables the pinned SDK’s internal reachability gate only in the test factory:
an intercepted HTTPS request must not depend on the Mac’s network state.

Run the native `TelemetryControllerTests`, `TelemetryTransportTests`,
`TelemetryDiagnosticsTests`, `TelemetryUsageTests`, `TelemetryPayloadFilterTests`,
`TelemetryCrashTests`, `TelemetryCrashSDKTests`,
`AutomationMCPTests`, `EvaluationStoreRunLifecycleTests`, and
`MCPTransportRegressionTests` suites. Coverage includes independent consent,
revocation/re-enable, stale delivery callbacks, mid-operation consent, bounded reports,
secret exclusion, real SDK serialization/transport, HTTP rejection, retained-batch
filtering, corrupted storage, scenario preflight, local HTTP evaluation success/failure,
connector failures, real-SDK identity persistence, SDK session rotation, production gates, and actual automation execution/cleanup outcomes. Check Privacy in the built app and close the app afterwards.

## Research and design decisions

[Apple unified logging](https://developer.apple.com/documentation/os/logging/) supports
recording event sequences for debugging and performance analysis. This informed the
local breadcrumbs, stable categories and error-level messages.
[PostHog's Swift SDK configuration](https://posthog.com/docs/libraries/ios/configuration)
documents asynchronous batching, flush controls and event filtering. This informed
queue retention, immediate failure visibility and verification of the real SDK path.
[PostHog native error tracking](https://posthog.com/docs/error-tracking/installation/ios)
supports macOS crash collection. Intents reconstructs its native payload into a strict schema: it removes exception reasons, arbitrary types, filenames, paths, functions, source context, variables, breadcrumbs and extra metadata before queueing, then filters again at the final transport. Only fixed types, native addresses and referenced Mach-O binary UUIDs survive. Crash-time context preserves the original build and consent generation.

The SDK native hook cannot be removed during a process lifetime. Intents removes the app-specific pending cache when consent changes, preventing further file writes while diagnostics are off. A persisted consent epoch rejects old reports even if deletion fails. Re-enabling sharing prepares an empty cache and refreshes the native hook context.

Readable function names require dSYMs matching the exact shipping archive. See [native symbol upload](https://posthog.com/docs/error-tracking/upload-source-maps/ios) and [local crash verification](../Verification/CrashReporting-20261010/README.md). Do not include source snippets when uploading symbols. Local builds and fixture tests do not establish live PostHog symbolication.

The collection is deliberately bounded and explicitly instrumented: it needs no
screen capture, customer-content export, provider request tracing or automatic
interaction tracking to show which workflows are failing and which builds are affected.


## Manifest and qualification

`PrivacyInfo.xcprivacy` declares installation-linked identifiers, product
interactions, performance measurements, crash data and safe diagnostic categories for analytics,
with no cross-app advertising tracking. The app does not identify an account or
link devices. UserDefaults and elapsed-time API reasons cover the telemetry code.
This local manifest is not an assertion that a store disclosure was submitted.

The [10 October repair evidence](../Verification/Telemetry-20261010/README.md)
separates source/tests, saved queries, interface checks and release/ingestion status.
The website privacy notice covers separate website analytics and is unchanged.

## Local exclusion and archive symbols (PR qualification)

Run `bash script/disable_local_telemetry.sh` once on a development Mac and restart any running Intents instances. The current-account/current-host preference in `com.coryparry.Intents.LocalTelemetry` is shared across updated app versions and takes precedence over usage/diagnostics consent, including Release builds. Legacy sharing preferences are also disabled. No hardware identifier or local exclusion marker is included in network payloads. Debug, simulator, tests, previews, demos and verification launches remain excluded independently.

The local block was applied and verified on the development Mac for this PR. It is a local machine policy, not a repository-wide analytics opt-out for other users. Keep it set when installing a distributed build here.

`script/upload_posthog_symbols.sh <archive> --verify-only` checks a Developer ID signed Intents archive and requires exact binary/dSYM UUID and architecture equality. Omit `--verify-only` to upload all archive dSYMs through PostHog CLI 0.18.10 to EU project 266962, binding the bundle identifier and the archive's version/build. Authenticate the CLI or provide `POSTHOG_CLI_API_KEY`; never commit the credential. The helper never includes source files, distributes an app, or publishes a GitHub release. Use it on the exact archive being distributed, never a later rebuild.

Symbol uploads alone cannot prove a hosted stack is readable. Verify a naturally occurring, consented native crash from an eligible machine after relaunch, matching its image UUID to the uploaded symbol set and inspecting resolved app frames in PostHog Error Tracking. Do not generate production test crashes or activity on the excluded development Mac.
