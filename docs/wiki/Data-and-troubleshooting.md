# Data, privacy, updates, and troubleshooting

[Home](Home.md) · [Getting started](Getting-started.md) · [Runs and results](Runs-and-results.md)

## Where Intents saves data

Intents saves projects, suites, imported files, and run history under `~/Library/Application Support/FoundationEvals/`. The batch store is in the `ProductionEvals/` subdirectory. Suite human reviews, judge-check state, drafts, and batch audits are also local. The app does not encrypt these files itself. A run can include prompts, responses, references, tool arguments, tool outputs, transcripts, and traces.

**Export Run as JSON** saves a copy of one run. Read the file before you share it.

Deleting a run removes its saved results and trace. **Start from Scratch** can reset a suite, clear its runs and traces, or do both. The app cannot undo these actions. Before a reset, back up the Application Support data or export the evidence that you need.

## Back up and restore a complete workspace

Quit Intents and the standalone plugin, and stop all CLI, polling, and native workers before copying data. A copy taken during a write can mix catalog, run, and audit versions. Use a private backup destination; these directories contain authored inputs and model outputs. An exported run is only one record, not a complete workspace backup.

Copy each directory that you use, preserving its complete contents and permissions:

| Data | Location |
|---|---|
| Native projects, suites, attachments, reviews, drafts, run history and batch store | `~/Library/Application Support/FoundationEvals/` (includes `ProductionEvals/` and `ProductionReviewDrafts.json`) |
| Siri documents, recovery drafts and frozen runs | `~/Library/Application Support/Intents/SiriStudio/` |
| Direct App Intent logs and result bundles | `~/Library/Application Support/Intents/MacIntentTesting/` |
| Standalone plugin projects, suites and runs | The directory selected by `FOUNDATION_EVALS_PLUGIN_DATA`, otherwise `PLUGIN_DATA`, otherwise `~/.local/share/apple-foundation-evals` |
| Separate CLI batch stores | Every directory supplied with `--storage`; these are not automatically part of the native store |
| Files outside these stores | Scenario and run exports, repository-backed suite files, original imported documents, custom tool resources and other external files that you need to run again |

Record the app version and these chosen paths alongside the backup. Save preferences separately with `defaults export com.coryparry.FoundationEvals /private/backup/Intents-preferences.plist`, substituting your private backup path. Preferences include privacy and connection settings and are not included in the Application Support copy.

Credentials are in the login Keychain. These file copies do not migrate judge keys, the MCP bearer credential or other Keychain secrets. Re-enter judge keys and reconnect MCP on the destination Mac using Settings. Do not put credentials in exported suites, jobs or backup notes. Runner trust and identity are workspace-local, but restored device connections may still need fresh pairing. Verify the intended machine and device before trusting a connection.

To restore:

1. Keep all writers stopped. Retain the current directories and preferences as a separate rollback copy, even if they appear empty.
2. Copy each saved directory to an empty staging directory on the destination Mac. Compare relative file lists and file hashes with the backup before installing it. A missing optional directory means that feature had no copied data; do not silently substitute another store.
3. Move the staged directories to their original locations, or explicitly configure the plugin environment and CLI `--storage` paths to their restored locations. Restore each directory as a whole. Do not merge catalogs or audit files from different snapshots. Keep the rollback copy until verification is complete.
4. If you choose to restore preferences, import the saved plist with `defaults import com.coryparry.FoundationEvals /private/backup/Intents-preferences.plist` while Intents is stopped. Review privacy settings and machine-specific paths before resuming work.
5. Start Intents without running evaluations. Check project and suite counts, archived items, a saved run and its trace, human reviews, batch reports and operator drafts. In App Intents, reopen a Siri document/run and inspect a Direct Action evidence directory. Open the plugin with its restored data directory and inspect its saved history separately.
6. Re-enter credentials and reconnect providers, MCP and devices as needed. Historical results remain historical evidence; successful restore does not qualify current signing, Siri, model availability or network access. If verification fails, quit all writers and reinstate the complete rollback directories and preferences before trying again.

