# Connect Codex through MCP

[Home](Home.md) · [Data and troubleshooting](Data-and-troubleshooting.md)

Intents has a local MCP connector for Codex. Through this connector, Codex can manage projects and suites, start runs, review saved evidence, control batches, and work with developer runners and Intent Lab. Codex uses the same local workspace as the app.

## Connect

1. Open **Intents → Settings → MCP Connector**.
2. Select **Connect to Codex**.
3. Restart Codex so it reads the new connector settings.
4. Keep Intents open while you use the connection.
5. Return to **MCP Connector**. Make sure that its **Status** is running.

The button can later show **Update Codex**, **Reconnect to Codex**, or **Repair Connection**. Its label depends on the connection state.

Intents adds a managed block to Codex settings. It starts the connector automatically while the app is open. The connector accepts connections at `127.0.0.1` on this Mac. Intents creates a bearer credential and stores it in the login Keychain. It also sets Codex to send this credential.

The endpoint alone cannot authenticate a client. An authenticated local client can read or change evaluation data. Keep the managed settings and credential private.

The **Advanced** section has **Copy Endpoint** and **Copy Manual Configuration** for manual setup. **Remove from Codex** removes the managed block. Restart Codex after removal. The installer keeps unrelated Codex MCP settings.

## Use the connection

The connector gives an agent its workflow guide when the connection starts. The agent can read workspace state, change evaluation definitions, start or cancel runs, and read saved evidence.

Ask the agent to cite saved run evidence in its result. For a baseline or release check, read the run in Intents. See [Runs and results](Runs-and-results.md).

The saved-report tools remain read-only. Advanced Intent Lab actions also support authored requirements, project setup, reviewed installation previews, execution, reruns, and recovery through the same coordinator as the app. Discover their exact schema rather than assuming every client exposes them by default. Build trust, pairing, installation, evidence transfer, quarantine recovery, and other decisions still need the required operator approval and readiness checks. Physical Siri qualification requires actual device evidence.

Read `eval_get_state` and `eval_workspace_state` first. The compact default catalog exposes common controls; `eval_find_actions` searches advanced operations and `eval_describe_action` loads one exact schema. Invoke reads through `eval_read_action` and mutations through `eval_apply_action`, using the revisions, confirmation fields, and caller-generated operation IDs required by that schema. Retry an identical operation ID and payload after a lost reply; inspect interrupted operations instead of automatically replaying them.

See the [MCP control guide](https://github.com/coryparrry/Intents/blob/main/docs/MCP_CONTROL_GUIDE.md) for batch uploads, review proposals, safe retries, and runner/Intent Lab controls. Review agent suggestions in [Review](Review-and-judge-checks.md); a proposal alone is not a human judgment.

For a stable execution, call `eval_get_scenario_execution_report` with its saved `executionID` UUID, or use `script/foundation-evals scenario-execution-report --execution-id <uuid>`. The report uses the same frozen requirement, retained assessment selection and frozen judge policy as the GUI and exported offline evidence checks. Missing or corrupt evidence cannot qualify. `eval_get_scenario_report` and `scenario-report --run-id` retain their existing child-run meaning.

For Debug verification with a separate store, launch the app with `--evaluation-storage <absolute-path> --mcp-use-existing-credential`. This explicit mode reads an already-existing local connector credential and starts the localhost transport without requiring an installed Codex entry. It cannot create or remove credentials, install or update Codex settings, or copy credential-bearing configuration. Missing or invalid credentials leave the connector stopped. Hosted tests and ordinary isolated launches cannot read the user's credential. `--disable-mcp-autostart` still prevents automatic startup.

## Solve connection problems

| Symptom | Action |
|---|---|
| Codex does not list Intents | Keep Intents open. Read **MCP Connector → Status**. Select **Repair Connection** if it appears. Then restart Codex. |
| A manual client receives `401 Unauthorized` | Use **Connect to Codex** or **Copy Manual Configuration**. The endpoint alone does not include the required credential. |
| A suite run is unavailable | Open the suite in Intents. Read the Run readiness reason. MCP uses the same run limits as the app. |

The bundled `script/foundation-evals` CLI reads the default local connector credential from the login Keychain and sends the Authorization header. macOS may ask you to allow the CLI to read that item. Keep the connector running when requesting saved reports.

For custom endpoints or automation, supply `--credential-file <path>` using a regular UTF-8 token file owned by you with owner-only permissions (`chmod 600`), or use the existing `FOUNDATION_EVALS_MCP_CREDENTIAL` environment option. The file takes precedence. All three commands support the same credential options. Plain HTTP is limited to loopback endpoints; remote endpoints require HTTPS and an explicitly supplied credential. Redirects are rejected. Credentials are never printed.
