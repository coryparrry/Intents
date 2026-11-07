# Siri Studio

Use **App Intent Testing → Siri Studio** to test how Siri selects actions,
fills in parameters, and replies across a conversation. [Direct Action](Mac-App-Intent-tests.md)
runs an action with the inputs you supply.

## Choose the app and write a scenario

1. Build a macOS app with App Intents metadata. Install it, open it once to
   register it, and quit it before testing.
2. In **App Intent Testing**, choose the installed build and select **Siri Studio**.
   The **Siri Studio setup** checklist automatically finds a compatible Xcode and
   fills the development team and a matching, valid signing certificate. It keeps
   an already-compatible Xcode choice and never changes your system's selected Xcode.
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
6. Use **Save** to store the draft. **Documents → Open scenario document…**
   opens a copy of exported JSON for the selected app.

Validation and Swift export work without running Siri. **Export Swift…** saves
the exact test source for the selected scenario. Use **Documents → Export all
scenarios as Swift…** for the complete document. The export records local
transcripts when run; treat its test results as potentially sensitive.

## Guided setup

The checklist shows seven prerequisites and the next action for each missing one:

- **Compatible Mac:** macOS 27.3 or later.
- **Xcode:** Xcode 27.3 or later with SiriEvaluations. Compatible installations in
  Applications, your selected Xcode, and an explicit developer directory are checked.
  If component or license setup is unfinished, **Open Xcode** and finish it there.
- **Development signing:** a valid Apple Development identity from the selected
  app's own team. Intents selects its exact certificate automatically; it never
  re-signs your app or substitutes a different team.
- **Test project tools:** XcodeGen. **Copy install command** copies
  `brew install xcodegen` when it is missing.
- **App registered:** the exact selected build must be installed and opened once.
  **Open app once** helps register it. Quit the app, then use **Recheck setup**.
- **App closed:** Intents preserves an already-running app; quit it yourself before a run.
- **Siri AI:** **Open Siri Settings**, enable Siri AI, finish its downloads, then
  confirm **Siri AI is enabled and its downloads are complete**. This is your
  confirmation, not an automatic claim about an unavailable public setting.

When the checklist says **Ready to run**, write a scenario, choose its expectations,
and press **Run**. Results appear in Studio automatically. Normal runs do not
require a terminal or a manual result import. You can hide the checklist to author
or export while prerequisites are missing. **Xcode and signing** below the editor
remains available for advanced overrides; use **Recheck setup** after changing them.
Discovery preserves edits made while a check is in progress.

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
exported Swift test. To grade the import, Studio verifies the scenario content,
revision, and target app against the export. Re-export and rerun tests whose
attachments lack a content fingerprint. **Open saved run…** accepts the
directory containing a `run.json` of up to 64 MiB. Runs and imports require an
empty output directory, which Studio makes private before writing evidence.
Run records and scenario documents are under
`~/Library/Application Support/Intents/SiriStudio/`.
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
