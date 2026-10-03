# Intent Lab Tasks

This is an independent iOS task-management example. Its SwiftData store and `CompleteTaskIntent` are app-owned; the intent calls the same repository that backs the task list. `TaskEntityQuery` reloads records from the persistent store using stable IDs.

## Build and run

Generate the project with `xcodegen generate --spec project.yml`, then open `IntentLabTasks.xcodeproj`. Run the `IntentLabTasks` scheme with the `Debug` configuration for the ordinary example app. The app seeds `task-001` (“Buy milk”) and `task-002` (“Book appointment”) only when its persistent store is empty.

The app target links only `IntentLabContracts`. Its `Debug` and `IntentLabTesting` configurations compile the shared, non-discoverable `IntentLabInvokeFeatureIntent` and harmless `IntentLabReadinessIntent` under `DEBUG && INTENT_LAB_TEST_SUPPORT`; app startup registers the app-owned `TaskFeatureTestSupport` for the feature operation. `IntentLabTesting` also uses bundle ID `com.example.IntentLabTasks.integration-tests`, a separate app container, and the `INTENT_LAB_TESTING` condition. The shared scheme runs the test target with that configuration. Test setup always relaunches the integration app with a fresh context and reseeds only that isolated store. Release builds omit the test intents and feature support.

## Intent Lab consumer adapter

`IntentLabIntegration.json` records the v2 action, preparation and cleanup allowlists, typed observer plan, isolated dataset, completion evidence, and Siri route. `queryOperations` delegates stable-ID entity reads to the shared `IntentLabQueryObserver`; the adapter owns test preparation, readiness, fresh-receipt checks, and cleanup verification. It refuses bundle IDs or fixture operations outside its allowlists and accepts completion only when a newly persisted action receipt carries the current invocation context. After each returned attempt, cleanup restores and verifies the isolated task store; a cleanup failure invalidates its evidence.

The declaration also exposes feature `com.example.intent-lab-tasks`, operation `complete-task`, and its canonical SHA-256 interface digest for the required string input `taskID`. The shared test intent routes that request through `TaskFeatureTestSupport` to `TaskCompletionService`, the same production service called by `CompleteTaskIntent`. The service records a top-level `productionService` receipt at entry; the generic test wrapper records only a nested `testSupport` receipt. The debug-only `TaskEntity.actionReceipts` query exposes both receipts to the harness. The declared readiness intent only returns a typed ready result and caller context; it does not invoke a task operation.

The production completion intent returns a plausible message after successful execution. In the test-only `suppressPersistence` fault it deliberately returns the same message without saving. The independent entity query must still report the target incomplete and no receipt. The `mutateUnrelatedTask` fault saves completion plus an unintended change to `task-002`; its separate assertion detects that change. Runner-level fault tests inspect the emitted evidence envelope and verify that both defects fail the behaviour scenario and its portable release-qualification check, while the correct mutation passes.

The invoke/readiness intents and feature adapter compile only under `DEBUG && INTENT_LAB_TEST_SUPPORT`. Repository fixture-reset and fault paths compile under `INTENT_LAB_TESTING || INTENT_LAB_TEST_SUPPORT`; the `IntentLabTesting` configuration defines both. Release omits those paths. Queried entities carry their preparation context, and the test build rejects an action that receives an entity from an earlier context. Cancellation cannot prove an out-of-process intent stopped, so a timed-out run still requires host-side device quarantine before another scenario may reset the store. Never point the integration scheme at an everyday app installation or production data.

## Siri

The app registers task-parameter App Shortcuts in the ordinary Debug product and isolated test product. They resolve the selected task through `TaskEntityQuery` at invocation time; no shortcut embeds a tokenless task entity. In the integration build, `CompleteTaskIntent` rejects missing or stale entity context, while a fresh query binds the selected task to the active invocation. A Siri check requires a signed install on a configured physical iPhone. Intent Lab's recognized-text Siri lane tests Siri activation with supplied text; it does not test microphone recognition. The persisted receipt and entity query provide a fresh completion check after activation.

## Outside-repository consumer check

For a consumer-only install check, copy this example to a clean checkout, pin the `FoundationEvalsDeveloper` Swift package dependency to the reviewed repository revision, and retain only the consumer-owned integration and test files. The repository's local path package reference is for in-repository development; it is not a release dependency.
