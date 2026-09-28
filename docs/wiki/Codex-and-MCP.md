# Connect Codex through MCP

[Home](Home.md) · [Data and troubleshooting](Data-and-troubleshooting.md)

Intents has a local MCP connector for Codex. Through this connector, Codex can edit suites, start runs, and read saved results and traces. Codex uses the same local workspace as the app.

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

Intent Lab report tools only read saved reports. They cannot trust an Xcode project, run device tests, clear a device quarantine, or change a fixture. Do these tasks in Intents and the app's test environment.

## Solve connection problems

| Symptom | Action |
|---|---|
| Codex does not list Intents | Keep Intents open. Read **MCP Connector → Status**. Select **Repair Connection** if it appears. Then restart Codex. |
| A manual client receives `401 Unauthorized` | Use **Connect to Codex** or **Copy Manual Configuration**. The endpoint alone does not include the required credential. |
| A suite run is unavailable | Open the suite in Intents. Read the Run readiness reason. MCP uses the same run limits as the app. |

The bundled `script/foundation-evals` CLI does not send the required Authorization header. Do not use its exit status as release evidence. Use the in-app report or an authenticated MCP client until this integration changes.
