# Automatic native crash reporting — 10 October 2026

Intents now enables automatic PostHog fatal crash reporting in eligible macOS production builds when **Share diagnostic statistics** is on. This switch remains off by default and independent of usage sharing. Reports are sent on the next launch. Development, test, preview, demo and isolated verification runs remain excluded.

## Privacy and consent

Outgoing reports retain fixed crash categories, native code addresses, referenced Mach-O UUIDs, image sizes/architecture and the original crashed build/session. Exception messages are replaced with a fixed placeholder. Raw reasons, arbitrary exception names, file paths, filenames, functions, source snippets, variables, breadcrumbs, prompts, responses, URLs, credentials and other properties are removed. Bounds limit exceptions, frames, images and upload size. Filtering runs before SDK queueing and again at the final transport, including retained batches. Diagnostic batches contain one event so an offline backlog of deep stacks cannot exceed the size limit as a combined batch. Usage-only batching remains unchanged.

The SDK can place a native report on this Mac before it is parsed and filtered. This is distinct from the sanitized event sent to PostHog. No source snippets should be included in symbol uploads.

The pinned SDK's native hook cannot be removed during the process lifetime. Turning sharing off clears the app-specific pending directory, preventing the hook from creating another file while consent is off. Each consent change also revokes the earlier epoch; stale reports cannot upload after re-enable even if file deletion fails. Re-enable recreates an empty directory and refreshes the native hook's context. Other apps' pending stores and the installation's anonymous identity are preserved.

## Coverage and evidence

| Question | Mechanism | Verification |
|---|---|---|
| Was a fatal native crash captured? | SDK Mach/signal/NSException handler and next-launch processing | Separate fixture actually raises an NSException and exits with SIGABRT; next launch produces one report |
| Is private content excluded? | Reconstruct the native payload from a strict allowlist | Background pure-filter tests, real SDK plus final app transport, and fixture reports omit the injected private sentinel |
| Do consent changes revoke crashes? | Pending-store purge and persisted consent epoch | Unit tests reject old/missing context; actual fixture writes no pending report after opt-out and captures fresh context after re-enable |
| Does the report describe the crashed build? | Persisted crash-time context, SDK `skipBuildProperties` | SDK regression and actual next-launch fixture preserve the crashed build rather than the reporting build |
| Can addresses become readable stacks? | Mach-O UUID, load address, instruction address and matching dSYM | Captured fixture UUID matches its local dSYM; `atos` resolves `Fixture.main()` |
| Which releases are affected? | Fatal crash count by original `app_build` | Saved PostHog query executes successfully; no eligible production events yet |

**50 tests in eight focused suites passed** with Xcode Debug, macOS, two jobs and parallel testing disabled:

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj \
  -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" -disableAutomaticPackageResolution \
  -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO \
  -only-testing:FoundationEvalsTests/TelemetryControllerTests \
  -only-testing:FoundationEvalsTests/TelemetryTransportTests \
  -only-testing:FoundationEvalsTests/TelemetryDiagnosticsTests \
  -only-testing:FoundationEvalsTests/TelemetryUsageTests \
  -only-testing:FoundationEvalsTests/TelemetryPayloadFilterTests \
  -only-testing:FoundationEvalsTests/TelemetryCrashTests \
  -only-testing:FoundationEvalsTests/TelemetryCrashSDKTests \
  -only-testing:FoundationEvalsTests/AutomationMCPTests test
