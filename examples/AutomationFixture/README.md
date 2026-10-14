# Automation Fixture

This committed disposable app supplies both the simulator e2e subject and the opt-in UI preparation subject. Generate its project with:

```sh
xcodegen generate --spec examples/AutomationFixture/project.yml
swift test --package-path examples/AutomationFixture --jobs 2 --scratch-path /private/tmp/intents-automation-fixture-model
```

The iOS scheme/target is `AutomationFixture`; the macOS scheme/target is `AutomationFixtureMac`. Both display **Automation Fixture**. Their bundle identifiers are `com.coryparry.IntentsAutomation.AutomationFixture` and `com.coryparry.IntentsAutomation.AutomationFixtureMac`. The Mac target supports preparation and drafting checks; simulator execution does not qualify Mac execution.

Every echo intent has one parameter named `value` and returns that value unchanged, except the enum and entity echoes, which return the selected raw value or identifier as text. Arrays accept empty inputs.

| Intent | Parameter type | Result codec |
|---|---|---|
| `EchoTextIntent` | `String` | `text` |
| `EchoBoolIntent` | `Bool` | `bool` |
| `EchoIntegerIntent` | `Int` | `integer` |
| `EchoDecimalIntent` | `Double` | `decimal` |
| `EchoDateIntent` | `Date` | `date` |
| `EchoEnumIntent` | `FixtureChoice` | `text` |
| `EchoEntityIntent` | `FixtureReference` | `text` |
| `EchoDurationIntent` | `Duration` | `duration` |
| `EchoCalendarComponentsIntent` | `DateComponents` | `calendarComponents` |
| `EchoURLIntent` | `URL` | `url` |
| `EchoIntentFileIntent` | `IntentFile` | `intentFile` |
| `EchoTextArrayIntent` | `[String]` | `textArray` |
| `EchoBoolArrayIntent` | `[Bool]` | `boolArray` |
| `EchoIntegerArrayIntent` | `[Int]` | `integerArray` |
| `EchoDecimalArrayIntent` | `[Double]` | `decimalArray` |
| `EchoDateArrayIntent` | `[Date]` | `dateArray` |

`FixtureChoice` has the stable raw values `first` and `second`. `FixtureReferenceQuery` deterministically resolves `reference-1`. `MakeFixtureFileIntent` takes no parameters and returns an `IntentFile` containing the UTF-8 bytes `phase3 fixture`, filename `fixture.txt`, and type `public.plain-text`; the file echo preserves all three.

The task UI exposes `task.title`, `task.owner`, `task.add`, `task.complete`, `fixture.control` and `fixture.reset`. Account is a segmented Personal/Work picker with Personal selected initially. Added records receive fresh UUID identifiers. Each row also has `task.record.<id>`. `TaskEntity` exposes `title`, `owner`, `completed` and `control`; `TaskQuery` reads persisted data independently of the UI. Bind an actual returned entity ID to `CompleteTaskIntent.task`. The App Shortcut phrase is “Complete <task> in Automation Fixture”.

For duplicate-record qualification, create two “Send invoice” records, one per account; select Personal by title and owner, complete its ID, and query again. Correct behavior leaves Work open. The deliberately wrong-record, missing-save and intermittent controls retain their original semantics. Missing-save reports a successful action while leaving the task unchanged on disk. The intermittent counter survives reset and restarts when the control changes.

`Metadata/` retains the byte-identical historical DuplicateTasks extraction and provenance for parser regressions. Its old bundle/query identifiers are historical evidence. Runtime catalogs must come from preparation of the current app, rather than this snapshot.

Source/model tests and a successful build are separate from actual intent execution, UI creation, independent query receipts and resource release. The reproducible e2e command and CLI usage are documented in [App automation](../../docs/wiki/App-automation.md).
