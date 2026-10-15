# Foundation Evals for Codex

A standalone local plugin for evaluating Apple's on-device Foundation Models
and inspecting actual session transcripts inside Codex. The Intents app does
not need to be installed or running.

The plugin includes a native Codex manifest with an explicit MCP server and
skill registration, alongside the Agent Plugins package format. It uses
[OpenAI MCP Extensions](https://github.com/openai/mcp-extensions) for sidebar,
chat-tab, and `.afevaltrace` file entrypoints. Hosts that support ordinary MCP
tools but do not support these UI extensions can still run the evaluations.

## Requirements

- An Apple Intelligence compatible Mac running macOS 27 or later.
- Apple Intelligence enabled, with the on-device model downloaded.
- Node.js 22 or later on the Codex runtime's executable path.
- Xcode 27 or newer with the macOS SDK, selected by
  `xcode-select`. The plugin compiles its bundled app evaluation engine locally on the
  first model check or run and caches it in its writable data directory.

Inference uses Apple's local model service. A sandbox that denies access to
that service can report a model-service failure even when availability is
true. The plugin records the actual error instead of reporting a passing run.

## Install from this checkout

From the repository root:

```sh
codex plugin marketplace add .
codex plugin add apple-foundation-evals@apple-foundation-evals-local
```

Start a new Codex chat after installation. Ask to open the evaluation workspace,
or use the plugin's **Evaluation Workspace** sidebar entrypoint when supported.
The thread entrypoint has the same title.
If the entrypoint is missing, restart Codex to refresh installed plugin discovery.

Example requests:

- “Use Foundation Evals to test these prompts against Apple's on-device model.”
- “Create an exact-match suite for these expected answers, then run it.”
- “Compare my last two runs and show the actual session transcripts.”

The repository marketplace points at `plugins/apple-foundation-evals`. For
another local marketplace, copy this complete directory and reference its
path. Repository or ZIP distribution works without `npm install`; the plugin
has no third-party Node runtime dependencies. Public directory submission is a
separate process: current OpenAI guidance requires coordination for local MCP
servers. This source package is for local Codex use, not a hosted web service.

## Evaluation and trace workflow

The workspace ports the app's project overview, sidebar, named case editor,
automatic saving, seven setup pages, results, comparisons and workflow trace
inspector into the MCP Apps HTML surface. The evaluation engine is extracted
from the app, with source hashes and explicit adaptations recorded in
`native/AppEngine/provenance.json`.

- **Cases** supports named prompts, expected answers, conversations, transcript
  restoration/history policies, field checks, case imports and Writing tools.
- **Setup** includes instructions/references, scoring, model sampling, custom
  fixture/loopback HTTP tools, structured schemas, session profiles and
  streaming/prewarm/transcript options. Reference files use the app's real
  PDFKit, UTF-8 and image extraction with its file/count/context limits.
- **Results and traces** preserve the actual app run and sample, workflow spans,
  token usage, timing, field assertions, tool calls, rubric judge evidence and
  Apple transcript. Capturing the full transcript is configurable.
- **Development workflows** support frozen instruction experiments, approved
  baselines, release-policy reports, repeatability analysis, assessment
  selection and separate human correction records.

App scoring supports AI rubric (1–4, every criterion must pass), Exact text
(trimmed outer whitespace), Contains text (case/diacritic insensitive), and
Collect only. Legacy flat suites retain their original exact/contains/none
semantics. OS/model updates can change results; retain run evidence when
comparing changes. Runs share a process lease, and cancellation preserves
completed samples and uses a bounded forced-stop fallback.

The standalone scope is local evals and traces. App Intents/Intent Lab,
external model providers, external judge connections, and companion-device
execution are excluded. Local HTTP tools use validated loopback endpoints.
The macOS 26 legacy runner remains for old flat requests, while the complete
app-format engine and its compilation require macOS/Xcode 27.

Suites, runs, references, baselines, experiments and corrections live under
`~/Library/Application Support/Apple Foundation Evals Codex/`. Use
`FOUNDATION_EVALS_PLUGIN_DATA` to choose a separate store. The plugin needs no
running app, app database or app credentials. MCP tool results requested in a
chat become that chat's context. Exports include prompts, responses and
references, so share them only within the user's requested scope.

## Develop and verify

```sh
cd plugins/apple-foundation-evals
npm ci
npm test
npm run typecheck
npm run test:native
npm run build:ui
FOUNDATION_EVALS_PLUGIN_DATA=/tmp/foundation-evals-preview npm run preview
npm run package
```

The local preview at `http://127.0.0.1:4317` hosts the real embedded UI against
the real stdio server and native runner. Use a temporary data path for manual
checks. Add `?theme=dark` to inspect the dark layout, or
`?theme=dark&themeControls=1` to exercise live host theme notifications.
Stop the preview after testing. `FOUNDATION_EVALS_NATIVE_BINARY` can
select a built runner for integration tests; production normally uses the
source-hashed native cache.

Packaging writes a versioned `dist/apple-foundation-evals-<version>.zip` at the repository
root with an explicit file allowlist. It excludes tests, working notes, cached
binaries, and local data. The offline UI bundle is checked in so installed
repository plugins can open immediately; rebuild it after editing UI source.

The workspace uses React, shadcn/ui (Radix nova), and Tailwind. The static shadcn Tailwind variants are vendored with their MIT licence and SHA-256 provenance; the component-generation CLI is not a dependency. The build embeds
all JavaScript and CSS in `ui/app.html`; users do not need npm or a CDN. Bundled
library licenses are included in `ui/vendor/THIRD-PARTY-NOTICES.txt`.

## Protocol and licenses

`.codex-plugin/plugin.json` explicitly registers `.mcp.json` and `skills/` for
Codex. `plugin.json` and `mcp.json` provide Agent Plugins 1.0 compatibility.
The server name `apple-foundation-evals` avoids collisions with an existing
app-backed `foundation-evals` server. Discovery requests accept standard MCP
request metadata. UI tools declare
`_meta.ui.resourceUri` and `_meta["openai/ui"].entrypoints`, and the resource uses
`text/html;profile=mcp-app`. File access uses opaque host resource URIs.

Plugin source is MIT. The minimal OpenAI MCP app transport is vendored from
`openai/mcp-extensions` under Apache 2.0; its exact revision and license are
preserved in `ui/vendor/`.

## Mac workspace and local feature parity

Version 0.3.0 uses Mac system typography, compact toolbar and segmented controls,
a persistent project sidebar, blue selection states, and labelled vector icons.
The workspace adapts to Codex light/dark appearance and narrow panels. Use the
arrow keys, Home and End in a tab group; use Command-F (Control-F on other hosts)
to focus workspace search. Escape dismisses action menus and the narrow sidebar.

Suite actions include duplication, portable export/import, approved baseline
inspection and deletion. Imported suites reset the Spotlight configuration to
its defaults. Search, Core Spotlight, Mail access, and contact identity are
disabled; imported scopes and requested attributes are cleared. Review and
enable search locally after importing if you want to use it.

Run deletion is available after execution stops;
confirmation dialogs explain what will be removed. Deleting a suite retains
its saved run snapshots. Overview offers a project release report. Compare
supports two to four saved runs; a two-run comparison also shows the app's
compatibility and regression analysis. Live model output remains visible while
later samples are generated when streaming is enabled.

| Evaluation workflow | Plugin support |
|---|---|
| Projects, suites and cases | Create/edit, autosave, search, duplicate, import/export and delete |
| Local model configuration | Sampling, token/tool budgets, prewarming, streaming and transcript capture |
| Case context | Setup turns, transcript restoration, session/model history and reference files |
| Tools and structured output | Fixture/loopback tools, Spotlight, image extraction, schemas and field checks |
| Scoring and evidence | Same-model rubric, exact/contains/collect, assessments, human corrections, traces, timing and token usage |
| Regression workflow | Instruction experiments, baselines, release reports and comparisons of 2–4 runs |
| Other app model providers and external judge connections | Unsupported; the plugin remains an on-device evaluation workspace |

### Sites hosting boundary

Sites can host a stateless HTTP MCP endpoint and its own authenticated plugin.
It cannot execute the Foundation Models service on a visitor's Mac. The current
plugin therefore keeps its MCP transport, evaluation engine and saved evidence
local. Its UI is bundled offline and needs no hosted server.

A future Site could distribute public templates or documentation. Hosted access
to local runs would require an explicitly paired local companion, per-user
request authorization, cancellation and offline handling. Local transcripts and
reference files should stay on the Mac unless their owner explicitly chooses
to share them. This release adds no cloud endpoint or evidence upload.
