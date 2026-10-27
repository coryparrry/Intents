# Connect Codex or Claude Code to Intents over MCP

Canonical page: https://intents-workbench.coryparry.chatgpt.site/guides/intents-mcp-coding-agents

## Short answer

Intents exposes authenticated MCP on localhost while its connector is running. Codex has a built-in setup button in Intents Settings; Claude Code can use a manual HTTP configuration with the same endpoint and bearer credential. Keep Intents open, protect the credential, and verify the connection before asking an agent to change suites or start runs.

## Connect Codex with the built-in setup

1. Open **Intents → Settings → MCP Connector**.
2. Select **Connect to Codex**. Depending on its state, the button may instead show **Update Codex**, **Reconnect to Codex**, or **Repair Connection**.
3. Restart Codex so it reloads its settings. Keep Intents open.
4. Return to **MCP Connector** and check that **Status** is running.

Intents generates a bearer credential, keeps it in the login Keychain, and configures Codex to send it. The managed setup preserves unrelated MCP settings.

## Configure Claude Code manually

Use **Advanced → Copy Endpoint** and **Copy Manual Configuration** in the connector settings. Keep the connector running. The documented endpoint is `http://127.0.0.1:17873/mcp`; an endpoint alone does not authenticate a client.

The copied manual configuration is a Codex TOML snippet. In its `http_headers` entry, find `Authorization = "Bearer …"`. The credential is only the value after `Bearer `, without the surrounding quotes; do not include the word Bearer in the environment variable. Make that credential available as `INTENTS_MCP_TOKEN` to the shell that launches Claude Code, using your local secret-management method. Do not put a real credential in this example, a repository, or shell history. The following single-quoted JSON preserves the environment placeholder for Claude Code:

```sh
claude mcp add-json intents '{"type":"http","url":"http://127.0.0.1:17873/mcp","headers":{"Authorization":"Bearer ${INTENTS_MCP_TOKEN}"}}'
```

Restart Claude Code from that environment and use `/mcp` to inspect the connection. This uses Claude Code’s documented HTTP transport and environment interpolation; Intents’ automatic installer configures Codex only. This guide does not claim a live Claude Code session was tested.

## Start by reading evidence

Ask the agent to read `eval_get_state` and `eval_workspace_state`, then describe a saved run. For advanced operations, discover the current schema with `eval_find_actions` and `eval_describe_action`. Do not guess action parameters. Authenticated clients can change evaluation data; the revisions, confirmation fields, and operation IDs in each schema matter.

Ask for saved run identifiers and inspect the result in Intents. An agent proposal is not a human review verdict. Use the [MCP control guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/MCP_CONTROL_GUIDE.md) for mutation and retry semantics.

## Troubleshoot the connection

If no tools appear, confirm the connector is running, restart the client, and confirm the endpoint and bearer configuration. Keep credentials out of shared logs. **Remove from Codex** removes Intents’ managed block; restart Codex afterward. Do not expose this localhost connector publicly.

Sources: [released Intents MCP setup](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md) and [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).

## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 26 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)
