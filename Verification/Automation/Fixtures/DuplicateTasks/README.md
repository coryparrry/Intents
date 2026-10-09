# Duplicate Tasks seeded control app

This ordinary source app deliberately supplies correct, wrong-record, missing-save and intermittent controls for canonical business qualification. It is **seeded verification**, not a discovered defect in FlipBook or a broad app-support result. There is no customer adapter or pre-existing test target in the generated app project. Its actual App Intent and entity query use its own persisted document.

Create two `Send invoice` tasks through the UI, owned by Work and Personal. Query real `TaskEntity` records and bind the unique Personal entity ID to `CompleteTaskIntent.task`. Independently query again, using the same checks for every control: Personal.completed is true, Work.completed is false. Verify both are false and the persisted control equals the approved mode before dispatch. Never select records by the property being asserted. Reset creates new IDs on every attempt; query results supply them.

The missing-save control returns changed in-memory state and a successful intent dialog while keeping saved task state unchanged. Queries always reload disk. The intermittent control alternates missing-save/correct behavior using an explicit persisted counter that survives fixture reset. Selecting a different control restarts its counter.

```sh
xcodegen generate --spec Verification/Automation/Fixtures/DuplicateTasks/project.yml
swift test --package-path Verification/Automation/Fixtures/DuplicateTasks --jobs 2 --scratch-path /private/tmp/intents-duplicate-tasks-model
```

Source/model tests and a successful build do not qualify real intent execution, UI creation, independent query receipts, runner release or canonical verdicts. Actual profiles and their reports must be recorded separately before any gate is marked qualified. This app has its own disposable bundle ID, `com.coryparry.IntentsAutomation.DuplicateTasks`; never use a personal app container as its fixture store.
