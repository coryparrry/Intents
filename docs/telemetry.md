# Anonymous app usage telemetry

Telemetry is **on by default** for installations without a saved preference.
Turn it off at any time in **Settings → Privacy → Share usage statistics**.
Saved opt-outs are preserved across launches and updates. PostHog does not initialize
when telemetry is off or its configuration is missing.

## What is collected

The only allowed event is `foundation_evals_app_opened`, with the app version and
macOS major version. It carries a random installation identifier and the event's
own timestamp. The identifier is not linked to a name, email, Apple account, or
provider account. Here, anonymous means no identity or evaluation content is sent;
the random identifier can still associate app opens from the same installation.

**AI evaluations, inputs, outputs, results, and evaluation activity are not tracked.**
There are no evaluation-start or evaluation-finish hooks. Counts, durations, scores,
errors, prompts, responses, suite names, reference files, provider addresses, and
credentials are excluded. The allowlist also rejects SDK-generated events and
strips device, screen, location, and session properties. Session recording,
automatic interaction tracking, error capture, and person profiles are disabled.
IP-based geolocation is disabled; the service still handles the source address
of the network connection.

Turning telemetry off cancels pending requests, discards unsent events, and resets
the identifier. It cannot recall data already received by PostHog or delete
historical events there.

## Configuration and verification

Foundation Evals uses EU PostHog project **Default project (266962)** with the
`foundation_evals_` prefix. The public ingestion token and host are in
`Configuration/AppInfo.plist`. The token permits ingestion, not reading analytics.

The pinned official Swift SDK batches events. The app only permits uploads to the
configured HTTPS host and blocks redirects and remote configuration requests.
Delivery is best effort; unsent batches from a previous launch are discarded.
SDK upgrades must recheck queue cleanup, property filtering, and upload behavior.

Run `TelemetryControllerTests` and `TelemetryTransportTests` in the native Xcode
test target. Tests cover the fresh default, preserved opt-outs, missing configuration,
re-enabling, rejected evaluation events, upload forwarding, and revocation. Hosted
tests do not inherit a developer's telemetry setting. Verify the Privacy switch
in the built app and confirm only app-open events reach PostHog.

[PostHog Swift SDK documentation](https://posthog.com/docs/libraries/ios)