```

`NativeCrashFixture.swift` uses the compiled pinned SDK and the production native sanitizer, a separate bundle identifier, a fake project token and a URLProtocol that never reaches the network. Its local reports each contain seven frames and three binary images. It verifies native SDK capture, next-launch processing and the process-lifetime handler's opt-out/re-enable behavior. The application SDK test separately verifies the complete app filter and final transport, including a queued deep-stack backlog larger than 256 KiB in aggregate, delivered as individually bounded events. No working Intents session was deliberately crashed and no fake production event was sent.

`upload-sanitized.json`, `upload-reenabled-sanitized.json`, `local-symbolication.txt` and `tests-summary.txt` contain the network-free fixture evidence. Local function-name resolution succeeded; fixture source line numbers were not qualified.

The final **unsigned arm64 Release build passed** with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`, two jobs and automatic package resolution disabled. The packaged privacy manifest passes lint and matches the source byte-for-byte. The executable and local dSYM UUIDs match. An earlier final rebuild exhausted disk space; removing only generated caches from this task's temporary directories allowed the rebuild to complete. `git diff --check` passed. No source fix was needed for the disk failure.

Independent Sol 6.1 source review found no material defect in privacy reconstruction, symbol metadata, original-build attribution or consent handling. The actual Debug Privacy settings were visually inspected at the top and bottom; disclosures wrap, scrolling reveals the complete text, development sharing stays disabled, and the local report remains available. The temporary app was closed. No simulator was used.

## PostHog

[Intents usage and diagnostics](https://eu.posthog.com/project/266962/dashboard/998410) now includes [Native fatal crashes — crashed build](https://eu.posthog.com/project/266962/insights/pv2qBZ2F). Project 266962 already has native error tracking enabled; no global project switch was changed. The existing nine analyses remain, with the new chart below them.

The saved query filters `app=intents`, `environment=production`, `platform=macOS`, `schema_version=2`, and `$exception_level=fatal`. It counts reports by the crashed build over 30 days. It does not claim a crash rate: diagnostic consent can differ from usage consent and next-launch delivery can miss crashes. The query returns a valid empty result pending a shipped release. This is an app-specific operational analysis, not a governed canonical metric. Browser visual inspection of the dashboard remains blocked by its login page; query and layout verification used the connector.

## Release symbols and remaining qualification

Use the **exact shipping archive's dSYMs**. A local unsigned build is not evidence of symbols for a distributed release. Before upload, compare each architecture's UUID in the archive executable and corresponding dSYM:

```sh
xcrun dwarfdump --uuid "$archive/Products/Applications/Intents.app/Contents/MacOS/FoundationEvals"
xcrun dwarfdump --uuid "$archive/dSYMs/Intents.app.dSYM"
```

Use a current authenticated PostHog CLI in the EU project. Read the version/build from that archive's `Contents/Info.plist`, then upload without `--include-source`:

```sh
POSTHOG_CLI_HOST=https://eu.posthog.com POSTHOG_CLI_PROJECT_ID=266962 \
  posthog-cli dsym upload --directory "$archive/dSYMs" \
  --main-dsym Intents.app.dSYM --release-name com.coryparry.FoundationEvals \
  --release-version "$archive_version" --build "$archive_build"
```

These commands are guidance and have not uploaded local symbols. Verify CLI success and matching symbol-set UUIDs in PostHog, then inspect an eligible real release crash for readable application frames. Do not deliberately crash a working user session. System framework symbols, hangs, memory pressure and system performance reports are outside this implementation.

The native manifest now declares installation-linked Crash Data for analytics, with no advertising tracking. Consent copy and the app's local policy documentation are updated. Store privacy disclosures must be reconciled before publishing a release. The website privacy page describes the website, so it was not changed. No store submission, release publication, symbol upload, commit or push was performed.

## Sources reviewed

Reviewed on 10 October 2026: [native crash setup](https://posthog.com/docs/error-tracking/installation/ios), [native dSYM upload](https://posthog.com/docs/error-tracking/upload-source-maps/ios), the connector's symbolication guidance, and pinned PostHog Swift **3.71.4** (`8551035fe72d8d6605cb077dd853867dc04283ec`). Source inspection covered the automatic integration, crash processor, frame/image models, context writer, exception steps and PHPLCrashReporter's process-global handler/file writer. Official pages were fetched as HTML and the relevant setup/privacy/symbol sections reviewed; no claim is made to have reviewed all PostHog documentation.
