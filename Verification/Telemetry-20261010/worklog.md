# Intents telemetry repair — 10 October 2026

## Goal
Repair native Intents telemetry and the relevant PostHog analyses. Preserve unrelated local work, anonymous identity, and separate usage/diagnostic consent. No release publication or history deletion requested.

## Findings and direction
- Intents is a macOS app; the automation runners can target iPhone, but that does not make the app an iPhone telemetry target.
- Existing recorder only sends app opens under usage consent. Operational outcomes require separate diagnostic consent, which defaults off.
- Session fields are removed by both payload filters. App/environment/platform/build dimensions are missing from usage events.
- Debug launches currently use the production project except for hosted tests/acceptance fixtures.
- PostHog SDK is pinned at 3.71.4. Bundled ingestion region is EU. Connected project 266962 is shared; verify token match before mutations.
- Existing dirty telemetry and app edits copied to `/tmp/intents-telemetry-baseline` for scoped review.

## Completed local work
- Implemented fixed first-use, screen and completed-feature events; app/environment/platform/build/schema dimensions; pure background-safe filtering; development gates; preserved SDK sessions and anonymous identity.
- Wired automation executor completion/cleanup outcomes and key-window navigation. Updated consent copy, documentation and local privacy manifest.
- Reclaimed 1.5 GiB of stale generated intermediates after Xcode hit a full disk; preserved source, products and verification records.
- Independent Sol 6.1 review found two session/navigation defects. Both fixed, with session-rotation regression and owning-key-window guards; both fixes passed a second independent review; production background-session delivery remains unverified.
- Final native regression run: 44 tests across six suites passed, including the saved automation wiring test; its source passed independent review. Debug manifest packaging, plist lint and scoped diff checks passed.
- Existing dashboard updated; all nine saved native queries executed without warnings. Strict production/schema-2 filters yield no eligible data, as expected before release.
- Dashboard visual inspection is blocked by PostHog login in the available browser; temporary tab closed. Native settings inspected visually at both scroll positions; navigation and hide/return worked; development sharing remained disabled. Temporary app closed. Local arm64 Release build passed with signing disabled; packaged manifest lint passed and matches source.

## Remaining delivery evidence
- No signed release, installation over the user's app, upload, commit or push was performed.
- Updated production screen/session/feature delivery and consent behavior need confirmation after release. Historical ingestion proves only earlier builds.
- Dashboard rendering remains unverified because the available browser requires login; all nine saved queries executed without warnings.

## Validation
- Final `xcodebuild test`: 44 tests in six suites passed; result `Test-FoundationEvals-2026.10.10_12-26-40-+0100.xcresult`.
- `xcodebuild ... -configuration Release CODE_SIGNING_ALLOWED=NO build`: passed. Exact commands and logs are linked in the adjacent README.
- Native Privacy top/bottom screenshots inspected; navigation/hide/return worked; temporary app closed. No simulator opened.
- Privacy manifest source/Release lint and byte comparison passed. Scoped baseline diff reviewed; `git diff --check` passed.
