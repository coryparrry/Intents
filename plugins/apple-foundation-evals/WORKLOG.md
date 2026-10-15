# Plugin iteration — 4 October 2026

- Outcome: make the standalone Codex evaluation workspace feel native to Mac and expose ordinary local evaluation actions.
- Recovered source from installed 0.2.1 cache; original 7de5 worktree is missing. App checkout has unrelated dirty UI work; preserve it.
- Keep the on-device model engine local. Sites MCP skill confirms a stateless hosted HTTP endpoint is supported; hosting does not run a user’s Mac model service. No hosted deployment planned for this local UI iteration.
- Parity audit: cases/setup/tools/results/experiments/baselines already implemented. Remote providers and external judge connections are unsupported by the local-only backend.
- Work in progress: fix selection contrast, Mac chrome/icons/controls, keyboard tabs/sidebar, suite/run management and 2–4 run comparison. Verify built offline artifact, regression tests and real IAB preview.

- Completed: recovered editable plugin plus `.agents/plugins/marketplace.json`; version 0.3.0 installed through Codex CLI and marketplace path repaired. Installed source matches recovered checkout at installation.
- Verification: 92 JavaScript/backend/package tests passed; final offline rebuild and 3 packaging tests passed after final layout/accessibility edits. Independent Sol 6.1 review reported no material findings (17 targeted tests).
- Actual IAB flows: light/dark case editor, keyboard End → Setup with focus retained, suite duplication, baseline empty-state inspection, workflow/report evidence, four-run comparison, narrow 430×800 sidebar/comparison. Fixed selected hover contrast and narrow toolbar/header overflow. Desktop viewport 1280×720.
- Actual on-device evidence: starter suite copy completed 3/3 passed; four sequential one-case exact-match runs completed and compared with real saved responses. Matching compiled runner reused by source hash; no Xcode build or simulator launch required.
- Console: one pre-navigation browser MutationObserver error appeared; plugin contains no MutationObserver call, and affected flows completed. No claim of a fully clean host console.
- Limits: this verifies the real MCP preview and installed payload, not refreshed Codex sidebar rendering. Start a new chat or restart Codex for discovery. Remote providers/external judges remain unsupported; no Sites deployment, cloud upload, Vision/Spotlight verification, commit, or PR.
- Source changes are limited to recovered plugin and marketplace files; unrelated dirty app files preserved. Temporary test data is under /tmp/intents-plugin-ui-20261004.
- Final read-only project release report also opened successfully; it correctly reports no required suites in the isolated preview project. Temporary browser tab closed and viewport override reset.

## UI correction after rejection

- User rejected 0.3.0 appearance. Current outcome is a structural UI redesign, not further colour/radius adjustments.
- Direction: compact Mac workbench; integrated case list/editor/inspector, restrained chrome and typography, no oversized overview ring/cards. Preserve evaluation features.
- Optional design-reference question sent; default is Xcode-style workbench while waiting.

## Structural redesign in progress

- Direction confirmed for implementation: native workbench anatomy, compact document tabs, integrated list/editor/inspector and suite table. Existing model execution and storage remain unchanged.

## Structural redesign completed — 0.4.0

- Rebuilt Cases as continuous list/editor/inspector panes; flat document tabs and compact toolbar/header. Overview is a suite table with compact assessment counts; Results has an integrated trend and run list.
- Actual IAB inspection: 1280×720 light/dark, 820×760 pane width, 430×800 narrow view; Setup navigation, Writing Tools → Rewrite dialog → Discard, conversation setup disclosure, This Mac dialog, saved Workflow trace and Report.
- Fixed observed responsive case-list stretching, old tab margin specificity, hidden narrow model-status action, and trend bars exceeding the compact chart.
- Verification: 93 JavaScript/backend/package tests passed. Following final chart CSS fix, all 3 packaging checks passed again. Source, installed 0.4.0, and ZIP agree for offline UI, manifests and server version.
- Independent Sol review: one material narrow model-status access finding, fixed and confirmed resolved; no other material findings. No model/storage changes in this revision. Native app dirty files remain preserved.
- Installed 0.4.0 through Codex CLI. Screenshots show the actual MCP local preview; refreshed sidebar rendering in a new Codex chat remains unverified. Full remote-provider/external-judge parity is still outside the current local-only backend.

## Library migration after second rejection

- Current outcome: replace hand-built UI with official shadcn/Radix components, using React and Tailwind. User explicitly requested libraries.
- Sidebar, Overview, Cases, tabs, menus, model/workflow dialogs now use installed library components. Advanced setup/comparison/evidence renderers keep existing behavior inside an isolated DOM/CSS region.
- Vite produces one offline HTML payload; no runtime CDN or npm installation required for plugin users. Added typechecking and DOM integration tests for editing, navigation, and dialog lifecycle.
- Actual preview is rendering; verification and independent regression review underway. Do not claim this candidate installed yet.

## shadcn migration completed — 0.5.0

- Installed official shadcn Radix nova source with React/Tailwind and Lucide icons. Core navigation, menus, dialogs, overview, case forms, checks and conversation controls use library components. Advanced setup/comparison/report renderers remain in isolated legacy DOM with library theme tokens.
- Verified 96 JavaScript/backend/package/DOM integration tests and TypeScript. Final offline rebuild/package checks passed 3/3 after the breadcrumb adjustment. Fixed inline string-replacement corruption and Tailwind scanning its generated output; packaged script syntax and deterministic regeneration are checked.
- Independent Sol review found dialog keyboard focus loss; restored focus to the opener (or current equivalent) and confirmed in DOM integration plus browser. No remaining material findings.
- Real MCP preview: light/dark, 1280×720 and 1280×860, 820×760 and 430×800. Verified model status, focus on close, Cases ↔ Setup, narrow sidebar, and a real local one-case run returning apple and passing. Trace and Report showed recorded evidence.
- 0.5.0 installed. Offline HTML, manifests, server catalog and third-party license notices match source, installed cache and ZIP. Development dependencies excluded from installation and restored in workspace.
- Screenshots are actual local MCP preview; rendering of a newly opened installed Codex workspace remains unverified. Native model/storage sources and existing app edits preserved. External provider/judge parity remains unsupported by the existing local-only backend.
- Browser error log retains the initial pre-fix syntax error and host MutationObserver error; no new error appeared after corrected reload and flows. Do not claim an entirely clean historical console.
