# Data, privacy, updates, and troubleshooting

[Home](Home.md) · [Getting started](Getting-started.md) · [Runs and results](Runs-and-results.md)

## Where Intents saves data

Intents saves projects, suites, imported files, and run history under `~/Library/Application Support/FoundationEvals/`. The batch store is in the `ProductionEvals/` subdirectory. Suite human reviews, judge-check state, drafts, and batch audits are also local. The app does not encrypt these files itself. A run can include prompts, responses, references, tool arguments, tool outputs, transcripts, and traces.

**Export Run as JSON** saves a copy of one run. Read the file before you share it. Intent Lab keeps artifacts and screenshots local by default. Its redacted sharing copy omits them.

Deleting a run removes its saved results and trace. **Start from Scratch** can reset a suite, clear its runs and traces, or do both. The app cannot undo these actions. Before a reset, back up the Application Support data or export the evidence that you need.

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

### Intent Lab says Setup needed

Read the connection messages and **Before you run** list. Make sure that the signed UI-test support, scheme, app, target, destination, and observation keys match. Make sure that the required parts have checks. A compiled support check does not run the scenario.

### Siri says Not observed

Make sure that you use a paired physical iPhone. Read the Siri language, shortcut, fixture reset, final-state observation, and device availability. A direct App Intent pass does not establish Siri success.

### Codex does not connect

Read [Connect Codex through MCP](Codex-and-MCP.md). Keep Intents open. Restart Codex after setup. A manual client must send the generated credential.

Keep the saved run, the app or model version, and the Intent Lab report. If the JSON export helps reproduce a result, keep it. Treat absent evidence as absent.

### A review shows Source changed

The saved annotation no longer matches its source evidence. Reinspect the sample in [Review](Review-and-judge-checks.md) and save a current review. Stale evidence cannot support a confirmed pattern or a regression promotion.

### A batch cannot be created or qualified

Read the error or the **Reports** issues in [Batch runs](Production-batches.md). Imported examples need explicit mappings for required critical cases. A required baseline needs approval of its current saved evidence; changed reviews or controls invalidate it. Missing, unscored, or uncertain responses, and missing required cost or latency evidence, cannot qualify just because other responses passed.

### An external judge needs its key again

Re-enter the key in judge settings if it predates endpoint binding or if you changed the provider or endpoint. The app preserves older unbound keys but will not use them automatically. Do not copy keys into worker settings, frozen jobs, or reports.

### A scheduled batch has not started

Schedules need the running app or an explicitly polling worker. They do not install a background daemon. Inspect the schedule, job state, worker target, and required approval before starting work again.
