# Siri Studio

Use **App Intents → Siri Studio** to test how Siri selects actions,
fills in parameters, and replies across a conversation. [Direct Action](Mac-App-Intent-tests.md)
runs an action with the inputs you supply.

## Choose the app and write a scenario

1. Build a macOS app with App Intents metadata. Actions used by Siri’s AI model
   must also adopt `ToolIntent` (or `@AppIntent(.tool)`) on macOS 27.3 or later;
   ordinary App Shortcuts alone do not expose those actions as model tools.
   Existing intents can keep their earlier deployment support with a
   `@available(macOS 27.3, *)` extension conforming to `ToolIntent`.
   Install the app, open it once to register it, and quit it before testing.
2. Open **App Intents → Choose app…** and choose that installed build.
   The page explains which apps work here. If a selected build has no Siri
   actions, it keeps the app’s name visible and explains how to build, install,
   and choose an updated copy. An older copy in Applications may not include
   changes you just made in Xcode. Use **Check … again** after replacing it.
   A successful choice opens **Setup**, checks Xcode and signing automatically,
   and prepares your first conversation or reopens the app’s saved conversations.
3. Use the **Conversations** toolbar tab. Select a conversation in the list on
   the left, then write its messages in the focused editor. Mention the app in
   the first message and use **Add turn** for follow-ups.
4. Under each message, use **Choose expected action** to select what Siri should do.
   Required actions allow additional calls. Use **New conversation** in the list
   to add another test.
5. Finish prerequisites in the **Setup** toolbar tab. Xcode, the development team,
   and a matching signing identity are detected automatically. The default setup
   view shows the next missing action; **Finish setup** opens it from the editor.
6. Use **Save** to keep the draft, then **Run** in the window toolbar. The workspace
   opens **Results**, where you can review Siri’s replies and actions and select
   an earlier result even if the current conversation has not run. Use **Observed
   turn** to inspect each message in a multi-turn conversation.

App Intents uses the same toolbar navigation, item list, and focused content
surfaces as the suite editor. Setup and results stay on their own pages.
The **Advanced** toolbar menu holds file actions and **Test an action directly**.
Choose **Advanced → Show advanced controls** for argument and result constraints,
forbidden calls, reply checks, repeat counts, setup hooks, and raw evidence.
On Setup it also reveals every detected fact and manual Xcode/signing overrides.
Hiding these controls preserves all authored settings; a notice identifies tests
that still use them.

A forbidden action can fail a check when Siri runs it or asks for confirmation.
Argument constraints on forbidden calls and enum case matching are pending live
preview qualification. **Advanced → Open scenario document…** opens a copy of
exported JSON. Opening a scenario returns to Conversations; opening or importing
a result switches to Results. Historical results remain readable when their
draft was removed; Run and selected-conversation Swift export require a current draft.

Validation and Swift export work without running Siri. **Advanced → Export Swift…** saves
the exact test source for the selected scenario. Use **Advanced → Export all
scenarios as Swift…** for the complete document. The export records local
transcripts when run; treat its test results as potentially sensitive.

## Guided setup

The Setup tab shows the next missing prerequisite. Advanced controls reveal all seven checks:

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
  **Open app once** helps register it. If macOS selects an older installed copy,
  **Show installed copy** locates that build; replace it with your development build
  or select that installed build instead. Quit the app, then use **Recheck setup**.
- **App closed:** Intents preserves an already-running app; quit it yourself before a run.
- **Siri AI:** **Open Siri Settings**, enable Siri AI, finish its downloads, then
  confirm **Siri AI is enabled and its downloads are complete**. This is your
  confirmation, not an automatic claim about an unavailable public setting.

When Setup says **Ready to run**, press **Run** in the window toolbar. Results
appear automatically on Results. Normal runs need no terminal or manual import.
You can write a conversation while finishing setup. In Setup, turn on
**Advanced → Show advanced controls** to open **Xcode and signing** for manual
overrides; use **Recheck setup** after changing them.
Discovery preserves edits made while a check is in progress.

For an app with an isolated test-data mode, enter its flags in **Setup → Xcode and signing →
App launch arguments** with advanced controls enabled before pressing Run. Each line is one literal argument,
including any spaces; shell expansion and shell quoting are not used. Arguments
are saved with the selected app’s scenario document, replayed by Studio and the CLI,
and shown in **Results → Run facts and evidence** with advanced controls enabled. Changing
arguments marks an earlier captured run stale. Imported or older runs may have
unknown launch arguments. Use non-sensitive test flags: scenario exports, local runs, and explicit
full-transcript exports retain them, while verdict-only exports omit them.
Exported Swift tests need their own app-launch configuration when run outside Studio.

## Run and inspect

Live runs require an Apple Intelligence-capable Mac with macOS 27.3 or later
and Siri AI enabled, Xcode 27.3 or later, XcodeGen, and an interactive login.
The selected app and generated UI test target must use the same Apple development
team. Approve the development automation prompt if macOS presents one. Leave
the Mac unlocked and let the test finish without using Siri or the subject app
during the run. Siri can use Private Cloud Compute and is subject to usage limits.

Use **Run** for one scenario, or **Advanced → Run all conversations** for all scenarios.
**Run** and **Export Swift…** validate only the selected conversation’s content,
so another unfinished draft does not block a finished conversation. Both drafts
remain saved. **Run all conversations** and **Export all scenarios as Swift…**
require every conversation to be complete. App identity, document version,
shared launch arguments, and authored-ID uniqueness are checked document-wide.
The CLI’s `--scenario UUID` uses the same selected-conversation rules; `siri
validate` continues to check the whole document.
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
bundle. **Advanced → Import result bundle…** accepts an `.xcresult` from an
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

## Recover unfinished work

Edits, including app launch arguments, are retained in a local recovery draft and
reopen after quitting. **Unsaved changes** means the saved document has not caught
up with the editor. Use **Save**, or **Retry Save** after a write failure. Opening
another document or choosing another app saves the current draft first; a failed
save keeps it available. Removing a turn asks before deleting its request and
expectations.

## Guided first test

App Intents opens with a four-step guide: **Choose app → Prepare Mac → Write
conversation → Run and review**. Choose a development-signed native Mac `.app`,
not an Xcode project or an iPhone/iPad build. Setup gives ordered instructions
for the next missing prerequisite, including signing and XcodeGen installation.
Use **Check my Mac** after completing an action.

**Create an example conversation** adds a new editable draft using an action
from the selected app. Edit its request with the details your action needs;
existing drafts remain unchanged. You can write while finishing Mac setup.
Once setup and the selected conversation are ready, **Run this conversation**
opens Results. Use **Guided setup** in the toolbar to reopen the guide, or
**Test an action without Siri** to test explicit inputs without Siri.
Use **Back to Direct Action** in the toolbar to leave Siri Studio from any page,
including Results or when the guide is hidden. Conversation edits are saved
before switching, and remain available when you return to Siri Studio.

Signing guidance follows [Apple's code signing documentation](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates).
The project helper is available through [Homebrew's XcodeGen formula](https://formulae.brew.sh/formula/xcodegen).