## What can leave the Mac

The on-device Foundation Model runs locally. A selected cloud model uses Apple's service. An external AI judge receives evaluation evidence after the app shows a disclosure and receives approval.

Custom local HTTP providers and tools receive the content that they need for a call. These services control further use of that content. Spotlight search can give the selected model matching local file content. Read references and provider settings before you run a suite with sensitive data.

**Settings → Privacy → Share usage statistics** controls optional telemetry. In a configured build, it is on by default. It sends app-open events, app and macOS versions, and a random installation ID. It does not send evaluations, inputs, outputs, results, suite names, files, or screen recordings.

If you turn telemetry off, Intents stops new telemetry and clears queued events. It also resets the local analytics ID. It cannot delete events that the telemetry service already received. If the build has no telemetry settings, the control is unavailable.

## Get updates

If the app includes the updater, use **Intents → Check for Updates…**. Release builds enable automatic update checks by default. If an older build has no update command, download the current disk image. Then replace Intents in Applications. A source build or unsigned development build is different from the signed release.

## Solve common problems

### The Run button is unavailable

1. Point to **Run** to read its readiness reason.
2. For a local run, open the destination menu and select **Run Details** for more information.
3. Make sure that the case has a prompt and the required expected text.
4. Make sure that the model, provider settings, tool schema, and reference import are ready.

### A completed run is absent from history

If **Retry Save** appears, restore storage access. Then select **Retry Save** before you start another run. Otherwise, select the correct project and suite. The sidebar Runs list belongs to the selected suite.

### A score looks wrong

1. Open the run's **Report**.
2. Read the complete response and scoring explanation.
3. Compare the scoring rule with the case's expected text or rubric.

You can correct or reassess an AI judgment. Intents keeps the original judgment.

### Results changed after a suite edit

Saved runs keep their old suite definitions. Run the current suite again. Then compare compatible runs. An old pass is not a current pass.

### A developer app does not appear

1. Open the runner screen in the developer app.
2. Put the device and Intents on a local network that permits discovery.
3. On iPhone or iPad, make sure that local-network permission and Bonjour settings are correct.

### A Mac App Intent check cannot run

Read the [Mac App Intent setup requirements](Mac-App-Intent-tests.md). Confirm the
selected built app has compiled intent metadata, and that Xcode, macOS, signing
team, JSON inputs, and expected results match the runner requirements. A catalog
entry does not prove execution. Retain infrastructure diagnostics when a run fails.

### Codex does not connect

Read [Connect Codex through MCP](Codex-and-MCP.md). Keep Intents open. Restart Codex after setup. A manual client must send the generated credential.

Keep the saved run, the app or model version, and the test report. If the JSON export helps reproduce a result, keep it. Treat absent evidence as absent.

### A review shows Source changed

The saved annotation no longer matches its source evidence. Reinspect the sample in [Review](Review-and-judge-checks.md) and save a current review. Stale evidence cannot support a confirmed pattern or a regression promotion.

### A batch cannot be created or qualified

Read the error or the **Reports** issues in [Batch runs](Production-batches.md). Imported examples need explicit mappings for required critical cases. A required baseline needs approval of its current saved evidence; changed reviews or controls invalidate it. Missing, unscored, or uncertain responses, and missing required cost or latency evidence, cannot qualify just because other responses passed.

### An external judge needs its key again

Re-enter the key in judge settings if it predates endpoint binding or if you changed the provider or endpoint. The app preserves older unbound keys but will not use them automatically. Do not copy keys into worker settings, frozen jobs, or reports.

### A scheduled batch has not started

A polling worker ticks schedules and executes matching jobs. An explicit `intents-evals tick --storage /path/to/store` creates due jobs but still needs a matching worker to execute them. For a native headless worker, use `--production-poll`; the CLI worker uses `--poll`. Keeping the normal app open does not tick schedules, and no background daemon is installed. Inspect the template name, next due time, paused state, remaining runs, worker target, job state and required approval before resuming work. See the [worker and schedule commands](../PRODUCTION_EVALS_GUIDE.md).
