# Production evaluations verification

Date: 3 October 2026. Base: 8d24fb5f1502481641c029d00722a17ac037af66. Source is isolated on codex/production-eval-workspace and remains outside the managed intents stack.

## Acceptance evidence

| Requirement | Observed evidence |
|---|---|
| Versioned datasets | Streaming import, source partition/duplicate/redaction/tamper/aggregate-size tests passed. 10,000 examples imported and evaluated. |
| Durable bounded execution | 123 responses saved, paused without execution, then remaining work resumed with exactly 10,000 distinct request executions; lease, cancellation, retry, deadline and interrupted-action tests passed. |
| Unattended workers | 39 real-process CLI assertions; fresh native app worker completed one actual on-device and AI-rubric evaluation with exit 0. |
| Opt-in capture | Sanitizer/allowlist/retention tests passed. Final regression checks 32 independent first writers, private permissions and append preservation. Capture creates no network upload. |
| Reports and gates | Source-grouped confidence, cohorts, repetitions/targets, latency/cost, baseline incompatibility and missing-evidence tests passed. Native pass and incomplete reports observed. |
| Attributed review | Assignment, disagreement/adjudication, reconciliation, crash recovery and coherent audited export tests passed. Native prompt/reference and human label flow observed. |
| Existing UI | Actual sidebar, datasets/jobs/review/reports/workers screenshots and controls inspected. Final navigation resets scroll position; Repeat batch creates a new pending job; captured report shows unavailable latency and incomplete evidence. |
| Independent verification | Separate core and native/UI source reviews completed; material findings fixed and rechecked. Local qualification only. |

## Commands and results

- `swift test --package-path Packages/ProductionEvals -j 2` — 18 tests passed before the final capture-only fix, including the 10,000-response test. Log: `/tmp/intents-production-all-tests-final.log`.
- `swift test --package-path Packages/ProductionEvals -j 2 --filter 'independentCaptureWriters|optInCapture'` — both tests passed after the final capture fix. Log: `/tmp/intents-production-capture-final.log`. The test suite now contains 19 distinct tests.
- `swift build -j 2 --product intents-evals` — passed on final source. Log: `/tmp/intents-production-cli-final.log`.
- `python3 script/test_production_evals.py .build/debug/intents-evals` — 39 assertions passed with actual child worker processes. Log: `/tmp/intents-production-cli-integration-final.log`.
- `swift build -j 2 --target FoundationEvalsDeveloper` — passed on final source. Log: `/tmp/intents-production-sdk-final.log`.
- `xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /tmp/intents-production-build -clonedSourcePackagesDirPath /tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 CODE_SIGNING_ALLOWED=NO build` — passed on final source. Log: `/tmp/intents-production-native-build-final.log`.
- `codesign --force --deep --sign - /tmp/intents-production-build/Build/Products/Debug/Intents.app` and `codesign --verify --strict --deep /tmp/intents-production-build/Build/Products/Debug/Intents.app` — passed. Development ad-hoc signature; no distribution qualification.
- `git diff --check` — passed before delivery.

The repository's existing aggregate portable tests have an unrelated private AppIntentsTesting SDK/runtime discovery incompatibility on this host. They do not constitute a passing test claim. The independent ProductionEvals package and targeted native/CLI builds were used for this scope. The new CI workflow runs these fixture/protocol checks; hosted CI is not yet a qualification claim.

## Native model and interface evidence

Exact fresh artifact: `/tmp/intents-production-build/Build/Products/Debug/Intents.app`, bundle ID `com.coryparry.FoundationEvals`, ad-hoc CDHash `007777cf791526c711ec3942029df696c937e74e`. The final interface was inspected after checking its executable path and launch time. Both test processes were closed after inspection.

Synthetic example: “Reply with Friday. Do not include any other text.” Reference and original captured output: Friday. Metadata: task=format, locale=en_GB, coverage=happy-path; curated regression partition. Production import confirmation was exercised with synthetic content.

GUI job A0522376-A55A-4723-A43F-A1F4F59E7766 passed 1/1 on-device response and AI-rubric grading. Saved workflow trace showed native generation, scoring, tokens and timing. Unattended clone E52D5840-C805-4E26-80EE-0486429EC776 passed 1/1, returned exit 0 and retained trace evidence. Worker reported Apple silicon, Version 27.2 (Build 26B5091g), en_GB and On-device · AFM 3 Core Advanced. Unattended subject duration was 7,489 ms; these small smoke timings are not throughput benchmarks.

Unattended workspace file hashes outside ProductionEvals were unchanged; no new temporary native worker directory remained after clean exit. Evidence: `/tmp/intents-production-headless-evidence.json` and report `/tmp/intents-production-headless-report.json`. Final GUI repeat of the captured batch saved the unchanged output, required review before qualification and showed P95 latency unavailable.

## Operational limits

This verifies local fixture capacity, real process integration, the native interface and two small on-device checks on one Mac. It does not qualify real customer capture, an iPhone/iPad/OS matrix, a physical fleet, hosted authentication, provisioning, billing enforcement or a shipped release. Worker labels and reviewer names are trusted local attribution, not attestation/authentication. Sanitization and consent belong to the integrating app. Shared storage must support coherent file locks and atomic renames. Unattended schedules need a live worker; no daemon is installed.
