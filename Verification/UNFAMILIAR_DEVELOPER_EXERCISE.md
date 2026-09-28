# Unfamiliar-developer exercise: an existing app

This is a prepared exercise, not evidence that a human completed it. Use the
developer's existing **FlipBook** app, not either Intent Lab sample. Its
`IdentifyItemIntent`, `CompareItemPricesIntent`, and `FindInventoryIntent` are
real App Intents. `IdentifyItemIntent` opens the app's identification flow;
the app's AI work happens later, under its own subscription, service, and
consent rules. A successful intent invocation alone cannot establish that the
AI feature produced a correct result.

## Participant and setup

- Recruit a developer unfamiliar with the Intents implementation and the
  FlipBook integration. The implementation agent and repository fixtures do
  not count as that participant.
- Provide a writable FlipBook development checkout, a signed test target,
  Xcode 27, an eligible test account, the app's normal AI service access, and
  a physical iPhone with Siri if Siri is in scope. Use a synthetic item image
  and synthetic inventory data. Keep production data out of the fixture.
- Give the participant the built Intents app and `docs/wiki/Intent-Lab.md`,
  without coaching on internal UUIDs, digests, observation names, or source
  files. Observe where the workflow itself explains missing support.

## Task to give the participant

> Connect FlipBook to Intent Lab. Use its actual item-identification service
> as the App Feature subject, then test the supported App Intent and Siri
> routes with the same synthetic item. Make the route outcome observable in
> FlipBook's own state. Save a failing requirement, change FlipBook so the
> observed defect is fixed, and rerun the unchanged requirement. Explain from
> the saved result which route changed and why you trust the comparison.

The participant should use the package installer or its reviewed manual
output, implement app-owned fixture preparation and observations, and declare
the real business input/output interface. The adapter scaffold must remain
fail-closed until those app operations exist. An app-owned feature may need to
be introduced for this exercise; the existing App Intent is a navigation
action and must not be presented as if it already returns AI identification.
After the participant selects routes and starts a run, Intent Lab must invoke
each route and capture its result. Do not ask the participant to tap the app's
feature button or speak a Siri phrase to stand in for an automated route.
Device unlock and trust or consent prompts remain device security prerequisites.

## Observe and record

Record the exact Intents commit, FlipBook commit, test target, signing mode,
device/OS, app build SHA-256, fixture content digest, and consent state. Time
the participant from opening **Connect app** to the first meaningful saved
route result. Record each place they needed outside help, could not find a
control, or misread a status. Preserve the original failure, changed-app
candidate, unchanged contract digest, coordinate evidence, comparison
qualification, and any partial or blocked route. Reopen Intents and confirm
the saved collection and evidence remain available.

Pass AD-01 only if that independent participant completes the task without
agent-authored answers, identifies the observed failure correctly, and can
explain the fix/retest evidence. A missing physical iPhone, service access,
test account, or participant blocks only the corresponding exercise route;
it does not substitute for package, native, CLI, or fixture verification.

## Current status

Prepared from the existing FlipBook source. On 2026-09-28 the repository owner
and paired iPhone became available, but this does not satisfy the independent
participant criterion. FlipBook service eligibility has not been verified, and
the installed Xcode 27.0 AppIntentsTesting bundle could not load on the iOS
27.2 device because its referenced AppIntentsServices symbol is absent. Use a
compatible Xcode/device runtime before asking the participant to start the
timed exercise. AD-01 remains unverified. No FlipBook files were changed.
