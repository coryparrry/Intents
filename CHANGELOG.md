# Changelog

## [1.5.1](https://github.com/coryparrry/Intents/compare/v1.5.0...v1.5.1) (2026-10-23)


### Bug Fixes

* admit production resumes and plugin execution before dispatch ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* **app:** preserve evaluation evidence and enforce execution boundaries ([61e4f74](https://github.com/coryparrry/Intents/commit/61e4f74f1e9a8f6908b576b5c0b200ade1bac58b))
* bind scoring and human corrections to the saved assessment evidence ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* cancel availability workers and check each collection member ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* center navigation on model evaluations and App Intents testing ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* compare compatible experiments and retain unknown usage totals ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* enforce production job budgets, storage bounds and committed progress ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* honor selected scoring policies and preserve bounded trace text ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* **intents:** replace legacy intent testing with native macOS checks ([61e13e3](https://github.com/coryparrry/Intents/commit/61e13e3199f2852ef7dcaed9208def1e8fc089eb))
* isolate hosted test data and pause uncertain batch requests ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* judge model responses against their frozen conversation context ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* keep judge conversation prompts stable across reloads ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* keep saved history current and protect repository links ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* make app testing setup reflect supported targets and readbacks ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* migrate saved legacy reviews and stabilize recovery and window-reopen checks ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* preserve blank captures, profile tool overrides and crash-session correlation ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* preserve confirmation ownership and reject stale workflow writes ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* preserve import ownership and propagate response cancellation ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* preserve imported content and saved feature evidence timestamps ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* preserve saved evidence and honor reassessment scoring ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* preserve unfinished drafts and protect damaged evaluation workspaces ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* prevent dataset metadata collisions and clean failed suite creation ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* recover oversized workspaces while preserving saved evidence ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* **release:** allow installer preflight to inspect draft releases ([a23d809](https://github.com/coryparrry/Intents/commit/a23d809f7db37dfef5ebb671f5302d0adcf812a4))
* **release:** generate the next release proposal after a removed unpublished candidate ([a23d809](https://github.com/coryparrry/Intents/commit/a23d809f7db37dfef5ebb671f5302d0adcf812a4))
* repair MCP lifecycle and standalone plugin recovery and shutdown ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* retain exact review references and selected assessment evidence ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* retain imported prompts and count populated CSV cases ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))
* retain interrupted evaluation results and enforce experiment ownership ([7ce1737](https://github.com/coryparrry/Intents/commit/7ce17378030c6a7ab65d8a8eeb3877971cb34918))
* withhold unpublished workspace runs and preserve measurement evidence ([f9eaf9c](https://github.com/coryparrry/Intents/commit/f9eaf9caef93bb8fc9d0cf9ddd0d480137153bf6))


### Refactoring

* **intents:** remove retired app automation services ([d7fd88d](https://github.com/coryparrry/Intents/commit/d7fd88dafab31561950bf22716abe88ceaf5f1ef))
* **intents:** remove retired app tests and fixtures ([62135a2](https://github.com/coryparrry/Intents/commit/62135a20c205138430b15d9ef400c264a4a6de50))
* **intents:** remove retired automation adapters ([c0100da](https://github.com/coryparrry/Intents/commit/c0100dad9594b9571e5ba873afa46efdfb065899))
* **intents:** remove retired automation contract tests ([847d843](https://github.com/coryparrry/Intents/commit/847d8434396c286342f3c8ce750a244aa6288e8f))
* **intents:** remove retired automation core sources ([6c73f0b](https://github.com/coryparrry/Intents/commit/6c73f0b1c321a5659d8b3e3b8b4a1acceaeebfe5))
* **intents:** remove retired automation models and views ([dfe71b9](https://github.com/coryparrry/Intents/commit/dfe71b98d8a6f9ac54aa1c94b29cb047f53240e8))
* **intents:** remove retired automation platform tests ([e6e61cc](https://github.com/coryparrry/Intents/commit/e6e61cc60e2956faa4afe0d8d0bc94cacfe8b6f5))
* **intents:** remove retired fixtures and recovery docs ([ee33bf3](https://github.com/coryparrry/Intents/commit/ee33bf360f6782bc15dadb48262c1bde4c82f597))


### Maintenance

* **deps-dev:** update standalone plugin Vite tooling to 8.3.4 ([92795be](https://github.com/coryparrry/Intents/commit/92795be2928394f04b5639e21a4fe1db70f98971))
* record the reviewed native core integration boundary ([bd439aa](https://github.com/coryparrry/Intents/commit/bd439aac05a68a51d91443a4d3e311a1156e83d8))

## [1.5.0](https://github.com/coryparrry/Intents/compare/v1.4.0...v1.5.0) (2026-10-20)


### Features

* **automation:** add a native workspace for owned app workflows and saved attempts ([f8de88e](https://github.com/coryparrry/Intents/commit/f8de88e13738fec413cbfa8ea59605d15503de0e))
* **automation:** add controlled Siri state-check preparation with live qualification gates ([f8de88e](https://github.com/coryparrry/Intents/commit/f8de88e13738fec413cbfa8ea59605d15503de0e))
* **automation:** provide a shared cli and reproducible simulator checks ([87f431c](https://github.com/coryparrry/Intents/commit/87f431c7ede5319b72b1e0e681bfeb6674ab0bf7))
* **distribution:** install Intents through Homebrew with release updates ([4a5ac5b](https://github.com/coryparrry/Intents/commit/4a5ac5b8114df7cd6df6ffbdb5496ede69df3871))


### Bug Fixes

* **automation:** await fixture services and registration within approved execution budgets ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* **automation:** compare saved failures against changed source with unchanged checks ([6e7aaa9](https://github.com/coryparrry/Intents/commit/6e7aaa96bc76d8098995446dde707cb24822d86f))
* **automation:** enable reviewed workflows for prepared mac source apps ([6e7aaa9](https://github.com/coryparrry/Intents/commit/6e7aaa96bc76d8098995446dde707cb24822d86f))
* **automation:** explain when a stopped attempt may have dispatched its action ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **automation:** force-stop a simulator test runner that ignores termination during release ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **automation:** honor explicitly selected Xcode during preparation ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* **automation:** preserve prepared capabilities, recovery, and source capture ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* **automation:** recover device ownership after a cancelled App automation run instead of blocking evaluations and Intent Lab ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **automation:** restore device ownership recovery and reliable app selection ([c9972a3](https://github.com/coryparrry/Intents/commit/c9972a3e698be8ed68f904a8af57a8379667437f))
* **automation:** restore typed intent runs across xcode and host updates ([f205bc9](https://github.com/coryparrry/Intents/commit/f205bc9ba6ea1dea4251f438546bdd012365dcd6))
* **automation:** retain terminal intent errors and restore workspace preparation ([b29669d](https://github.com/coryparrry/Intents/commit/b29669de15781f7032b82845881bb0b11cebff80))
* **ci:** enforce selected checks and reduce Mac runner contention ([a782b20](https://github.com/coryparrry/Intents/commit/a782b20b0e4d38578bcd6c18d5f2155858069ce9))
* **ci:** keep live simulator and Mac acceptance outside automatic checks ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **ci:** stabilize regression fixtures and consolidate CI validation jobs ([73dc8ba](https://github.com/coryparrry/Intents/commit/73dc8ba4f3b456f6103e6859c62f209d2c78a0bc))
* **ci:** stabilize simulator readiness and process reuse checks ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* **ci:** support macOS Python versions without os.waitid in the signing helper ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **ci:** wait for fixture registration inside simulator test hosts ([99f2944](https://github.com/coryparrry/Intents/commit/99f294462de90bb7fd2db3ae250c443bb8063f5a))
* confirm runner termination before releasing automation resources ([f03d364](https://github.com/coryparrry/Intents/commit/f03d36497fab8f6b489872bc8fd40fd5dc944fd7))
* **diagnostics:** classify scenario setup failures correctly ([4a7b0fc](https://github.com/coryparrry/Intents/commit/4a7b0fc2ae6429cafa6efd8527d448d1ea1b5608))
* **diagnostics:** report consented native crashes without private content ([4a7b0fc](https://github.com/coryparrry/Intents/commit/4a7b0fc2ae6429cafa6efd8527d448d1ea1b5608))
* **evaluations:** preserve completed outputs and recover failed runner connections ([b29669d](https://github.com/coryparrry/Intents/commit/b29669de15781f7032b82845881bb0b11cebff80))
* **evaluations:** preserve concurrent suite edits and comparable evidence ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* **intent-lab:** accept equivalent no-op preparation and cleanup operations declared by integrations ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **intent-lab:** disable the support check until an integration declaration is bound ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **intent-lab:** let captured evidence be saved from Connect app without rerunning the test ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **intent-lab:** save passing Intent Lab results instead of rejecting them as inconsistent pending evidence ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **intent-lab:** show the UI test failure when a run records no evidence ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **intents:** align generated setup and saved checks with executable evidence contracts ([b29669d](https://github.com/coryparrry/Intents/commit/b29669de15781f7032b82845881bb0b11cebff80))
* **intents:** keep Intent Lab unavailable until its release flag is enabled ([6a1cade](https://github.com/coryparrry/Intents/commit/6a1cade078c3627fcd060d66257fd567cf22bd36))
* **plugin:** recover status polling and report captured evidence accurately ([b29669d](https://github.com/coryparrry/Intents/commit/b29669de15781f7032b82845881bb0b11cebff80))
* **release:** keep release PRs current and include missing changelog categories ([c5fcc17](https://github.com/coryparrry/Intents/commit/c5fcc170f89882f015641f848373b322b436f453))
* **review:** keep review editing controls reachable ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* run mixed ui and app intent workflows in the prepared test host ([f03d364](https://github.com/coryparrry/Intents/commit/f03d36497fab8f6b489872bc8fd40fd5dc944fd7))
* **sdk:** support pinned external developer and intent test consumers ([b29669d](https://github.com/coryparrry/Intents/commit/b29669de15781f7032b82845881bb0b11cebff80))
* **telemetry:** restore session and completed-feature analytics ([4a7b0fc](https://github.com/coryparrry/Intents/commit/4a7b0fc2ae6429cafa6efd8527d448d1ea1b5608))
* **telemetry:** retain active usage and screen counts through diagnostics changes ([4a7b0fc](https://github.com/coryparrry/Intents/commit/4a7b0fc2ae6429cafa6efd8527d448d1ea1b5608))
* **ui:** highlight the latest saved scored run in suite sparklines ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* **ui:** keep recent runs ordered across suites after restart ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* **ui:** restore workspace navigation, tab transitions, and clear saved-run results ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* **ui:** retain recent saved runs, separate suite trends, and preserve completed case failures ([0265653](https://github.com/coryparrry/Intents/commit/0265653283c3bd4e174609f5339d4f237e7b8cf4))
* wait for simulator readiness before controller release checks ([f03d364](https://github.com/coryparrry/Intents/commit/f03d36497fab8f6b489872bc8fd40fd5dc944fd7))
* **workflows:** cancel and join active operations during shutdown ([b29669d](https://github.com/coryparrry/Intents/commit/b29669de15781f7032b82845881bb0b11cebff80))


### Performance

* **ci:** reuse builds and bound CI runner demand ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))


### Documentation

* **release:** explain changelog coverage and maintenance release versions ([c5fcc17](https://github.com/coryparrry/Intents/commit/c5fcc170f89882f015641f848373b322b436f453))
* **site:** clarify downloads and first evaluation ([#73](https://github.com/coryparrry/Intents/issues/73)) ([caada4a](https://github.com/coryparrry/Intents/commit/caada4a65de0ea1ea2ca570680bb89c71bcdf1a3))


### Refactoring

* **automation:** consolidate production workflows on deterministic execution ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))
* remove dead execution paths and obsolete tests ([#137](https://github.com/coryparrry/Intents/issues/137)) ([88663bc](https://github.com/coryparrry/Intents/commit/88663bc1119e1f45cdf399fdb751d622c79c420f))


### Tests

* **automation:** cover qualification evidence verifier ([#76](https://github.com/coryparrry/Intents/issues/76)) ([d1712d7](https://github.com/coryparrry/Intents/commit/d1712d78a78c2ff7abb4982fa31de4781993ecc6))
* **automation:** measure cancellation responsiveness from host exit ([bb43343](https://github.com/coryparrry/Intents/commit/bb43343a37ccd924329300c15657cefbfd859959))
* **intent-lab:** cover executor kill escalation after journal failure and connection deadline ([#104](https://github.com/coryparrry/Intents/issues/104)) ([b17cb76](https://github.com/coryparrry/Intents/commit/b17cb767d336db7e8537ffbfc8ddbae4b8d297ab))
* **mcp:** cover parse validation for attachment, start-run, list-runs and project release tools ([#81](https://github.com/coryparrry/Intents/issues/81)) ([e6a1e29](https://github.com/coryparrry/Intents/commit/e6a1e299424025a04797ba89ff9aa04f26bed510))
* retain meaningful behavioral coverage ([0239141](https://github.com/coryparrry/Intents/commit/0239141f9076779093298391b8677f1770ed511b))


### Continuous Integration

* **release:** require curated release notes without restarting code checks ([07a2cac](https://github.com/coryparrry/Intents/commit/07a2cac4afee50669aa823d1886cee272b0fbb4b))

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
