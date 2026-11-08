# Siri Studio

Use **App Intents → Siri Studio** to test how Siri selects actions,
fills in parameters, and replies across a conversation. [Direct Action](Mac-App-Intent-tests.md)
runs an action with the inputs you supply.

## Choose the app and write a scenario

1. Build a macOS app with App Intents metadata. Install it, open it once to
   register it, and quit it before testing.
2. In **App Intents**, choose the installed build and select **Siri Studio**.
3. Add a scenario and enter one or more turns. Name the app in requests where
   Siri needs to find it in the background.
4. In the inspector, choose required actions and any argument or result
   constraints. Required calls in one group can be ordered or unordered.
   Use **Forbidden calls** to catch unwanted actions: required calls alone
   allow extra calls. A forbidden action can fail the check when Siri runs it
   or asks for confirmation. Argument constraints on forbidden calls and enum
   case matching are pending live preview qualification.
5. Add reply checks, scenario-wide constraints, or an optional Direct Action
   setup that resets app state before each repeat.
6. Use **Save** to publish the draft as the saved document. Edits are also kept
   in a local recovery draft and reopen after quitting. **Unsaved changes** means
   the saved document has not caught up with those edits. Opening another document
   or selecting another app saves the current work first; a save failure keeps the
   draft in place and shows **Retry Save**. Removing a turn asks you to confirm
   removal of its request and expectations.
7. **Documents → Open scenario document…** opens a copy of exported JSON for the selected app.

Validation and Swift export work without running Siri. **Export Swift…** saves
the exact test source for the selected scenario. Use **Documents → Export all
scenarios as Swift…** for the complete document. The export records local
transcripts when run; treat its test results as potentially sensitive.

## Run and inspect

Live runs require an Apple Intelligence-capable Mac with macOS 27.3 or later
and Siri AI enabled, Xcode 27.3 or later, XcodeGen, and an interactive login.
The selected app and generated UI test target must use the same Apple development
team. Approve the development automation prompt if macOS presents one. Leave
the Mac unlocked and let the test finish without using Siri or the subject app
during the run. Siri can use Private Cloud Compute and is subject to usage limits.

Use **Run** for one scenario, or the adjacent menu for all scenarios.
Use repeats to see whether results vary. **Cancel** stops the owned test and
retains available evidence. The [Siri Evaluations reference](https://developer.apple.com/documentation/sirievaluations)
describes Apple's grading.

Apple provides the scenario metrics. Intents shows which turns were reached,
the observed calls and arguments, their outcomes and results, and Siri’s reply.
An **Intents check** is a local comparison to help explain the transcript.
A complete repeat that fails an Apple metric can make the scenario **Failed**;
a partial repeat can be **Incomplete** even when Apple grades its reached turns.
**Blocked** means prerequisites or reliable evidence were missing. Edits
mark an earlier result **Stale**. If Apple provides only aggregate metrics,
the exact number of passing repeats may be unavailable.

Use **Run facts and evidence** to locate the generated Swift, log, and result
bundle. **Documents → Import result bundle…** accepts an `.xcresult` from an
exported Swift test. Import first saves the current edits and matches the attached
scenario ID, revision, and a digest of its complete authored content and target app.
An independently edited copy cannot reuse an old passing verdict. Older exports
without that digest show **Blocked**; export and run the current document again.
Open the corresponding scenario document to see its authored expectations. **Open saved
run…** accepts the directory containing `run.json`. Run records and scenario
documents are under `~/Library/Application Support/Intents/SiriStudio/`.
Verdict-only export omits the authored and observed conversation. The separate
transcript export includes it.

For an iPhone app you own, put the shared intents and feature code in an
[AppIntentsPackage](https://developer.apple.com/documentation/appintents/appintentspackage)
and link it into a Mac target with its own bundle identifier. The Mac test does
not cover iPhone UI or onscreen context. Siri Studio does not target iPhone
Simulator, physical iPhone, or Mac Catalyst in this version.

## Use the CLI

From the repository root:

```sh
swift build --jobs 2 --product intents-native-tests
cli="$(swift build --show-bin-path)/intents-native-tests"

"$cli" siri validate --app "$APP" --scenarios scenarios.json
"$cli" siri export --app "$APP" --scenarios scenarios.json --output SiriStudioTests.swift
"$cli" siri run --app "$APP" --scenarios scenarios.json \
  --developer-dir "$DEVELOPER_DIR" --team "$TEAM" --identity "$IDENTITY" \
  --output "$RUN_DIRECTORY"
"$cli" siri show --run "$RUN_DIRECTORY"
```

Use an empty output directory. For `export` or `run`, add `--scenario UUID`
once per selected scenario or omit it to use the complete document. Xcode
applies the longest selected scenario’s allowance to each test in the run.
`--allowance` overrides that bound (up to 1,800 seconds); `--timeout` sets the
whole-run limit (up to four hours). The CLI returns a nonzero exit code when
any scenario does not pass. See the
[Courtside sample](../../examples/SiriStudioSample/README.md) for fixture setup
and qualification.
