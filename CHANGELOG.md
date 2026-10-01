# Changelog

## [1.4.0](https://github.com/coryparrry/Intents/compare/v1.3.0...v1.4.0) (2026-09-20)


### Features

* **brand:** rename Foundation Evals to Intents across the app and release experience ([27741da](https://github.com/coryparrry/Intents/commit/27741dac23b71a6d7815dbec8a659ba02d13a2c4))


### Bug Fixes

* **brand:** restore the established Intents social preview layout ([b60b097](https://github.com/coryparrry/Intents/commit/b60b097d9489160e9148928f7115166242138453))

## [1.3.0](https://github.com/coryparrry/Intents/compare/v1.2.0...v1.3.0) (2026-09-19)


### Features

* **cases:** add starter packs and structured case import ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))
* **comparison:** identify device and OS versions when comparing saved runs ([a25beb4](https://github.com/coryparrry/Intents/commit/a25beb48eb102916c6ca8f38769bb0a3ce95d6b4))
* **evals:** update evaluation workflow implementation ([1071c70](https://github.com/coryparrry/Intents/commit/1071c70d9815b859bdb347f0c90c2b34628cd4db))
* **evidence:** preserve run provenance and explicit human approvals ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))
* **experiments:** compare controlled instruction variants ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))
* **integration:** evaluate registered Swift app features on paired Apple devices ([a25beb4](https://github.com/coryparrry/Intents/commit/a25beb48eb102916c6ca8f38769bb0a3ce95d6b4))
* **integration:** run repository and application checks through MCP and CLI ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))
* **judging:** configure independent judges and reassess saved responses ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))
* **judging:** harden compatible judge connections with attempt traces and extended timeouts ([1071c70](https://github.com/coryparrry/Intents/commit/1071c70d9815b859bdb347f0c90c2b34628cd4db))
* **releases:** fail closed on stale or incomplete project evidence ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))
* **runs:** show scoring attribution and model identity in run history ([1071c70](https://github.com/coryparrry/Intents/commit/1071c70d9815b859bdb347f0c90c2b34628cd4db))
* **workspace:** inspect suite health and recent evaluation runs in a project dashboard ([a25beb4](https://github.com/coryparrry/Intents/commit/a25beb48eb102916c6ca8f38769bb0a3ce95d6b4))
* **workspace:** organize evaluations into projects and saved suites ([161d1fb](https://github.com/coryparrry/Intents/commit/161d1fb0f543e004270c615a468a90116be26a7a))


### Bug Fixes

* **assessments:** keep incomplete reassessments separate from original passing scores ([6afcfd3](https://github.com/coryparrry/Intents/commit/6afcfd332d1f79ae0720b73efcac84cc80cc835c))
* **ci:** keep main push checks from being cancelled ([ab5be0f](https://github.com/coryparrry/Intents/commit/ab5be0fe5056f0d933ee835ddf85447135bb52cc))
* **editor:** fallback on-device context size and harden case pickers ([1071c70](https://github.com/coryparrry/Intents/commit/1071c70d9815b859bdb347f0c90c2b34628cd4db))
* **editor:** preserve prompt edits when keeping a stale rewrite ([8dc3628](https://github.com/coryparrry/Intents/commit/8dc3628ce5f932e2a7ad69bfeb983098adb6e1b7))
* **editor:** simplify suite navigation and keep prompts with expected answers ([a25beb4](https://github.com/coryparrry/Intents/commit/a25beb48eb102916c6ca8f38769bb0a3ce95d6b4))
* **evaluation:** stop cancelled or unavailable judge work without duplicate requests ([a106300](https://github.com/coryparrry/Intents/commit/a1063002fd25bdd1bd85e7e548ba98d3a9d14171))
* **judge:** reject failed completions and preserve authentic request evidence ([c1e1d25](https://github.com/coryparrry/Intents/commit/c1e1d25adf05b99754d1903f82e91a0b7bebb322))
* **judge:** tolerate malformed optional streaming usage without retrying valid verdicts ([c1e1d25](https://github.com/coryparrry/Intents/commit/c1e1d25adf05b99754d1903f82e91a0b7bebb322))
* **judging:** restore compatible JSON requests and actionable endpoint errors ([a106300](https://github.com/coryparrry/Intents/commit/a1063002fd25bdd1bd85e7e548ba98d3a9d14171))
* **mcp:** preserve hidden suite policy and tokenizer state across automation updates ([ab5be0f](https://github.com/coryparrry/Intents/commit/ab5be0fe5056f0d933ee835ddf85447135bb52cc))
* **models:** reload Core AI resources when model files change ([a106300](https://github.com/coryparrry/Intents/commit/a1063002fd25bdd1bd85e7e548ba98d3a9d14171))
* **release:** reject ambiguous or semantically inconsistent release overrides ([f10abc3](https://github.com/coryparrry/Intents/commit/f10abc3343697e7145936c16394893d1594a5c47))
* **release:** require curated notes for squash-merged features and fixes ([f10abc3](https://github.com/coryparrry/Intents/commit/f10abc3343697e7145936c16394893d1594a5c47))
* **suite:** keep git definitions portable and commit repository links atomically ([ab5be0f](https://github.com/coryparrry/Intents/commit/ab5be0fe5056f0d933ee835ddf85447135bb52cc))
* **tests:** align migration fixture timestamps with canonical JSON precision ([750f56a](https://github.com/coryparrry/Intents/commit/750f56a5c75c4384216dec8e69366f794bce843c))
* **tests:** emit correctly framed SSE events in the judge fixture ([c1e1d25](https://github.com/coryparrry/Intents/commit/c1e1d25adf05b99754d1903f82e91a0b7bebb322))
* **tests:** synchronize quick-action completion without polling deadlines ([8dc3628](https://github.com/coryparrry/Intents/commit/8dc3628ce5f932e2a7ad69bfeb983098adb6e1b7))
* **tools:** bound workflow evidence for rejected shared reference-tool admission ([bbbbcda](https://github.com/coryparrry/Intents/commit/bbbbcdae4d9ede98ef42c0238d79afa4300e91a4))
* **workspace:** load replacement workspaces before atomically archiving the current selection ([ab5be0f](https://github.com/coryparrry/Intents/commit/ab5be0fe5056f0d933ee835ddf85447135bb52cc))
* **workspace:** preserve valid catalogs and fail closed across recovery mutations ([ab5be0f](https://github.com/coryparrry/Intents/commit/ab5be0fe5056f0d933ee835ddf85447135bb52cc))
* **workspace:** prevent legacy recovery from restoring revoked approval authority ([750f56a](https://github.com/coryparrry/Intents/commit/750f56a5c75c4384216dec8e69366f794bce843c))
* **workspace:** reject unsafe attachments and preserve unreadable evaluation state ([a106300](https://github.com/coryparrry/Intents/commit/a1063002fd25bdd1bd85e7e548ba98d3a9d14171))

## [1.2.0](https://github.com/coryparrry/Intents/compare/v1.1.1...v1.2.0) (2026-09-08)


### Features

* **traces:** add a native workflow waterfall and inspector ([#19](https://github.com/coryparrry/Intents/issues/19)) ([bf350d2](https://github.com/coryparrry/Intents/commit/bf350d2afcde6d1cb695a35cf24653e4f057e6c7))

## [1.1.1](https://github.com/coryparrry/Intents/compare/v1.1.0...v1.1.1) (2026-09-06)


### Bug Fixes

* **app:** add signed updates and private launch statistics ([#16](https://github.com/coryparrry/Intents/issues/16)) ([2353a78](https://github.com/coryparrry/Intents/commit/2353a78657776a4f1df0026ee90d0b18330f03d4))
* **updates:** enable automatic Sparkle updates ([#17](https://github.com/coryparrry/Intents/issues/17)) ([b0a5b70](https://github.com/coryparrry/Intents/commit/b0a5b709f827d4597ca71e5499ce95133b3222c2))

## [1.1.0](https://github.com/coryparrry/Intents/compare/v1.0.0...v1.1.0) (2026-09-06)


### Features

* **release:** add manually controlled signed GitHub releases ([#8](https://github.com/coryparrry/Intents/issues/8)) ([843e3e1](https://github.com/coryparrry/Intents/commit/843e3e1f6afef2fd5c6cacfa2c3a1f1ca91a0866))


### Bug Fixes

* **docs:** make the README artwork a full-width banner ([#5](https://github.com/coryparrry/Intents/issues/5)) ([cfff5cc](https://github.com/coryparrry/Intents/commit/cfff5ccfbaf9e890c18dd7b0040b10c9541453d2))
* **evals:** address concurrency warnings and refresh lifecycle checks ([#11](https://github.com/coryparrry/Intents/issues/11)) ([4a86219](https://github.com/coryparrry/Intents/commit/4a86219328c7827a3afc539e73daea37aabf1a52))
* **release:** automate release PRs on main merges ([#12](https://github.com/coryparrry/Intents/issues/12)) ([a4c856b](https://github.com/coryparrry/Intents/commit/a4c856bd5649e126bc61c8a0bac6d9970c870277))
* **release:** publish releases only after verified DMG upload ([#14](https://github.com/coryparrry/Intents/issues/14)) ([014d9e5](https://github.com/coryparrry/Intents/commit/014d9e58e8f3ec8757b52c06fb72e789ce89794a))
* strengthen CI and add repository branding ([#3](https://github.com/coryparrry/Intents/issues/3)) ([73f2d8c](https://github.com/coryparrry/Intents/commit/73f2d8c7bb7d536cb80d54d4be45d3fdfe2439dc))
* **ui:** reshape the evaluation workbench around summary cards ([#6](https://github.com/coryparrry/Intents/issues/6)) ([d5469ea](https://github.com/coryparrry/Intents/commit/d5469eaaf7067710914bc2a51b290ca4441d6dfc))
