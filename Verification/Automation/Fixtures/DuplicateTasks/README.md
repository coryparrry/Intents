# Duplicate Tasks seeded control app

This ordinary source app deliberately supplies correct, wrong-record, missing-save and intermittent controls for canonical business qualification. It is **seeded verification**, not a discovered defect in FlipBook or a broad app-support result. There is no customer adapter or pre-existing test target in the generated app project. Its actual App Intent and entity query use its own persisted document.

The project has two app targets sharing the same UI, intents, repository and disk store: `DuplicateTasks` for iOS and `DuplicateTasksMac` for native macOS 26+. The Mac target explicitly disables App Sandbox because the reviewed independent storage boundary is the fixture's `Documents/DuplicateTasks.json`. Its disposable bundle ID is the same as the iOS fixture; source intake must select the platform's actual target.

Create two `Send invoice` tasks through the UI, owned by Work and Personal. Query real `TaskEntity` records and bind the unique Personal entity ID to `CompleteTaskIntent.task`. Independently query again, using the same checks for every control: Personal.completed is true, Work.completed is false. Verify both are false and the persisted control equals the approved mode before dispatch. Never select records by the property being asserted. Reset creates new IDs on every attempt; query results supply them.

The missing-save control returns changed in-memory state and a successful intent dialog while keeping saved task state unchanged. Queries always reload disk. The intermittent control alternates missing-save/correct behavior using an explicit persisted counter that survives fixture reset. Selecting a different control restarts its counter.

```sh
xcodegen generate --spec Verification/Automation/Fixtures/DuplicateTasks/project.yml
swift test --package-path Verification/Automation/Fixtures/DuplicateTasks --jobs 2 --scratch-path /private/tmp/intents-duplicate-tasks-model
```

For the native Mac source-preparation workflow, select this fixture folder and `DuplicateTasksMac`, configuration `Debug`, target kind `nativeMac`. Resolve the current target with `AutomationMacGUIIdentity.currentTarget()`; a stored or fabricated login-session string is not preparation authority. The app candidate's target ID is `0097213446DD56D3A67F9399`. Preparation captures the source, builds the app, and adds its associated intent host to the captured copy. The unchanged task UI exposes `fixture.control`, `fixture.reset`, `task.title`, `task.owner`, `task.add`, and `task.record.<entity-id>` for the approved fixture setup. Choose `Correct`, `Wrong record`, `Missing save`, or `Intermittent` through the ordinary Behavior picker; create the duplicate titles through the ordinary UI.

This command builds only the standalone native fixture; it does not prepare the associated intent host, launch the fixture, write its Documents file, or qualify a durable verdict:

```sh
xcodebuild build \
  -project Verification/Automation/Fixtures/DuplicateTasks/DuplicateTasks.xcodeproj \
  -scheme DuplicateTasksMac -configuration Debug \
  -destination 'platform=macOS' -sdk macosx -jobs 2 \
  -derivedDataPath /private/tmp/intents-duplicate-tasks-mac-build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

The resulting product is `/private/tmp/intents-duplicate-tasks-mac-build/Build/Products/Debug/DuplicateTasksMac.app`. The registered durable-reader recipe is `duplicate-tasks-json.v2`, pinned to this regenerated dual-platform project and the same three unchanged business source files. The earlier iOS-only project recipe `duplicate-tasks-json.v1` is unsupported; retained old recipes need new source preparation and review. `Metadata/provenance.json` remains evidence for its recorded iOS product only.

Source/model tests and a successful build do not qualify real intent execution, UI creation, independent query receipts, runner release or canonical verdicts. Actual profiles and their reports must be recorded separately before any gate is marked qualified. This app has its own disposable bundle ID, `com.coryparry.IntentsAutomation.DuplicateTasks`; never use a personal app container as its fixture store.
