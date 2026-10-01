# Intent Lab Tasks

This is an independent iOS task-management example. Its SwiftData store and `CompleteTaskIntent` are app-owned; the intent calls the same repository that backs the task list. `TaskEntityQuery` reloads records from the persistent store using stable IDs.

## Build and run

Generate the project with `xcodegen generate --spec project.yml`, then open `IntentLabTasks.xcodeproj`. Run the `IntentLabTasks` scheme with the `Debug` configuration for the ordinary example app. The app seeds `task-001` (“Buy milk”) and `task-002` (“Book appointment”) only when its persistent store is empty.

The `IntentLabTesting` configuration uses bundle ID `com.example.IntentLabTasks.integration-tests`, a separate app container, and the `INTENT_LAB_TESTING` compilation condition. The shared scheme runs the test target with that configuration. Test setup always relaunches the integration app with a fresh context and reseeds only that isolated store.

## Intent Lab consumer adapter

`IntentLabIntegration.json` records the v2 action, preparation and cleanup allowlists, typed observer plan, isolated dataset, completion evidence, and Siri route. `queryOperations` delegates stable-ID entity reads to the shared `IntentLabQueryObserver`; the adapter owns test preparation, cleanup verification, readiness, and fresh-receipt checks. It refuses bundle IDs or fixture operations outside its allowlists and accepts completion only when a newly persisted action receipt carries the current invocation context. After each returned attempt, cleanup restores and verifies the isolated task store; a cleanup failure invalidates its evidence.

The production completion intent returns a plausible message after successful execution. In the test-only `suppressPersistence` fault it deliberately returns the same message without saving. The independent entity query must still report the target incomplete and no receipt. The `mutateUnrelatedTask` fault saves completion plus an unintended change to `task-002`; its separate assertion detects that change. Runner-level fault tests inspect the emitted evidence envelope and verify that both defects fail the behaviour scenario and its portable release-qualification check, while the correct mutation passes.

The test hooks and fault branches are compiled only in `IntentLabTesting`. Queried entities carry their preparation context, and the test build rejects an action that receives an entity from an earlier context. Cancellation cannot prove an out-of-process intent stopped, so a timed-out run still requires host-side device quarantine before another scenario may reset the store. Release and ordinary Debug products do not contain the test fault hooks. Never point the integration scheme at an everyday app installation or production data.

## Siri

The app registers task-parameter App Shortcuts in the ordinary Debug product and isolated test product. They resolve the selected task through `TaskEntityQuery` at invocation time; no shortcut embeds a tokenless task entity. In the integration build, `CompleteTaskIntent` rejects missing or stale entity context, while a fresh query binds the selected task to the active invocation. A Siri check requires a signed install on a configured physical iPhone. Intent Lab's recognized-text Siri lane tests Siri activation with supplied text; it does not test microphone recognition. The persisted receipt and entity query provide a fresh completion check after activation.

## Outside-repository consumer check

For a consumer-only install check, copy this example to a clean checkout, pin the `FoundationEvalsDeveloper` Swift package dependency to the reviewed repository revision, and retain only the consumer-owned integration and test files. The repository's local path package reference is for in-repository development; it is not a release dependency.
