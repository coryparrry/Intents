# Changelog

## [1.5.0](https://github.com/coryparrry/Intents/compare/v1.4.0...v1.5.0) (2026-10-10)


### Features

* **automation:** add a native workspace for owned app workflows and saved attempts ([f8de88e](https://github.com/coryparrry/Intents/commit/f8de88e13738fec413cbfa8ea59605d15503de0e))
* **automation:** add controlled Siri state-check preparation with live qualification gates ([f8de88e](https://github.com/coryparrry/Intents/commit/f8de88e13738fec413cbfa8ea59605d15503de0e))
* **distribution:** install Intents through Homebrew with release updates ([4a5ac5b](https://github.com/coryparrry/Intents/commit/4a5ac5b8114df7cd6df6ffbdb5496ede69df3871))


### Bug Fixes

* **release:** keep release PRs current and include missing changelog categories ([c5fcc17](https://github.com/coryparrry/Intents/commit/c5fcc170f89882f015641f848373b322b436f453))
* **ui:** highlight the latest saved scored run in suite sparklines ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* **ui:** keep recent runs ordered across suites after restart ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* **ui:** restore workspace navigation, tab transitions, and clear saved-run results ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* **ui:** retain recent saved runs, separate suite trends, and preserve completed case failures ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))


### Documentation

* **release:** explain changelog coverage and maintenance release versions ([c5fcc17](https://github.com/coryparrry/Intents/commit/c5fcc170f89882f015641f848373b322b436f453))
* **site:** clarify downloads and first evaluation ([#73](https://github.com/coryparrry/Intents/issues/73)) ([caada4a](https://github.com/coryparrry/Intents/commit/caada4a65de0ea1ea2ca570680bb89c71bcdf1a3))


### Tests

* **automation:** cover qualification evidence verifier ([#76](https://github.com/coryparrry/Intents/issues/76)) ([d1712d7](https://github.com/coryparrry/Intents/commit/d1712d78a78c2ff7abb4982fa31de4781993ecc6))
* **intent-lab:** cover executor kill escalation after journal failure and connection deadline ([#104](https://github.com/coryparrry/Intents/issues/104)) ([b17cb76](https://github.com/coryparrry/Intents/commit/b17cb767d336db7e8537ffbfc8ddbae4b8d297ab))
* **mcp:** cover parse validation for attachment, start-run, list-runs and project release tools ([#81](https://github.com/coryparrry/Intents/issues/81)) ([e6a1e29](https://github.com/coryparrry/Intents/commit/e6a1e299424025a04797ba89ff9aa04f26bed510))

## [1.4.0](https://github.com/coryparrry/Intents/compare/v1.3.0...v1.4.0) (2026-10-03)


### Features

* automate Siri route checks with an XCTest-only runner ([8d1b0d8](https://github.com/coryparrry/Intents/commit/8d1b0d82acde907e3084aad833eca202370df709))
* **brand:** rename Foundation Evals to Intents across the app and release experience ([27741da](https://github.com/coryparrry/Intents/commit/27741dac23b71a6d7815dbec8a659ba02d13a2c4))
* compare stable Intent Lab requirements across app rebuilds ([a760d1f](https://github.com/coryparrry/Intents/commit/a760d1fcf6fd4767dac6b8117fa1ab00ad75345b))
* **evals:** run resumable batches and control evaluations through MCP ([5008e16](https://github.com/coryparrry/Intents/commit/5008e167495ef18b5648576fa5a4876fcdcbd22c))
* guide connected app checks through the current Intent Lab interface ([c28dd28](https://github.com/coryparrry/Intents/commit/c28dd28e1cb2d6b1570a96683081cc7a409b4503))
* **intent-lab:** add reusable App Intents test integrations ([35c647c](https://github.com/coryparrry/Intents/commit/35c647c2d07979ecb98dada316939b7aca6cbfd8))
* **intent-lab:** add scenario evaluation and project release reporting ([9e2c318](https://github.com/coryparrry/Intents/commit/9e2c3186ab01b565bb5b0b2ec8ba8ea7a894aa31))
* **intent-lab:** guide app checks and show observed route outcomes ([b4c0a7f](https://github.com/coryparrry/Intents/commit/b4c0a7f38501813cf8fe8098c64cb8a137f89a4b))
* **intent-lab:** keep developer checks comparable across app fixes and routes ([b69d7ce](https://github.com/coryparrry/Intents/commit/b69d7ce37efee3c8f2eabb9028688c9fe59a7555))
* **intent-lab:** retain regression collections and scoped reruns ([b4c0a7f](https://github.com/coryparrry/Intents/commit/b4c0a7f38501813cf8fe8098c64cb8a137f89a4b))
* **intent-lab:** verify saved evidence offline against trusted requirements ([b69d7ce](https://github.com/coryparrry/Intents/commit/b69d7ce37efee3c8f2eabb9028688c9fe59a7555))
* review saved evaluation outputs, track failure patterns, and create verified regression cases ([a4e593d](https://github.com/coryparrry/Intents/commit/a4e593d6eb2d0e69e515fd4f4649b13ea4983c7b))
* **site:** add an interactive showcase with recorded Intents app examples ([2477e15](https://github.com/coryparrry/Intents/commit/2477e157ce0a5a8b57cc905d33b0ab868c92a261))
* **ui:** redesign the workspace with native toolbar navigation and a unified visual style ([5d2b98e](https://github.com/coryparrry/Intents/commit/5d2b98e92a1f7dd28c5a8a9d48a13d45e3cb61dc))


### Bug Fixes

* **brand:** restore the established Intents social preview layout ([b60b097](https://github.com/coryparrry/Intents/commit/b60b097d9489160e9148928f7115166242138453))
* **evals:** bind judge credentials and require coherent approved release evidence ([5008e16](https://github.com/coryparrry/Intents/commit/5008e167495ef18b5648576fa5a4876fcdcbd22c))
* **intent-lab:** reject incomplete scenario release evidence ([9e2c318](https://github.com/coryparrry/Intents/commit/9e2c3186ab01b565bb5b0b2ec8ba8ea7a894aa31))
* **intent-lab:** select Siri choices with symbol-prefixed app attribution ([9e2c318](https://github.com/coryparrry/Intents/commit/9e2c3186ab01b565bb5b0b2ec8ba8ea7a894aa31))
* keep CLI credentials explicit for custom endpoints and reject redirects ([301ac1a](https://github.com/coryparrry/Intents/commit/301ac1a0ac89e14f48a8b9ffd51db96bbdc75eb8))
* preserve suite decisions and history across repository and recovery failures ([301ac1a](https://github.com/coryparrry/Intents/commit/301ac1a0ac89e14f48a8b9ffd51db96bbdc75eb8))
* reject DTD-bearing project previews before XML entity expansion ([301ac1a](https://github.com/coryparrry/Intents/commit/301ac1a0ac89e14f48a8b9ffd51db96bbdc75eb8))
* **site:** keep copy feedback with the current response ([2477e15](https://github.com/coryparrry/Intents/commit/2477e157ce0a5a8b57cc905d33b0ab868c92a261))
* **site:** stop active transitions when motion is paused ([2477e15](https://github.com/coryparrry/Intents/commit/2477e157ce0a5a8b57cc905d33b0ab868c92a261))
* **ui:** explain evaluation controls, comparison coverage, and workflow timing ([3947e78](https://github.com/coryparrry/Intents/commit/3947e785b975e3b3d45b58f6ef65f6da5b7cc5af))
* verify executed actions in intent lab results ([890ab6b](https://github.com/coryparrry/Intents/commit/890ab6b32ca1fd4c00647547140173e577d48b49))
* verify native Mac bundle resources and product fingerprints consistently ([301ac1a](https://github.com/coryparrry/Intents/commit/301ac1a0ac89e14f48a8b9ffd51db96bbdc75eb8))

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
