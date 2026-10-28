> Remediation complete for all 34 original findings, plus one compatible development-dependency correction (A01). The original triage was 26 Fix now and 8 Fix if cheap; including A01, the complete inventory is 35 items: 26 Fix now, 9 Fix if cheap, 0 Defer, 0 Ignore. GitHub CI and Plugin validation succeeded on source commit `8e3b6f48d058d08e96de89b468c301fe0150f1bc`; all 38 hosted UI tests passed. The original audit below preserves pre-fix evidence, followed by the implementation and validation ledger.

# Intents prelaunch code review — 28 October 2026

**Original audit recommendation: fix R01 and M01 before launch.** Both could make authoritative state say something the operator did not approve: a failed exact-match release check could pass under a different assessment contract, and an MCP approval could persist a different pending disclosure policy or destination. No actual external transmission or published broken release was demonstrated. Their fixes and regression results are recorded in the remediation appendix.

**Original audit: 34 actionable findings, comprising 2 P1, 28 P2, and 4 P3.** The audit was a source review with local tests and isolated reproductions, not a launch certification. It made no production-code edits. The later authorized remediation is documented separately below.

## Snapshot, method, and boundaries

- Source: `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`, branch `main`, initially clean, at `/Users/coryparry/Developer/Projects/Intents`.
- Scope: current app source, canonical shared AppEngine, ProductionEvals package/CLI, developer runner and Mac App Intent libraries, standalone plugin, website, telemetry, CI and release scripts. Other worktrees and unpublished changes are outside this snapshot.
- Host: macOS 27.2, Xcode 27.1, Apple Swift 6.4, Node 26.11.1, Python 3.15.0.
- Nine independently owned subsystem audits plus the coordinating persistence/UI/privacy/website pass. Several bounded subreviews covered distinct source contracts. Every subsystem completed a normal execution/caller/test pass and a second boundary/failure/adversarial pass. Material candidates were challenged against guards and tests; the disclosure findings also received a separate independent adjudication.
- Runtime probes use synthetic temporary data. Framework executor, exact-source, linked-module, JSDOM, and full application integration evidence are distinguished below. No private saved evaluations or credentials were used.
- P1 means fix before launch because important result/approval authority is wrong. P2 means a concrete, actionable correctness, reliability, performance, or verification issue. P3 means a bounded lower-impact or exceptional-input issue. Confidence is independent of priority.
- Final priorities are those in the index and detail headings. During consolidation, malformed judge-envelope repair, extreme numeric overflow, and corrupted-dataset reuse were reduced to P3 because their practical impact/preconditions are narrower than ordinary workflow defects.
- The report deliberately retains qualification gaps and rejected hypotheses. The absence of another finding in a reviewed area is not a proof of absence.

## Finding index

This index records the original findings. Detailed sections below preserve their triggers, source chains, evidence limits, corrections, and regression recommendations. See the remediation appendix for their current disposition.

| ID | Priority | Finding | Evidence |
| --- | --- | --- | --- |
| [R01](#r01) | P1 | A different reassessment contract can turn a failed exact-match critical release check into a pass | Actual canonical engine runtime; app integration source-traced |
| [M01](#m01) | P1 | MCP disclosure approval can persist a pending draft's different image policy or destination | Exact-source sequence probe and independent source adjudication |
| [M02](#m02) | P2 | Production snapshot/native-job MCP calls validate canonical revision but freeze draft content | Source/caller/guard trace; excludes captured-job branch |
| [M03](#m03) | P2 | MCP suite replacement erases promoted regression provenance | Deterministic source trace and promotion-idempotence contract |
| [M04](#m04) | P2 | CRLF managed-config updates generate duplicate TOML tables | Extracted installer functions and independent TOML parsing |
| [M05](#m05) | P2 | Managed-block replacement loses TOML section scope and commits duplicate keys | Exact before/after fixture and TOML parser rejection |
| [M06](#m06) | P2 | Recommended manual setup fallback leaves the connector stopped | Settings/runtime/UI source trace |
| [E01](#e01) | P2 | After-tool generation settings are silently overridden by request options | Real FoundationModels synthetic tool transition plus positive control |
| [E02](#e02) | P2 | Image resolution rejects or rewrites valid non-image union alternatives | Full validator/resolver source trace; runtime regression still needed |
| [E03](#e03) | P2 | Reference excerpts discard answers immediately before search terms | Deterministic excerpt source/fixture trace |
| [E04](#e04) | P2 | Possessive matches rank correctly but excerpt anchoring misses them | Foundation tokenization probe and source trace |
| [E05](#e05) | P3 | Malformed judge JSON envelopes trigger an extra verdict-repair request and wrong failure attribution | Exact decoder fixture; transport loop source-traced |
| [P01](#p01) | P2 | Exporting inside the active production store can poison job listing or recurse into staging | Actual-store probes relinked against freshly built source |
| [P02](#p02) | P2 | Pause/resume/pause reuses a control revision and accepts a stale resume | Actual-store probe relinked against freshly built source |
| [P03](#p03) | P2 | Delimiter collisions merge distinct metadata cohorts and can pass a failing cohort | Actual-store report probe relinked against freshly built source |
| [P04](#p04) | P2 | A permitted 80% to 70% regression incorrectly fails a 10-point limit | Actual-store report probe relinked against freshly built source |
| [P05](#p05) | P3 | Extreme accepted finite measurements produce infinite, unencodable reports | Actual-store probe; requires malformed trusted-worker measurements |
| [P06](#p06) | P3 | Import/upload completion retries report success for corrupted retained datasets | Exact-source isolated harness; requires preexisting storage damage |
| [R02](#r02) | P2 | Deleting a calibration source blocks unrelated example enrollment/partition changes | Exact production partition logic runtime fixture |
| [R03](#r03) | P2 | Calibration reports survive suite/connection changes and misattribute old metrics | Source state/presentation trace; two triggers, one provenance issue |
| [N01](#n01) | P2 | Rediscovery overwrites an authenticated runner with connecting/empty features | Copied-source state-transition fixture; no real peer |
| [N02](#n02) | P2 | Reloading a rebuilt app can reuse stale cached Bundle metadata | Native Foundation fixture at the same replacement path |
| [N03](#n03) | P2 | Full application hashing blocks the main actor and cancellation | Actor and synchronous file/hash call-chain proof; latency unmeasured |
| [S01](#s01) | P2 | Concurrent plugin creates exceed the catalog hard limit and break enumeration/recovery | Real OS-locked cross-process Store.write fixture |
| [S02](#s02) | P2 | Successful portable suite exports can exceed the import JSON bound | Real export/import fixture within independent source/reference bounds |
| [S03](#s03) | P2 | A portable legacy trace cannot preview without its source project existing locally | Two-store real API fixture, no destination writes |
| [S04](#s04) | P2 | Catalog recovery pauses autosave indefinitely and prevents UI teardown | Actual UI entry with React/JSDOM and parent teardown message |
| [S05](#s05) | P3 | Plugin backup/recovery documentation names the wrong default data directory | README, store and launcher comparison |
| [Q01](#q01) | P2 | Every judge-example row repeatedly rebuilds/hashes the entire review sample catalog on the main actor | Source work/actor proof; native latency unmeasured |
| [Q02](#q02) | P2 | Plugin polling rereads every complete terminal run twice and rehashes it | Real API probe: 50 runs, 100 reads, 12,904,100 bytes per call |
| [D01](#d01) | P2 | Document report-integrity tests are absent from normal/full CI discovery | Discovery/import/runner reproduction; 20 tests pass only with adjusted path |
| [D02](#d02) | P2 | Incomplete document manifests and impossible slots can pass qualification reports | Mutated isolated report fixtures; semantic-ledger gaps also reproduced |
| [C01](#c01) | P2 | Installer publication does not require dedicated production recovery/protocol qualification | Workflow/source validator trace and isolated gate validation |
| [C02](#c02) | P2 | Affected PR routing omits the CLI signal-cleanup integration suite | Routing output plus source/test dependency trace |

## Validation results

These checks validate their stated source/fixture boundaries. They did not remediate the findings.

| Check | Result and scope |
| --- | --- |
| `swift test --package-path Packages/ProductionEvals -j 2` | Passed 61 tests in 10 suites. Initial sandbox attempt could not write compiler cache; normal-cache retry succeeded. |
| `swift build --build-tests -j 2` | Passed against reviewed source. |
| `CI_TEST_SELECTION='["*"]' python3 script/ci_run_tests.py swift` | Passed 138 Swift Testing tests across four test products (40 + 8 + 55 + 35). The separate XCTest harnesses report zero because these cases use Swift Testing; the actual test products executed. Native app-only tests are a separate gap. |
| `swift build --product intents-evals -j 2` | Passed. |
| `python3 script/test_production_evals.py .build/debug/intents-evals` | Passed 89 assertions: real custom-worker processes, bounded resume, backend isolation, capture/review, export, timeout. |
| Python inventory through `script.ci_run_tests.run_tests` | All inventoried modules passed across the initial run and affected-module retry. Initial run: 351 tests, with two compiler-cache fixture errors; `test_foundation_evals_cli` and `test_update_signature` then passed 13 tests with normal cache access. An earlier plain unittest discovery command failed because `script/tests` is a namespace directory; the maintained explicit module runner was used instead. |
| `PYTHONPATH=script python3 -m unittest script.test_document_quality_report script.test_document_semantic_report` | Independent lane passed all 20 report tests; D01 explains why normal CI misses them. |
| Plugin `npm test` | 297 total: 296 passed initially; only preview-origin failed because sandbox denied a temporary `127.0.0.1` listener. `node --test scripts/tests/preview-origin.test.mjs` passed 1/1 after enabling loopback access. No product failure was inferred from EPERM. |
| Plugin `npm run typecheck` | Passed. |
| Website syntax, inline-style verification, `node --test tests/*.test.mjs` | Passed syntax/style checks and all 40 tests. Rendered-browser behavior remains unqualified. |
| Independent focused checks | 175 release/CI Python checks, 63 plugin tests and 71 supplementary plugin tests passed. These overlap the broader baseline and are not added to its counts. |
| Production adversarial probes | Control, cohort, regression, numeric and both export probes were recompiled/relinked against the fresh root `.build/out/Products/Debug/ProductionEvals.o`; outputs confirmed current source. The initial relink script used library entry mode for two top-level fixtures; corrected entry mode then passed. This was a harness invocation error. |

Full local verification logs are retained in `/tmp/intents-launch-review-20261028/`. They are ephemeral; material outputs and reproduction steps are preserved below. Compiler cache/loopback/macro sandbox failures are environment evidence, not product findings. No automatic-approval rejection occurred.

## Launch priorities and remaining proof

1. Fix R01 and M01, add full-store integration regressions, and recheck their affected callers.
2. Correct immutable snapshot/provenance/control/cohort authority, configuration-file preservation, storage recovery/portability, and qualification-gate gaps before relying on those workflows for launch decisions.
3. Address UI/worker lifecycle and scaling problems; measure interactive behavior after correction. Handle the P3 edges in proportion to exposure.
4. Run the selected native app and UI checks against the fixed source, then exact-source release/package and live qualification required by `docs/ci-manual-tests.md` and `docs/releasing.md`.

Not executed or established: native app Xcode test target/UI screenshots; signed runner behavior; live Core AI resources, Spotlight index/OCR/barcodes, actual nearby pairing, native AppIntents invocation, fresh document-corpus/model quality, external judge/provider transmission, real iOS/iPadOS package consumer build, actual hosted Codex file preview, signed/notarized installer, installation/upgrade/updater behavior, current-head hosted CI or publication. Plugin native/inference suite and final zip packaging were not rerun in this audit. The SDK's declared macOS-only deployment minimum despite advertised iOS/iPadOS support remains a consumer-build qualification question, not a confirmed code defect.

The coordinating pass also inspected suite autosave/switch rollback, attachment bounded reads/path checks, launch/shutdown ownership, telemetry eligibility/consent epochs/final egress filtering and website analytics/DOM behavior. It established no additional finding. This does not certify privacy or platform behavior beyond the inspected source and test boundaries.

## Detailed findings and evidence

Each subsystem section preserves its two-pass coverage, rejected hypotheses, exact source locations, proof limits, and suggested regression tests. Historical memory informed scope only; findings use current source and current-run evidence.

## Review, calibration, reassessment and prompt improvement

Snapshot: `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`; read-only review; repository clean before and after. Scope excluded document-generation implementation and generic execution except contracts consumed here. Two passes: workflow/source contracts and tests; adversarial changed scoring, stale suite/connection, deleted evidence, cancellation/persistence, and held-out leakage.

### Verified findings

<a id="r01"></a>

### R01 — P1 — A different deterministic reassessment can turn a failed critical exact-match run into a passing release check

Anchor: `plugins/apple-foundation-evals/native/AppEngine/EvaluationDevelopmentAnalysis.swift:211` (selected scoring/evidence contract validation is conditional on the original run being modelJudge); `:258–261` then uses selected statuses for critical cases regardless of their contract. App path: `FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift:1067–1091` builds reassessment from the current suite scoring mode, appends/selects its assessment, preserves the original run mode/revision.

Prerequisite: the store must have a resolvable judge connection, any credential that connection requires, and current external-evidence approval. Reassessment resolves/approves that connection even for deterministic scoring; an unconfigured default exact-match suite will fail admission.

Trigger: save an exactMatch run with critical case expected `READY` and response `READY extra` (failed). Change current suite to containsExpected, reassess that saved output (passes deterministically), then restore the suite to its exact original definition. The original run mode/revision now match, but the selected containsExpected assessment controls the critical-case verdict. The release report returns passed even though its selected assessment has a different scoring contract from the current exactMatch suite.

Runtime evidence: `/tmp/intents-cross-contract-release-repro.swift` compiled against actual canonical native AppEngine sources using the native boundary-test compile pattern (RunnerCore and every AppEngine Swift file except AppEngineBridge/AppEngineWorkflows). It uses real MetricScorer, EvaluationScoringContract and EvaluationReleaseCheckEvaluator. `/tmp/intents-cross-contract-release-repro` exits 0 and prints:

```
REPRODUCED: original exactMatch critical case=failed; release before=10; selected containsExpected assessment=passed; release after=0; incompatible contract accepted
Before failures: ["Critical case <UUID> did not pass every trial."]
After failures: []
```

The harness constructs the equivalent deterministic reassessment; full EvaluationStore integration was source-traced, not executed. Build log `/tmp/intents-cross-contract-release-build.log`. Initial compile was blocked by nested Swift macro sandbox restrictions; the changed-condition compile outside the sandbox succeeded. No repo source edits or inference/network requests.

Fix/test: validate every selected assessment against the current scoring contract and immutable source evidence, including deterministic modes, before its scores can affect release or baseline checks. Add store integration coverage exactMatch -> containsExpected reassessment -> restore original -> release report must remain incompatible; also cover review/field assertion and modelJudge transitions.

Confidence: high. Impact: false release success for a failing required critical case through ordinary reassessment and scoring edits.

<a id="r02"></a>

### R02 — P2 — A deleted calibration source prevents unrelated Review enrollment and partition changes

Anchor: `FoundationEvals/FoundationEvals/Stores/EvaluationStore+Review.swift:98–103`; assign resolves every example source, throwing on any orphan, before it can change the requested case. `:64` calls this during Review enrollment. `FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift:2828` updates prompt-improvement references during deletion but leaves reviewedJudgeExamples; `:2861` removes the run. Clear history similarly retains judge examples (`:3070–3075` only clears prompt improvements).

Trigger: enroll a judge example from run A, delete A's saved run (or clear history), then enroll a valid human-reviewed output from unrelated live run B or change B's partition. The stale A example throws `A judge example's source is missing. Restore it before changing partitions.` No normal remove-example action is available. Legacy Correct judgment enrollment can still append checks, but Review enrollment and all partition edits remain blocked.

Evidence: exact production EvaluationReviewJudgePartitions enum was extracted unchanged into `/tmp/intents-review-partition-repro.swift` with minimal model stubs. `swift -module-cache-path /tmp/intents-review-module-cache /tmp/intents-review-partition-repro.swift` exits 0; an unrelated orphan rejects live-case assignment; manual orphan removal makes the identical assignment succeed. Deletion and UI recovery paths independently inspected.

Fix/test: atomically remove/invalidate judge references during source deletion (including foreign-suite deletion and clear history), and expose a recovery/removal policy; prevent an unrelated missing source blocking a valid case partition change. Integration test enroll A -> delete A -> enroll/change B -> relaunch.

Confidence: high. Impact: durable workflow dead end after normal history cleanup.

<a id="r03"></a>

### R03 — P2 — Latest calibration results are attributed to another suite or changed judge configuration

Anchor: `FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift:35` keeps one global latestJudgeCheck; only a new check clears it (`:1243`); successful suite selection `:738–749` / loadSelectedSuite `:845+` retains it. `FoundationEvals/FoundationEvals/Views/ReviewJudgeChecksPane.swift:26–29` displays it in every selected suite and resolves its title from current connection metadata. `FoundationEvals/FoundationEvals/Services/EvaluationReassessmentService.swift:11–14` retains only connectionID/results; no suite identity or immutable judge/configuration provenance. Connection replacement `FoundationEvals/FoundationEvals/Stores/EvaluationStore.swift:940–954` does not invalidate it.

Triggers: (1) Check suite A, switch to B, open Judge checks: B displays A's Development/Held-out statistics, even with no B examples. (2) After checking model A, edit its connection with the same UUID to name/model/endpoint B: A's historical statistics appear under B's current name without a stale indication. Native settings disable edits during active checks but allow this after completion; MCP/store edits can also occur during execution.

Evidence: deterministic source trace; no full native UI repro executed.

Fix/test: freeze project/suite ID, scoring/source revision and requested/observed judge identity/configuration digest in each report; display historical identity and clear or flag results after relevant changes. Tests for A -> B selection and same-ID connection mutation.

Confidence: high. Impact: calibration evidence appears to validate the wrong suite or judge.

### Coverage and rejected candidates

- Prompt improvement: Development-only generation input; candidate selection frozen before held-out work; no aggregate pass gain can hide a per-case held-out regression; invalid/partial/errored/cancelled evidence cannot authorize apply; comparison history excluded from default release evidence; run deletion invalidates recommendations; apply requires canonical and draft equality to source; candidate-adoption persistence rollback examined. No additional confirmed defect.
- Reassessment: frozen cases/instructions/attachments and run-owned image digests; captured tool and conversation evidence required; cancellation does not commit partial assessment; provider usage/cost incompleteness and deterministic identity handled; cross-contract release exception above.
- Human review: initially hidden judgment, view identity resets disclosure, source digest staleness, proposal acceptance, confirmed-failure pattern grouping, regression creation, draft navigation/shutdown persistence. Timing/token traces are not verdict/rationale leakage.
- Calibration: case-wide partition ownership and held-out inheritance; scoring-contract groups; unavailable counts and denominator safety. Stale report attribution and orphan recovery exceptions above.
- Rejected suspected mixed objective/semantic criteria bug: compatible judge client consumes semanticSuite.rubricCriteria, so filtered semantic indexes are respected even when original cases contain criteria overrides.
- Rejected data-source mutation recommendation: report captures source suite and compared evidence; canonical/draft stale guards and image snapshot digests already protect normal mutation paths. No actionable unsupported tampering claim.

### Qualification limits

Existing focused tests inspected, not run: EvaluationPromptImprovementTests; EvaluationReviewWorkflowTests; EvaluationReassessmentIntegrity/ProvenanceTests; relevant EvaluationDevelopmentWorkflow, SelectedAssessmentCoverage, ExecutionStoreShutdown, MCPWorkspaceCompletion and legacy review tests. Heavy builds/testing coordinated by parent. No native UI/screenshots or live provider qualification in this lane.

Judge checks have no in-app cancellation control and only cancel on app shutdown; long sequential checks hold suite mutation/switching busy. This is reported as a limitation, not a confirmed finding without an explicit cancellation requirement. Attachment-dependent human review has no inline source-image/document viewer; not promoted as a defect.

## MCP authority, transport and installation

Scope: app MCP transport, tool contracts/discovery, store authority, control receipts, workspace/production/runner controls, lifecycle, installer/settings. Two passes: ordinary caller/test contracts; then adversarial input, stale/draft authority, consent, cancellation/failure and configuration preservation. Production files unchanged. Independent installer/settings review consolidated after checking source and exact TOML evidence.

### Findings

<a id="m01"></a>

### M01 — P1 — Disclosure approval applies a different draft than the revision/digest the caller approved

- Primary location: `FoundationEvals/FoundationEvals/Services/MCPWorkspaceControl.swift:291-304` (especially 302). High confidence.
- Outer guards compare expectedWorkspaceRevision (161-164), selected IDs and expectedRevision (75-87) to canonical suite state. Revision (62-71) excludes draftSuite. Handler validates canonical suite connection/digest (293-296), then `EvaluationStore.approveExternalJudgeDisclosure` (1031-1040) approves and saves draftSuite's exact connection and attachment policy. `saveSuite` (3339) passes draft into `commitSuite`, which sets canonical suite to candidate (4430); no second candidate-binding guard exists.
- Prerequisites: an authenticated, explicitly confirmed MCP approval call and a valid pending draft that differs before its debounced save (normally 350 ms). Freshly saved canonical content closes this particular stale-state window. The action itself sends no evidence.
- Trigger: canonical connection A, image references disabled; obtain canonical/workspace revisions and digest A; a valid pending UI draft enables image references before autosave. Approve using the old revisions/digest. The action approves and persists the image-enabled draft and reports success. Alternatively pending draft switches to B: B is approved and persisted before the handler returns failure against A.
- Impact: operator approval can silently authorize a different evidence disclosure policy/destination. This establishes incorrect approval state, not an actual outbound transmission.
- Isolated source probe: `/private/tmp/mcp-disclosure-source-probe.py` extracts the unchanged handler case, store approval method and approval predicate into `/private/tmp/mcp-disclosure-source-probe.swift`; minimal call/store/save stubs. `swift -module-cache-path /private/tmp/intents-mcp-review-module-cache /private/tmp/mcp-disclosure-source-probe.swift` prints same-A false-to-true policy approval succeeds and draft-B is approved despite failed response. This is source-sequence evidence, not native app integration. Source independently cross-checked by review_workflows lane.
- Fix: bind approval to a single exact candidate/disclosure, including attachment policy; either reject divergent drafts or flush then revalidate revisions/digest before mutation. Test both changed draft policy and changed draft connection; failure must leave approval and canonical/draft persistence unchanged.

<a id="m02"></a>

### M02 — P2 — Production snapshot/create bind canonical revisions but freeze unreported draft contents

- Locations: `Services/MCPProductionControl.swift:39-40,65-78`, `Services/MCPWorkspaceControl.swift:75-87`. High confidence, source-verified.
- Trigger: capture canonical revision R, change valid draft prompt/instructions/provider without canonical commit, then dataset_snapshot or native job_create using R. requireTarget validates canonical R; dataset_snapshot copies draftSuite, nativeConfiguration calls EvaluationStore.productionSnapshot (5614), which also copies draftSuite.
- MCP state returns canonical suite (MCPStoreAuthority 194-213; workspace_state 146-147). Current test MCPStoreAuthorityTests.stateUsesOneAuthoritativeSuiteWhileTheUIDraftIsInvalid explicitly proves draft/canonical divergence can persist. Thus callers cannot identify the bytes their supplied revision freezes.
- Fix: use canonical content corresponding to R or flush/revalidate and expose a draft revision. Test changed draft fields with unchanged canonical revision and require conflict or canonical bytes. Native UI draft snapshot behavior itself is intentional; finding concerns MCP authority.

<a id="m03"></a>

### M03 — P2 — Legacy suite replacement erases promoted-regression provenance

- Location: `Services/MCPStoreAuthority.swift:406-415`. High confidence, source-verified.
- Trigger: promote a reviewed failure, read eval_get_state, change only suite name/instructions, call eval_replace_suite preserving case IDs. Mapping constructs new EvaluationCase values and does not preserve currentCase.reviewSource. Native source set at EvaluationReviewWorkflow 245-250 is absent from MCPCaseDeclaration (161-169), so caller cannot preserve it.
- Impact: persisted source audit disappears; repeat promotion now creates a second case because EvaluationStore.promoteReviewToCase (1148) checks reviewSource.reviewID for idempotence. Document cases are explicitly guarded at store 2733; no document-loss claim.
- Fix/test: retain matching-case server-owned provenance. Add read/replace after promotion and repeat-promotion assertion returning original case ID. Existing MCP preservation tests cover feature/provider/conversation/assertions/policy, not reviewSource.

<a id="m04"></a>

### M04 — P2 — CRLF managed configuration update duplicates the TOML table

- Locations: `MCP/Installer/CodexMCPInstaller.swift:577,687`. High confidence, reproduced.
- Both scanners search Swift Character `\n`; CRLF is one grapheme cluster, so CRLF managed config becomes one initial comment and the markers/table are missed. Installing appends a second mcp_servers.foundation-evals table to otherwise valid TOML.
- Evidence: `/private/tmp/intents-mcp-installer-probe.swift` extracted unchanged pure functions; exact before/after `/private/tmp/intents-mcp-crlf-probe-result.json`. Parent lane reran Python tomllib: before valid, after rejects duplicate table at line 9. Plain multi-assignment CRLF instead refuses safely.
- Fix/test: handle line terminators while preserving byte/range mapping; CRLF install/update/unchanged/inspection/conflict/removal fixtures.

<a id="m05"></a>

### M05 — P2 — Replacing managed block loses surrounding TOML section scope and commits duplicate keys

- Location: `MCP/Installer/CodexMCPInstaller.swift:301-308`; commit caller 253. High confidence, reproduced.
- Valid old managed block has table header and URL, followed after END marker by unmanaged `http_headers = { Authorization = "Bearer manual-secret" }`, still in that server table. Installer validates remainder after deleting block, treating remaining setting as root; replacement adds its own http_headers, generating duplicate keys. Complete proposed text is not validated before commit.
- Extracted Swift probe yields exact duplicate output; Python tomllib accepts original, rejects output `Cannot overwrite a value (at line 6, column 58)`.
- Fix/test: preserve table scope during ownership inspection and validate entire proposed output; fixture must yield valid TOML or refuse preserving bytes.

<a id="m06"></a>

### M06 — P2 — Recommended manual setup fallback leaves connector stopped

- Locations: `MCP/Installer/MCPSettingsController.swift:184,228-235`; `FoundationEvals/FoundationEvals/FoundationEvalsApp.swift:159-168`; `Views/MCPSettingsView.swift:41-64`. High confidence, source-verified, independent settings review.
- Installer rejects unsupported valid TOML (e.g. escaped quoted key), sets needsAttention and recommends manual configuration. Copy action only copies snippet. Manual edits do not update in-memory installation state; app autostart requires installed, and settings exposes no independent Start control. On relaunch unsupported configuration still classifies needsAttention.
- Impact: advertised fallback cannot make MCP usable without fixing installer compatibility/using debug launch flag.
- Fix/test: offer authenticated connector startup independent of config mutation. Inject installer/server and verify manual fallback starts with copied credential while leaving unsupported config unchanged.

### Coverage and gaps

Traced HTTP loopback bind, host/origin/bearer/content-type preflight, admission release/body bounds; JSON-RPC/notification/version errors; discovery read/mutation gating; legacy parser and suite preservation; global receipts/retry/restart/spill/shutdown; workspace revision and confirmation contracts; production/runner delegation and tracked completion; runtime generation/start/stop/termination; installer permission/ownership/marker parsing and settings startup.

No native build, native suite, live socket, provider, pairing device or outbound transmission test ran. Parser probes and source-sequence probe are the only runtime evidence. Existing lifecycle/protocol/store tests were read, not rerun. Working tree remained clean.

Rejected hypotheses: release_report changes selection but correctly advertises mutation; legacy document cases cannot silently flatten via replacement (explicit guard); getter force unwraps are backed by same-actor operation invariants in ordinary paths; discovery cannot route mutations through read entry point; credential values are absent from receipt arguments (only digest retained); normal duplicated headers fail preflight; stale runtime generations and shared stop teardown guarded. Installer rollback race remains unvalidated candidate: NSFileCoordinator probe fails before callback with Cocoa error 512 in temporary roots; stopped after changed-root attempt, not reported as proven defect.

## Evaluation execution and tools

Snapshot: clean `main`, `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`, 2026-10-28. Read-only review. Final `git status --short` empty and `git diff --check` passed. No app or repository test/build launched in this lane. Two small FoundationModels injected-executor fixtures compiled under /tmp, with no live inference or network.

### Findings

<a id="e01"></a>

### E01 — P2: After-tool generation settings are silently overridden

- Primary: `plugins/apple-foundation-evals/native/AppEngine/EvaluationFeatureResponse.swift:31-39`; related `plugins/apple-foundation-evals/native/AppEngine/EvaluationDynamicProfile.swift:87-90`, `plugins/apple-foundation-evals/native/AppEngine/ModelExecutionConfiguration.swift:32-42`.
- Trigger: enable a session profile and set an after-tool response limit different from the suite response limit. The suite always supplies a non-nil `maximumResponseTokens` per request. If the global sampling/temperature/reasoning values are explicit, those also override the corresponding after-tool profile settings.
- Impact: the after-tool generation UI and saved configuration describe settings the executor does not use; evaluations compare the wrong model behavior. The after-tool response limit is always ignored. Sampling, temperature and reasoning overrides are ignored when their global equivalents are non-nil. Shared canonical source affects both app and standalone plugin.
- Evidence: production `EvaluationFeatureResponse.generate` clears only `toolCallingMode` for profiles, while passing other request options/context to streaming and ordinary generation. FoundationModels request values take precedence over profile modifiers. Exact public-framework behavior was executed with a two-phase DynamicProfile, a synthetic tool and injected executor. Before and after the tool: `MAX Optional(512) TEMP Optional(0.2) SAMPLING greedy REASONING moderate`, despite after-tool modifiers 4096/0.7/random(top7, seed8)/deep. Positive control with empty request options produced after-tool 4096/0.7/random/deep.
- Command: `xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 -module-cache-path /tmp/intents-profile-modulecache /tmp/intents-profile-dynamic-contract.swift -o /tmp/intents-profile-dynamic-contract && /tmp/intents-profile-dynamic-contract`.
- Result: exit 0, approximately 0.4 seconds. Fixture is retained at `/tmp/intents-profile-dynamic-contract.swift`. Initial static-profile fixture `/tmp/intents-profile-contract.swift` also passed. A first dynamic fixture using `@SessionPropertyEntry` failed because the compiler macro sandbox could not start; changed hypothesis to the public `SessionPropertyKey` API avoided the macro and passed. This did not require escalation or a live model.
- Existing tests: `FoundationEvals/FoundationEvalsTests/EvaluationDynamicProfileTests.swift:7-24` asserts configuration-to-modifier mappings, not executor observations.
- Fix/test: make the dynamic profile own effective initial and after-tool options, avoid competing per-request values, and budget for the actual reachable maximum response limit. Add injected-executor tests that observe options before/after a tool for ordinary and streaming response paths and verify inherited defaults.
- Confidence: high; source plus real framework execution, with a positive control.

<a id="e02"></a>

### E02 — P2: Valid union arguments can be rejected or changed during image resolution

- Primary: `plugins/apple-foundation-evals/native/AppEngine/EvaluationCustomTool.swift:437-444`; related `:528-552`, especially `:540` and `:541-543`; mutation at `:477-483`.
- Trigger: field `payload = union(array<imageReference>, array<string>)`, arguments `{"payload":["hello"]}`, empty history. Full schema validation accepts the second alternative. Resolver selects the first image-bearing array because `valueCouldMatch` checks only array shape, then tries to parse `"hello"` as an ImageReference and throws before fixture/HTTP dispatch.
- Object variation: union of imageReference and object `{attachmentLabel:string,note:string}` can pass through the object branch, then get treated as imageReference and replaced with image metadata, losing `note`.
- Impact: valid configured custom tools fail before dispatch or receive changed arguments. Shared canonical source affects app and plugin.
- Evidence: full validation and resolver branch trace by schema/tools reviewer; no runtime test executed.
- Fix/test: select the union branch using full schema validation, including nested types/constraints, before resolving image fields. Regress both non-image and image array/object alternatives through tool dispatch.
- Confidence: high; deterministic source trace.

<a id="e03"></a>

### E03 — P2: Reference excerpts discard answers before search terms

- Primary: `plugins/apple-foundation-evals/native/AppEngine/ReferenceLookupTool.swift:123-128`.
- Trigger: source `£120 is the annual fee.`; query `annual fee`.
- Evidence: excerpt begins at the first query-token match, producing `…annual fee.` and dropping `£120`, even though the whole source fits within 350 UTF-8 bytes. No model behavior is needed to reproduce the string operation.
- Impact: reference-search tool withholds the answer from the subject model for a valid matching source, degrading evaluation results.
- Fix/test: retain whole short references; for long references include a bounded amount of preceding/sentence context. Add a regression retaining the price for the example above.
- Confidence: high; deterministic source trace.

<a id="e04"></a>

### E04 — P2: Ranking and excerpt anchoring disagree on possessive tokens

- Primary: `plugins/apple-foundation-evals/native/AppEngine/ReferenceLookupTool.swift:119-125`; ranking tokenizer at `:90-93`.
- Trigger: 80 repetitions of `background ` followed by `The customer’s return window is 30 days.`; query `customer`.
- Evidence: ranking splits punctuation and counts `customer`; Foundation `.byWords` anchoring sees `customer’s`, fails to match, and falls back to the document prefix. The 350-byte excerpt omits the only answer. Delegated no-build JXA/Foundation probe confirmed the differing token boundaries and omitted answer.
- Impact: a correctly ranked matching document yields irrelevant tool evidence.
- Fix/test: share tokenization/matching boundaries for ranking and anchoring, preserving ranges into the original string. Regress late ASCII and curly possessives; hyphen/numeric separators should use the same tokenizer too.
- Confidence: high; source plus Foundation tokenization probe.

<a id="e05"></a>

### E05 — P3: Malformed JSON protocol envelopes incorrectly trigger a verdict repair

- Primary: `FoundationEvals/FoundationEvals/Services/EvaluationCompatibleJudgeResponse.swift:115-116`; propagation at `FoundationEvals/FoundationEvals/Services/EvaluationCompatibleJudgeClient.swift:345`, retry classification at `:276-280` and `:445`.
- Trigger: independent judge returns HTTP 200 with `{"choices": [` or `{"unexpected":true}`.
- Evidence: JSONDecoder leaks DecodingError from the completion-envelope decoder. The client treats every DecodingError as a repairable model verdict and sends a second request. Two bad envelopes become `invalidJudgeOutput`; a successful second response hides the first protocol failure. Malformed SSE is correctly a response failure, stops immediately and maps to `judgeNetworkFailure`. HTTP-client reviewer executed exact decoder source with a minimal trace stub and confirmed both JSON examples were DecodingError rather than protocol failures; equivalent SSE was a protocol failure.
- Impact: unnecessary potentially paid request and incorrect provider/protocol vs judgment attribution.
- Fix/test: wrap only JSON-envelope decoding failures as malformed response failures. Keep decoded verdict-content failures repairable. Inject malformed/missing-choices transport responses and assert one request and `judgeNetworkFailure`.
- Confidence: high; source plus exact decoder fixture.

### Passes and coverage

1. Execution/lifecycle pass: app and plugin EvaluationRunner variants; subject and judge generation; provider admission; per-sample preparation, setup/history retention/projection, cancellation, fatal batch stop, progress, result/assessment construction; paired experiment plan validation/aggregation; deterministic scoring; dynamic-profile state; refusal race; context/token and shared tool budgets; workflow spans; built-in evidence.
2. Contract/adversarial pass: compare configuration and test contracts against execution; full union validation vs image transformation; request/profile precedence; reference rank/excerpt boundaries; protocol envelope vs verdict repair classification; model-judge criterion remapping, document isolation, scored coverage and comparisons/release reporting. Challenged each accepted candidate using current callers and tests.

Delegated scope completed: SchemaBuilder/Validator, custom tools, HTTP tool/workflow requests, reference lookup, Spotlight runtime, HTTP subject adapter, compatible judge client/decoder, CoreAI loader, corresponding config/callers/tests. Static inspection also covered shared customization/vision/configuration, context cache, conversation runtime/models, judge subject context, exact-criterion extraction, judge validation, run analysis and release/experiment summaries.

No app/native suite, live custom endpoint, CoreAI resources, actual Spotlight index, native OCR/barcode, real refusal explanation, or UI flow was qualified. Loader cache/cancellation/security-scoped resource behavior was source-reviewed, not live verified. Candidate E2 needs a focused runtime regression; candidates E3/E4 have not run a full reference-tool integration suite. No source corrections were made.

### Challenged/rejected candidates

- Zero/negative repetitions or count overflow in ordinary runner: app/plugin validation bounds normal entry points; experiment validates its own plan. No exposed invalid execution path established.
- Deferred custom-provider admission: adapter exact-counts assembled request with configured tokenizer; absent tokenizer uses runner conservative UTF-8-byte estimates.
- Subject response discarded by failed judge: scorer returns unscored result while preserving subject response; incomplete saved tool evidence has a dedicated scoring fallback.
- Mixed semantic/exact rubrics and document remapping: criterion remapping and per-document isolated calls preserve original indexes and context.
- Field assertions bypassed by reassessment: reassessment gates new judgments through assertions.
- Refusal timeout waits forever on loser: explicit continuation race cancels without waiting for a noncooperating explanation, as intended; no further leak fix proposed without runtime evidence.
- Missing SSE DONE/finish reason: explicit compatible-endpoint policy, not a regression.
- Reserved tool HTTP port discrepancy: app and plugin intentionally compile different config-model adaptations; app rejects its MCP port.
- Spotlight cancellation, identity collisions, cross-source deduplication/reply aggregation: no concrete faulty path established.
- CoreAI loader cache/security scope ownership: coherent in source, resource-dependent proof remains a gap.

## Production batches, reports and storage

Reviewed read-only source at `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`. Repository remained clean. Owned: `Packages/ProductionEvals`, `Sources/ProductionEvalsCLI`, app `ProductionWorkspaceStore`, `NativeProductionExecutor`, `ProductionNativeWorkerCommand`, and their `EvaluationStore` admission/snapshot calls. A bounded child reviewer covered dataset/upload/report/review/approval/evidence paths independently; findings below were checked against source.

This independent lane did not rebuild packages or run the full suite; the coordinator later ran the checks above. Runtime probes linked existing `Packages/ProductionEvals/.build/out/Products/Debug/ProductionEvals.o` and its module; those artifacts initially lacked source-to-artifact proof. The coordinator subsequently relinked and reran the control, cohort, regression, numeric and export probes against the freshly built current-source root module, confirming the same results. Source formulas independently establish the reported defects. All runtime stores were synthetic `/tmp` fixtures and removed after each probe.

### Findings

<a id="p01"></a>

### P01 — P2: An export inside the active store can break workspace loading or recursively copy its own staging

- Location: `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionEvidenceExport.swift:35-46`.
- Trigger: Export to a new `<root>/Jobs/export` directory. Destination validation accepts it and export succeeds. The next `storage.jobs()` sees `export` as a job directory and throws `Invalid job directory`, breaking the workspace's all-lists refresh and polling workers. A destination `<jobDirectory>/export` instead creates staging beneath its copied source; recursive `copyItem` fails only after generating deeply nested copies, increasing disk use while holding the exclusive store lock. Dataset descendants and other storage collections have analogous problems.
- Evidence: `/tmp/intents-production-export-store-probe.swift` printed `EXPORTED=true` then `JOBS_READ=false error=integrity("Invalid job directory.")`. `/tmp/intents-production-export-probe.swift` printed NSCocoaErrorDomain514 / underlying NSPOSIXErrorDomain63. The child's exact Foundation copy-shape repro created 123 paths before filename-too-long.
- Fix/test: Reject canonicalized destinations inside the active store, including symlink aliases; test top-level collection outputs, job/dataset descendants and aliases. Confidence high.

<a id="p02"></a>

### P02 — P2: Control revision ABA allows a stale resume to undo a newer pause

- Location: `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionJobs.swift:96-111`.
- Trigger: Read a revision while paused; another operator resumes and a later timeout/operator pauses the job again. The revision is again identical because it hashes only `paused/cancelled`. A delayed resume using the first revision passes the optimistic guard and clears the newer pause. This can admit additional work while a newer timed-out side effect is still unverified.
- Evidence: `/tmp/intents-production-aba.swift` printed `mutationChanged=true revisionsIdentical=true` and `staleResumeAccepted=true finalPaused=false`. `evidenceMutationID` already changes on each real control transition, so this is not caused by cost-ledger updates.
- Fix/test: Include the control mutation identity in the revision while excluding timing/cost-only changes. Test pause-resume-pause ABA rejection, same-state idempotent changes and cost-ledger stability. Confidence high.

<a id="p03"></a>

### P03 — P2: Ambiguous cohort identity can pass a failing cohort

- Location: `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionAnalysis.swift:83-90`; accepted metadata at `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionDatasets.swift:110-111`.
- Trigger: A failed example has `{"task":"a=b"}`; a passing example has `{"task=a":"b"}`. Both keys are selected for threshold `task=a=b` and concatenate to the same cohort identity. A minimum0.5 passes although actual `task == "a=b"` evidence has passrate0.
- Evidence: Actual-storage probe `/tmp/intents-production-report-probes.swift` printed `COHORT exit=0 computedRate=0.5 actualTaskRate=0.0`.
- Fix/test: Use collision-free structured dimension identity, or reserve the delimiter in dimension keys with explicit compatibility handling. Cover collisions, two colliding dimensions in one record, and required-cohort matching. Confidence high.

<a id="p04"></a>

### P04 — P2: Exact allowed pass-rate regression fails at the boundary

- Location: `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionAnalysis.swift:151`.
- Trigger: Baseline8/10, candidate7/10, allowed regression0.1. IEEE subtraction gives0.10000000000000009, so the job incorrectly fails.
- Evidence: Actual-storage report probe printed baseline0.8 / candidate0.7 / limit0.1 / exit10 with only `Pass rate regressed beyond the approved limit.`
- Fix/test: Use a narrowly bounded numeric comparison or exact ratio arithmetic. Test the exact boundary and adjacent genuinely excessive regression. Confidence high.

<a id="p05"></a>

### P05 — P3: Individually finite response measurements can make reports impossible to encode

- Location: `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionAnalysis.swift:93-111`; acceptance at `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionJobs.swift:248-253`.
- Trigger: One accepted `Double.greatestFiniteMagnitude` latency gives histogram bucket32768, then infinite P95 upper edge. Two accepted1e308 latencies overflow the sum/average. Costs have analogous unbounded accumulation. Reports can still report exit0 / baselineEligibletrue before JSON output and export fail.
- Evidence: Actual-storage report probe printed `NUMERIC reportExit=0 p95Finite=false eligible=true`, then `EncodingError.invalidValue` at p95UpperMilliseconds. Independent exact-formula Swift proof also confirmed average overflow.
- Fix/test: Bound accepted measurements or use overflow-safe aggregation and explicit finite aggregate handling. Include successful JSON serialization in boundary tests. Confidence high; malformed trusted-worker input is required.

<a id="p06"></a>

### P06 — P3: Dataset import/completed-upload retries can claim success for corrupted retained bytes

- Location: `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionDatasets.swift:59-64`, `Packages/ProductionEvals/Sources/ProductionEvals/Services/ProductionUploads.swift:171`.
- Trigger: A previously published `examples.jsonl` becomes corrupted. Reimport of the valid original data and repeated completion of the upload return its existing revision using `loadDataset` with default `verifyFiles:false`; later reader/job creation rejects the revision.
- Evidence: Child reviewer harness using exact dataset/upload source confirmed both success returns, followed by `Dataset bytes changed after publication` from `ProductionDatasetReader`. Fixture `/private/tmp/dataset-review-29e6aw41`.
- Fix/test: Verify retained files before returning a successful immutable revision in mutation completion paths. Cover current and legacy identity reuse and completed-upload retry. Confidence high; preexisting storage damage is required.

### Coverage and rejected candidates

Two passes traced normal workflows and malformed/concurrent/interrupted cases: immutable dataset identity and offsets, upload receipts and sealing, job freezing, target/repetition slot identities, lease admission/expiration/stale commits, maximum attempts, safe replay versus side effects, deadline/cancellation races, wall-clock and cost budgets, attempt cost journaling, pause/resume/cancel, scheduled clone recovery, native snapshot/images/admission, captured evidence, CLI backend routing and response limits, paginated results, report provenance/latency/rates/cohorts, review authority/disagreement/reconciliation, approval invalidation and export consistency.

Existing tests cover the major lease/retry/cost/review/approval contracts. No new confirmed defect was found in deadline winner selection, interrupted side-effect replay prevention, cost-journal settlement recovery, worker target matching, native image verification, exact-evidence approval, first-baseline approval, review disagreement or assigned reconciliation. First baselines intentionally do not need their own predecessor. Reviewer names and workers use documented trusted-local-store provenance. Preview intentionally validates a bounded prefix before import.

Additional gap: exports contain candidate evidence and aggregate baseline rates but omit the referenced baseline's raw evidence, evidence revision and approval receipt. This was not classified as a defect because the public export contract does not explicitly require a self-contained baseline bundle. Selected native/live checks remain unverified; parent coordinates full validation.

## Developer runner and native intent integration

Snapshot: f26880d16aaedf4fdc99ec0d5d54e80a17202e97. Read-only; final git status clean.

### Validated findings

<a id="n01"></a>

### N01 — P2 — Rediscovering a connected runner destroys its usable connection snapshot

- Location: Sources/FoundationEvalsDeveloper/DeveloperRunnerClient.swift:477-488 (guard at 468 rejects only a different authenticated peer).
- Trigger: A trusted, authenticated peer is lost from Bonjour discovery while its transport session survives, then the same peer is discovered again. `lostPeer` intentionally preserves connected sessions (515-522).
- Behavior/impact: `found` replaces its connected snapshot with `state: .connecting, features: []`, calls `beginConnecting`, and reinvites the existing peer. The normal existing connection has no reason to repeat its authenticated hello, and `startUnauthenticatedSessionTimeoutIfNeeded` refuses a timer when an authenticated peer exists (921-922). New execution is rejected because `execute` requires the snapshot to remain connected (408-410); feature choices disappear. Recovery requires disconnect/reconnect.
- Confidence: High; source and isolated state-transition reproduction.
- Evidence: /tmp/intents-developer-review-t_oarqm0/run.log reports `Before rediscovery: connected features: 1` then `After rediscovery: connecting features: 0`. Reproduction uses copied original Client+Protocol code, with only Observation annotations removed after the sandbox's Swift macro plugin returned malformed responses. A same-file test helper seeds the authenticated connection; `found` logic is unchanged. No real peer is contacted.
- Fix/test: Preserve state/features for an already authenticated same peer, optionally updating discovery metadata only. Add a recovery regression with authenticated state, lostPeer, found; assert connected state and features remain intact and new execution admission is retained.

<a id="n02"></a>

### N02 — P2 — Reloading a rebuilt app can reuse stale bundle metadata

- Location: Sources/MacIntentTesting/MacIntentCatalog.swift:12-15.
- Trigger: Load an app, replace/rebuild it at the same path with a different CFBundleExecutable (remove the old executable), then reload in the same Intents process.
- Behavior/impact: Foundation caches Bundle(url:) metadata. Reload reads the original executable URL and rejects the valid replacement as missing its executable until Intents restarts. Changed bundle identifiers are also stale, potentially mislabeling a reloaded catalog.
- Confidence: High; native subreviewer independently reproduced Foundation behavior twice, including explicitly releasing the bundle and draining its autorelease pool. Parent reviewer inspected exact script and output.
- Evidence: /tmp/intents-launch-review-native/bundle-cache-repro.py and bundle-cache-repro.log. Log reports original identifier/executable after replacement/release, cached executable missing, current disk executable present. Fixture uses copied /usr/bin/true; removed afterward.
- Fix/test: Parse fresh Contents/Info.plist bytes and derive/validate the executable from current disk metadata, binding those bytes to product identity. Regression loads fixture, replaces Info/executable at the same path, removes original executable, reloads and checks current ID/path.

<a id="n03"></a>

### N03 — P2 — Full application hashing blocks the main actor and cancellation

- Location: FoundationEvals/FoundationEvals/Stores/MacIntentTestingStore.swift:47; Sources/MacIntentTesting/MacIntentRunner.swift:50,109,116,126,261; hashing loop Sources/MacIntentTesting/MacIntentProductIdentity.swift:37-40.
- Trigger: Select or test a large valid native application bundle.
- Behavior/impact: Store and runner are @MainActor. Catalog loading and repeated identity validation synchronously enumerate/read/hash every bundle file there, permitting up to 8 GiB and 250,000 entries without suspension/cancellation checkpoints. Intents UI and Cancel cannot execute during a scan. Only final validation is detached (runner 199/475), leaving earlier repeated scans blocking.
- Confidence: High for actor/blocking semantics; no large-bundle timing benchmark performed to avoid competing with shared builds.
- Evidence: Direct actor/call-chain verification; synchronous FileHandle reads and SHA256 updates in capture(), reached from synchronous main-actor Store.load and runner.run/validateSubject.
- Fix/test: Move catalog hashing and all identity scans off the main actor and add cooperative cancellation between chunks/files. Test with paused injected hashing to prove main-actor heartbeat and cancellation run while hashing is pending.

### Coverage and proof boundaries

Two passes: (1) discovery, pairing/authentication/protocol identity, feature registration/admission, desktop execution projection/capture alias, native catalog/source/CLI/invocation/export/ownership; (2) adversarial state transitions, malformed/replayed/cross-direction traffic, request-ID ownership/cancellation, reconnect/pairing renewal, transport shutdown and large/replaced app behavior. Native work delegated to a disjoint reader; material findings verified above.

Inspected Sources/FoundationEvalsDeveloper, Sources/MacIntentTesting*, related app stores/adapter/views, tests and integration docs/examples. Existing source/tests cover duplicate active registry IDs, cross-connection cancellation, same-connection duplicate result suppression, secure ordering, expectation-free input validation, and explicit cooperative deadline semantics. No additional validated issue in scalar/source escaping, authored-case export, result counts, process-group cleanup, or subject lifetime binding.

Unverified: live nearby network/pairing, native AppIntentsTesting/signing, actual interactive UI behavior, iOS package consumer deployment/build. Package.swift declares only macOS26 despite docs advertising iOS/iPadOS26; this is a qualification gap, not a reported defect without a consumer build. Capture is an alias to ProductionEvals.DeveloperProductionCapture; primary capture implementation belongs to the production review lane.

No repository changes or heavy/shared builds. Swift copied-source repro compiled and ran after removing Observation macros solely in /tmp; original-macro compile was blocked by sandbox macro plugin response, not established product failure. Parent owns shared checks. Rejected speculative actor task-order races, already-documented non-cooperative cancellation limits, malicious local trust-file corruption, and schema numeric-roundtrip concerns (subject value enum has tagged Codable representation).

## Standalone plugin

Snapshot: f26880d16aaedf4fdc99ec0d5d54e80a17202e97. Read-only source audit; final Git status clean. Owner: plugin JS backend, UI, native entry/legacy bridge, launch/build/package scripts. Shared `native/AppEngine` implementation excluded and owned by another lane.

### Findings

<a id="s01"></a>

### S01 — P2 / High confidence: concurrent creates can exceed the catalog hard limit and make startup/recovery fail

Source: `plugins/apple-foundation-evals/server/store.mjs:91-93`, with failure at `:60`. The transaction worker holds a separate record lock for each UUID (`server/suite-transaction.mjs:15-17`), while create admission counts the whole directory and then writes without a catalog lock. At 4,999 records, simultaneous creates for different IDs can both observe spare capacity and commit. `recordNames` then rejects all enumeration above 5,000, including startup and recoveryPage's enumeration (`server/catalog-recovery.mjs:14`).

Isolated Linux/macOS-neutral Node storage repro: create Store in a fresh /tmp root, populate 4,999 .json paths, concurrently call eight `Store.write('projects', {id:randomUUID(),name:...})`. Actual result: two successful creates, six rejected "Local history is full", directory count 5,001. `recordNames('projects')` then rejected "Local history exceeds 5000 entries; archive old records". Each Store.write uses its real OS-locked worker, so this exercises cross-process mutation. Two plugin servers sharing their default store can reach the same interleaving. Temporary fixture removed afterward.

Fix: serialize new-record catalog admission with a stable catalog-wide lock and consistent lock order (or replace the hard enumeration gate with bounded recovery that remains usable above the count). Keep per-record CAS. Test simultaneous distinct creates at 4,999 valid records, assert count <= 5,000, and assert startup/recovery remains available.

<a id="s02"></a>

### S02 — P2 / High confidence: successful suite export can exceed the import tool's JSON limit

Source: `plugins/apple-foundation-evals/server/catalog.mjs:32` (`json: text(16777216)`), `server/references.mjs:60` (16,000,000 allowed base64 bytes), and `server/workspace.mjs:56` (suite definition plus referenceFiles serialized together). The independently allowed <=1 MiB suite can push a valid portable bundle beyond the JSON tool bound. UI imports use that JSON argument (`ui/app.js:1139-1141`).

Isolated temp-store repro: a valid 986,808-byte normalized app suite, 30 cases with 31,000-character prompts, three stored text references of 4,999,998, 4,999,998, and 1,999,998 bytes with correct SHA-256 metadata and 16,000-character extracted text. `eval_export_suite` succeeded and produced 16,991,294 JSON characters. Passing its exact `.json` to `eval_import_suite` rejected `arguments.json must be a valid string` before extraction. All file and aggregate encoded limits were respected. Temporary fixture removed afterward.

Fix: align import, export, and transport bounds for the complete bundle, or reject oversized exports with an actionable combined limit before claiming success. Add near-boundary export/import roundtrip coverage that includes a near-1 MiB suite plus reference bytes.

<a id="s03"></a>

### S03 — P2 / High confidence: portable legacy trace preview requires the originating project to exist locally

Source: `plugins/apple-foundation-evals/server/workspace.mjs:118` applies `await project(...)` even for `persist=false`; `:76-78` exports the legacy public envelope including its source projectId. The .afevaltrace file entrypoint calls `eval_parse_trace` with only JSON (`ui/app.js:1553`). A valid exported flat-suite trace from a non-default project cannot be opened read-only in a new store because its source project is not present there.

Two fresh temp-store repro: source creates a custom project, saves a legacy flat suite under it, imports one valid completed terminal fixture run and exports it through `eval_export_run`; destination `eval_parse_trace({json: exported.json})` rejects `Project not found`. Destination saved-run count stayed zero. UI's explicit import flow can override the project, but ordinary file preview cannot. Temporary fixture removed afterward.

Fix: separate read-only evidence parsing from local ownership admission. A preview should preserve or display external project metadata without requiring a matching local project; persistence can remap to a chosen/default local project. Test export from a custom source project -> fresh-store file preview, asserting content preserved and no writes.

<a id="s04"></a>

### S04 — P2 / High confidence: catalog recovery deadlocks UI teardown even when no edits need saving

Source: `plugins/apple-foundation-evals/ui/app.js:1572` pauses autosave on recovery; `:1644-1647` awaits flush before disposing it. `ui/autosave.js:13` waits on the pause before even checking dirty versions. The recovery pause is only released on a successful workspace result (`ui/app.js:1579`), so closing an oversized workspace never answers `ui/resource-teardown` or disposes its services.

Confirmed at both helper and actual UI integration boundaries: a clean autosave pause -> flush remained pending with zero save calls, resumed only after pause release. Then bundled the unchanged actual `ui/app.js` entry in memory with React and JSDOM, accepted a catalogRecovery result, and delivered JSON-RPC `ui/resource-teardown` from its parent window source. Actual observation after 100 ms: `{recoveryVisible:true,teardownReplied:false,disposed:false}`. Manually disposing autosave released the handler and yielded `{teardownReplied:true,disposed:true}`. No actual browser or source edits; temp bundle removed.

Fix: make teardown explicitly handle recovery's pause (clean flush may finish without waiting; dirty recovery drafts need an intentional safe closing policy) and always release/dispose owned services. Add integration coverage entering recovery then requesting teardown, with clean and pending-draft cases.

<a id="s05"></a>

### S05 — P3 / High confidence: documentation points to the wrong default storage directory

`plugins/apple-foundation-evals/README.md:88` states `~/Library/Application Support/Apple Foundation Evals Codex/`, but `server/store.mjs:10` and `scripts/launch.mjs:62` default to `~/.local/share/apple-foundation-evals`. Correct backup/recovery documentation. This is lower severity than the four P2 issues.

### Coverage and evidence

Pass one traced MCP request validation/dispatch, store record identities and revisions, transaction worker framing, guardian lease admission/cancellation, terminal run/experiment publication and recovery, suite/run/case/reference import/export, workflow CAS, UI navigation/autosave/polling/imported previews, legacy native request/result framing, source-hashed native cache/build cancellation, preview host/origin checks, and package allowlist/installed source closure.

Pass two examined adversarial independent record creation at capacity, nearly maximal portable export boundaries, foreign ownership in read-only traces, and recovery/teardown interaction. Findings above are reproduced through real storage/app/UI code with isolated synthetic fixtures. Rejected candidates after tracing current safeguards: result/raw sample mismatches (validation.mjs:96 checks the full envelope); reference path traversal (content-addressed stored-name allowlist); changed-record recovery deletion (locked byte revision check); concurrent suite edits/adoption rollback (record CAS); partial experiment publication exposure (owning experiment commit gate); stale UI response overwrites (workspace scope tickets); orphan compiler descendants (process-group cancellation until stream close); package missing runtime modules (whole server allowlist and extracted-package tests).

Focused existing verification: 63/63 pass, 0 skipped/cancelled. Command: `node --test tests/backend-shared-store.test.mjs tests/backend-run-recovery.test.mjs tests/backend-import-integrity.test.mjs tests/backend-import-consistency.test.mjs tests/transaction-framing.test.mjs tests/catalog-recovery.test.mjs tests/shutdown.test.mjs scripts/tests/native-build-process.test.mjs scripts/tests/package.test.mjs`. Full output: `/tmp/intents-launch-review-plugin-tests.log`. Package tests rebuild generated UI; checked-in output matched and final Git status remained clean.

Supplementary verification: 71/71 pass, 0 skipped/cancelled. Command: `node --test tests/workspace-state.test.mjs tests/polling-recovery.test.mjs tests/suite-form-regressions.test.mjs tests/catalog-recovery-ui.test.mjs tests/backend-workflows.test.mjs tests/backend-case-import-content.test.mjs` -> `/tmp/intents-launch-review-plugin-supplement.log`.

Gaps: no live Foundation Models inference, macOS native compilation, actual Codex hosted UI/file-opening verification, physical device, or public release qualification in this lane. Shared AppEngine internals deliberately excluded; source and isolated Node/JSDOM evidence are not live-provider or rendered-browser proof.


Exact isolated repro outputs:

```text
Capacity: {"writes":["Local history is full; delete or archive old records","Local history is full; delete or archive old records","Local history is full; delete or archive old records","ok","Local history is full; delete or archive old records","Local history is full; delete or archive old records","ok","Local history is full; delete or archive old records"],"count":5001}
catalog error: Local history exceeds 5000 entries; archive old records
Roundtrip: {"storedSuiteBytes":986808,"exportedJsonChars":16991294,"importToolJsonMaximum":16777216}
roundtrip error: arguments.json must be a valid string
Portable trace: file preview error: Project not found
saved destination runs: 0
Actual UI: {"recoveryVisible":true,"teardownReplied":false,"disposed":false}
{"afterManualAutosaveDispose":{"teardownReplied":true,"disposed":true}}
```

## Performance and code quality

Snapshot: `f26880d16aaedf4fdc99ec0d5d54e80a17202e97` in `/Users/coryparry/Developer/Projects/Intents`. Working tree was clean before and after inspection. No repository edits, native builds, or provider calls.

Two passes completed: (1) structural survey of app/store projections and persistence, canonical shared-engine membership and intentional variants, ProductionEvals storage/report/index traversal, plugin store/listing/polling, and associated tests; (2) source tracing of candidate hot paths and a bounded actual-API plugin read-count probe. Findings below are performance/quality issues; no line-count or style-only findings.

<a id="q01"></a>

### Q01 — P2: Review rows rebuild and rehash the entire saved sample catalog

Primary location: `FoundationEvals/FoundationEvals/Views/ReviewJudgeChecksPane.swift:59` (also line 36).

Trigger: Open Reviewed examples with many judge examples and saved run samples. The `ForEach(examples)` row independently evaluates `store.reviewSamples.first`. `FoundationEvals/FoundationEvals/Stores/EvaluationStore+Review.swift:5-6` has an uncached computed getter; every access invokes `EvaluationReviewWorkflow.samples`. That method sorts all relevant runs and computes a source digest for every sample (`Services/EvaluationReviewWorkflow.swift:12-19`). Each digest canonical-encodes the complete `run.subjectEvidence` as well as the sample (`:31-48`, `:323-324`). The snapshot includes all cases and attachment text (`Models/DevelopmentWorkflowModels.swift:493-509`). The store is main-actor isolated (`Stores/EvaluationStore.swift:13`).

Consequence: E judge-example rows and S history samples cause E*S digest computations, each repeating the corresponding run's full evidence serialization, synchronously in UI work just to display names. For example, 100 examples and 1,000 samples imply 100,000 complete source encodes/hashes per body evaluation. Ordinary Samples search also recalculates the expensive computed projection at multiple call sites (`Views/SuiteReviewView.swift:61-77,101,113,120,126`); currentness checks separately rehash the full evidence via `FoundationEvals/FoundationEvals/Services/EvaluationReviewWorkflow.swift:103-105` and `FoundationEvals/FoundationEvals/Models/DevelopmentWorkflowModels.swift:520-521`. Native latency was not measured; the repeated work and its actor are source-proven.

Improvement: Materialize/index immutable review sources by run/sample identity when source evidence changes, and resolve rows from that index. At minimum compute one projection and lookup dictionary for a view evaluation. Cache per-run integrity checks rather than rehashing the same snapshot for each annotation. Preserve the existing source-digest representation so saved human reviews do not become stale.

Regression evidence to add: An injected digest counter or indexed-projection contract with multiple runs/examples should prove that repeated name lookups do not regenerate the catalog; verify invalidation after actual evidence mutation and continued digest stability after reassessment. Existing `EvaluationReviewWorkflowTests` and legacy migration tests verify ordering, evidence binding and currentness on small fixtures, not this work amplification.

Confidence: High. Source proof, no native runtime benchmark or visible-stall claim.

<a id="q02"></a>

### Q02 — P2: Plugin status refresh rereads every terminal response and trace twice

Primary location: `plugins/apple-foundation-evals/server/app.mjs:229-233`.

Trigger: Keep an evaluation active while substantial terminal run history exists. UI refresh requests `eval_list_runs` (`ui/app.js:757-763`); the active poller repeats after 1,800 ms (`ui/polling.js:5-14`, wired in `ui/app.js:802-808`). `EvaluationApp.runs()` first calls `recover()`, which scans every full run to project only id/status/ownerPid (`server/app.mjs:94`), then scans them again to build summaries (`:233`). `Store.list` projects only after `scan` reads/parses the full record (`server/store.mjs:66-79` and `:39-48`). Summary additionally canonical-hashes the whole public run (`server/app.mjs:31`; `server/app-format.mjs:148-153`). These tool calls share a serialized queue (`server/app.mjs:165-177`), including cancel-run dispatch (`:206`).

Consequence: Poll cost and time before queued controls can dispatch grow with all stored response/trace bytes, including immutable runs in other projects, rather than active progress. The store permits 5,000 entries (`server/store.mjs:56-61`). The compact-summary response limit does not bound the underlying bytes read.

Actual-API probe: Created a disposable store under the system temporary directory, using the real `EvaluationApp` and `Store`, with 50 terminal runs, each having eight synthetic 16,000-character responses. Wrapped `store.readRecord` only to count returned raw bytes and invoked `app.runs()` twice. Both calls returned 50 summaries and performed **100 run reads / 12,904,100 bytes**; measured warm elapsed times were 36 ms and 19 ms. No native runner was invoked. At the permitted 5,000 equivalent entries the same algorithm entails about 1.29 GB of read/parse input per poll (arithmetic extrapolation, not a measured large-history timing). Temporary fixtures were removed.

Improvement: Keep lightweight run metadata/revision summaries separate from immutable response evidence, or cache projections with cross-process-safe invalidation; enumerate/recover only potentially running records during polling and request the selected run's live progress separately. Preserve startup recovery and external-write detection rather than deleting those checks.

Regression evidence to add: Count full record reads/bytes across repeated unchanged status calls with terminal history; assert bounded active-status work, detection of newly published terminal/external records, stale-suite health correctness and interrupted-run recovery. Existing catalog tests check byte limits and recovery correctness, but no repeated-poll I/O bound was found.

Confidence: High for repeated reads; source-derived scalability/control-latency consequence, with bounded runtime proof above.

### Coverage and discarded suspicions

- Surveyed `EvaluationStore`, review views/workflow/models, workspace persistence/loading, editor performance tests; shared source map/provenance tests and selected engine model/analysis algorithms; ProductionEvals codec/dataset reader/record paging/report/progress/execution surfaces; plugin app/store/workspace/format/poller and relevant backend/catalog tests.
- Did not treat the 5,645-line store as a finding by itself. Several proposed extractions would be preferences without a separately established defect.
- Did not flag app/plugin file-name duplication as drift: canonical ownership is explicit in `script/shared_app_sources.json`, former shared app copies are absent, and noncanonical variants have intentional provider/platform differences. A full semantic parity audit was outside this lane.
- Did not flag swallowed cleanup errors or intentional malformed-evidence rejection without a proven lost diagnostic/data consequence. `loadRuns` reports malformed individual run files, so the initial suspicion of silently dropping corrupt history was discarded.
- Production indexed dataset reads, source-aware reports and full integrity verification are deliberate. Some pagination/report paths scan history, but no independently reproduced actionable defect was established here. No generic rewrite or weakened integrity check is recommended.
- Test inspection found meaningful behavioral fixtures; source contract tests alone were not reported as misleading without a concrete missed behavior.
- No Apple provider/device/UI performance qualification, profiler capture, native tests, package builds, or broad test execution was performed. Functional correctness is covered by other review lanes.

## Document quality evidence and verification

Snapshot: `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`. Read-only repository review; no builds, providers, or repository edits. Two passes covered baseline contracts/tests, then adversarial corpus and semantic ledger boundaries.

<a id="d01"></a>

### D01 — P2: Report regressions never run in hosted CI

- Files: `script/test_document_quality_report.py:1`, `script/test_document_semantic_report.py:1` (test placement), plus imports at quality test lines 10–13, semantic test line 6, and `script/document_quality_report.py:7`.
- Trigger: ordinary/full CI discovers only `script/tests/test_*.py` (`script/ci_routes.py:267-272`), and its runner accepts only `script.tests.test_*` module names (`script/ci_run_tests.py:28-33`). Both new modules are instead under `script/`.
- Impact: all 20 report-integrity regressions are silently absent from even full CI. Running their natural root module names directly also raises `ModuleNotFoundError: document_semantic_report`, so merely adding their current names to routing is insufficient.
- Confidence: high; executed reproduction below.
- Fix/test: move into `script/tests`, use imports that work from repository-root module execution, and add them to relevant routing/dependency maps. Confirm the inventory includes them and `ci_run_tests.py python` executes all 20.

```bash
python3 - <<'PY'
from script.ci_routes import python_test_inventory
from script.ci_run_tests import run_tests
names = ['script.test_document_quality_report', 'script.test_document_semantic_report']
print('Discovered:', sorted(set(names) & python_test_inventory()))
try:
    run_tests('python', names)
except ValueError as error:
    print(type(error).__name__ + ': ' + str(error))
PY
python3 -m unittest script.test_document_quality_report script.test_document_semantic_report
PYTHONPATH=script python3 -m unittest script.test_document_quality_report script.test_document_semantic_report
```

Observed: `Discovered: []`; runner rejects names; direct root unittest errors on both imports; adding `PYTHONPATH=script` executes 20/20 successfully.

<a id="d02"></a>

### D02 — P2: Incomplete corpus and impossible slot ledgers can pass generation qualification

- File: `script/document_quality_report.py:99-101`, `:131`, and `:82-83`; semantic corroboration at `script/document_semantic_report.py:101-104` and `:112-118`.
- Trigger: the report compares summary counts only to the ledger; it never checks the manifest's complete document set or requested total. Slot identities need only be unique, with no bounded contiguous sequence. The semantic layer likewise checks surfaced rows only, leaving missing noncandidate batches and arbitrary invalid rejected receipts unchecked.
- Impact: an incomplete or mixed evidence set can claim `generation_gate_passed: true`, and reported yield can omit failed attempts. This violates the documented attempt-completeness guarantee. Semantic admission does not close the hole for current generation versions.
- Confidence: high; mutated only isolated existing test fixtures in reproduction below.
- Fix/test: require summary document/requested totals to match the manifest; require every manifest document in the ledger and bounded contiguous slots following the harness's early-stop policy; reconcile semantic batch identities with outer attempts and validate evidence-bearing rejection receipts. Add regressions for omitted documents, altered request counts, slot gaps/out-of-range slots, and missing/orphan semantic batches.

```bash
PYTHONPATH=script python3 - <<'PY'
import json
from script.test_document_quality_report import QualityReportTests
f = QualityReportTests(); f.setUp()
try:
    run = f.directory
    f.run_report()
    labels = json.loads((run / 'review-template.json').read_text())
    for label in labels.values():
        for key in ['supported', 'useful_distinct', 'rubric_correct', 'acceptable_without_edits']:
            label[key] = True
    labels_path = run / 'labels.json'
    labels_path.write_text(json.dumps(labels))
    manifest = json.loads((run / 'input.json').read_text())
    sources = [json.loads(x) for x in (run / 'sources.jsonl').read_text().splitlines()]
    for i in [10, 11]:
        manifest['documents'].append(dict(manifest['documents'][0], id=f'document-{i}'))
        source = dict(sources[0], name=f'document-{i}.txt')
        sources.append(source)
        (run / source['name']).write_text('Source')
    (run / 'input.json').write_text(json.dumps(manifest))
    (run / 'sources.jsonl').write_text('\n'.join(map(json.dumps, sources)))
    result = f.run_report(labels_path)
    print('Manifest documents/requested:', len(manifest['documents']), sum(d['requested'] for d in manifest['documents']))
    print('Reported documents/requested:', result['documents'], result['requested'])
    print('Incomplete corpus generation gate:', result['generation_gate_passed'])
    rows = [json.loads(x) for x in (run / 'attempts.jsonl').read_text().splitlines()]
    rows[0]['slot'] = 999
    (run / 'attempts.jsonl').write_text('\n'.join(map(json.dumps, rows)))
    labels['document-0:999'] = labels.pop('document-0:0')
    labels_path.write_text(json.dumps(labels))
    print('Impossible slot generation gate:', f.run_report(labels_path)['generation_gate_passed'])
finally:
    f.tearDown()
PY
```

Observed: manifest 12 documents / 120 requested, reported 10 / 100, gate true; slot 999 replacing slot 0 also gives gate true. Candidate bytes and label digests stay unchanged.

Current semantic boundary corroboration:

```bash
PYTHONPATH=script python3 - <<'PY'
import tempfile
from pathlib import Path
from script.test_document_semantic_report import SemanticEvidenceTests
from document_semantic_report import semantic_metrics
f = SemanticEvidenceTests(); f.setUp()
row = dict(documentID='doc', slot=999, candidate=f.case, semanticReview=f.review, outcome='surfaced')
event = dict(batchID='doc:999', attempt=1, outcome='accepted', review=f.review, candidateDigest=f.review['candidateDigest'])
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory); f.write_run(path, [event])
    missing = dict(documentID='doc', slot=1000, outcome='semantic_rejection_or_unsupported')
    print('Missing rejection batch gate:', semantic_metrics(path, [row, missing])['semantic_review_gate_passed'])
    invalid = dict(batchID='doc:999', attempt=1, outcome='rejected', review={'garbage': True}, candidateDigest='invalid')
    f.write_run(path, [invalid, dict(event, attempt=2)])
    print('Invalid rejected receipt gate:', semantic_metrics(path, [row])['semantic_review_gate_passed'])
PY
```

Both semantic-review gates are true. Semantic-controls gate correctly remains false when controls are omitted; that separate frozen-control check does not reconcile the run ledger.

### Other validation and boundaries

- Baseline: all 20 report tests pass with `PYTHONPATH=script`.
- Retained `/private/tmp/intents-pr177-acceptance-replay-20261027`: all ten historical receipts validate; terminal exit is 0.
- Retained `/private/tmp/intents-pr177-acceptance-semantic-20261027`: all 22 semantic receipts validate; terminal exit is 65, so this is not a successful combined campaign. No historical terminal failure was relabeled as success.
- Those historical snapshots differ from current judge client/document judge and semantic reviewer/harness sources; they are historical evidence only. The docs correctly keep broad-corpus and release qualification unfinished.
- Rejected hypotheses: raw-vs-structured semantic verdict tampering, sibling-context substitution for surfaced drafts, stale summary generation-version bypass, duplicate outer attempts, missing terminal success, and cross-runtime/source-hash control reuse are already blocked by existing checks/tests.
- The runner snapshots fresh inputs and exits with xcodebuild's status; no additional validated runner finding. No heavy/native builds or live-provider reruns were performed.

## Document application coverage and rejected hypotheses

Snapshot: f26880d16aaedf4fdc99ec0d5d54e80a17202e97. Repository was clean at start and end. Read-only; no native builds or live model/provider calls.

### Validated findings

See D01 and D02 above for exact lines, executed reproduction commands, confidence, fixes and regression-test suggestions.

1. P2, high confidence: report tests are excluded from CI discovery and fail the standard repository-root module-import convention. All 20 only run after adding `PYTHONPATH=script`. Locations: `script/test_document_quality_report.py:11-13`, `script/test_document_semantic_report.py:6`, `script/ci_routes.py:267-272`, `script/ci_run_tests.py:28-33`.
2. P2, high confidence: generation qualification does not reconcile the complete manifest or enforce bounded/contiguous slot ledgers. Manifest 12 documents/120 requested can qualify using only 10 documents/100 requested. Slot 999 can replace slot 0 and still qualify. Current semantic validation skips noncandidate rows and accepts a missing rejection batch or invalid rejected receipt before an accepted receipt. Locations: `script/document_quality_report.py:82-83`, `:99-101`, `:131`; `script/document_semantic_report.py:101-118`.

### Two-pass application coverage

Pass 1 traced source import (PDF/text/Markdown selection, byte/page/passage/character bounds, Unicode normalization and exact citation matching), draft save/recovery and cancellation ownership, generation token admission and bounded retries, candidate/reference separation in two-stage semantic review, receipt digests and sibling-question invalidation, human acceptance/publication, archive portability/provider reset, source copying into runs and scoring/reassessment.

Pass 2 checked adversarial missing/duplicate/unsupported evidence, moved/removed context, stale candidate/sibling receipts, interrupted work, malformed verdicts, duplicate-fact yield, local isolated-rubric scoring, exact/semantic mixtures, external evidence approval and capacity admission, archive identity conflicts and production/plugin conversion rejection. Reviewed document unit/persistence/semantic/judge-isolation/quality/UI tests. No additional confirmed application defect met reporting confidence.

Specific protections checked: answering gets source plus question without reference/rubric; document context is strict inline and is never fitted away; full original source is required for semantic review; late cancellation cannot persist acceptance; failed semantic transport stops the batch; current policy/content digests gate receipt reuse; source-only exports clear provider/judge bindings and imported cases lose review acceptance; store suite creation validates and preserves retry identity.

### Proof boundaries and rejected hypotheses

No fresh native test execution, interactive screenshots, PDF runtime extraction, live generation, live semantic/scoring quality or external-provider behavior was established by this read-only lane. Parent owns shared verification. Historical retained quality snapshots differ from current judge/document/semantic sources; old receipt validation is not current release qualification.

Rejected as already blocked or intentional: raw-vs-structured receipt tampering, surfaced sibling-context substitution, missing terminal success, cross-runtime/source-hash control reuse, reference/rubric leakage into answering, silent context truncation, provider-binding transfer on archive import, stale acceptance after content edits, and duplicate outer ledger identities. Full-source removal being refused during semantic acceptance is intentional source-authority protection; the normal Cases editor permits later explicit human reacceptance as documented.

Potential upper-bound draft-history growth and malformed duplicate-ID archives were considered but not promoted without a native user-flow reproduction; neither is included as a validated finding.

## CI selection and release qualification

Source: f26880d16aaedf4fdc99ec0d5d54e80a17202e97. Checkout remained clean. Read-only scope: workflows; release/build/install/update scripts; CI routing, gates, test policy, signing; release docs. Document quality detector/report scripts excluded.

### Findings

<a id="c01"></a>

### C01 — P2: Installer publication does not require production package recovery/protocol tests
- Location: `script/verify_release_source.sh:11-20`; `script/release_validation.py:12-16`; supporting `.github/workflows/production-evals.yml:33-38`, `Package.swift:48-55`.
- Trigger: Ordinary CI succeeds at the release source while the separate Production eval fixtures workflow fails, or a version-only release source has no production workflow at all. The packager checks only ci.yml, so publication can continue.
- Impact: ProductionEvals is embedded in the shipped app, but its dedicated recovery/capacity tests and real worker protocol/exit fixture are outside the enforced installer qualification. Green source release gates do not establish that these tests passed for the exact packaged source.
- Confidence: High for missing enforcement. No claim that current production tests fail or that a broken installer was published.
- Evidence: root Package.swift adds production runtime as a target but has no ProductionEvalsTests test target; those tests belong to the nested package. ci.yml has no nested package/worker protocol command and never calls production-evals.yml. Source verifier only requests ci.yml success and three required job names. Isolated Python call to validate_checks also accepts the three successful core jobs plus an extra failed fixtures job, showing the bounded contract. Existing orchestration tests cover failing/missing core gates but no failed independent production workflow.
- Fix: Execute reusable production fixture qualification at the exact immutable release source (or integrate it into the terminal ci.yml gate) and require success before signing/publication. Version-only release commits need qualification too, so requiring an existing path-filtered push run alone is insufficient.
- Test: successful ordinary source CI plus failed/missing production fixtures must block release; passing exact-source production fixtures permits it.

<a id="c02"></a>

### C02 — P2: Affected PR checks omit the CLI signal cleanup integration suite
- Location: `script/ci_routes.py:498-500`; supporting `Tests/MacIntentTestingCLITests/NativeTestsSignalTests.swift:7-26`.
- Trigger: PR changes `Sources/MacIntentTestingCLI/NativeTestsSignals.swift` (or signal integration in NativeTestsMain.swift) without editing the test file.
- Impact: Router selects only NativeTestsCLITests and no native suites, missing the integration test that directly compiles NativeTestsSignals.swift and proves SIGINT/SIGTERM drain owned children and restore process dispositions. A regression can pass affected PR checks. Main full CI runs the missing suite after merge, so this is a PR coverage gap, not complete repository omission.
- Confidence: High.
- Evidence: Python coverage calls for NativeTestsSignals.swift and NativeTestsMain.swift both yielded swift_suites=[NativeTestsCLITests], native_tests=[]. NativeTestsSignalTests directly compiles the changed production source into its own subprocess fixture. Existing routing regression tests assert the narrower CLI suite selection.
- Fix: Include NativeTestsSignalTests for CLI runtime changes, or use an explicit dependency map which includes it for signals/main and shared CLI helpers.
- Test: route a signals source-only change and assert both applicable suites are selected; retain narrower selection only where source independence is demonstrated.

### Validation

175 targeted Python tests passed in 16.521 seconds:
`python3 -m unittest script.tests.test_release_dispatch script.tests.test_release_validation script.tests.test_package_installer_workflow script.tests.test_update_homebrew script.tests.test_wait_release_ci script.tests.test_release_pr script.tests.test_ci_gate script.tests.test_ci_routes script.tests.test_ci_native_routes script.tests.test_ci_run_tests script.tests.test_ci_native_tests script.tests.test_ci_workflow`

Two passes: first traced normal source-to-package-to-publication and affected check ownership; second challenged draft/source/tag mismatches, protected-script dispatch, selected suite dependency coverage, omitted independent workflows, cleanup and update authenticity. No heavy builds or network used.

### Rejected candidates / boundaries

- Protected-script path bypass rejected: verify_release.sh line 3 enters the control checkout; its separate-source/no-scripts regression passes.
- Draft/tag mismatch and partial-upload publication are fail closed in current scripts and fixture tests. Existing assets are not silently clobbered.
- Installer checksum shape, expected Developer ID team, signed source SHA, architecture, feed URL/key/length, and actual Ed25519 installer signature are checked. These are source/fixture conclusions, not fresh Apple validation.
- UI runner rejects skipped or absent selected methods; native runner rejects zero passed selected target/suite. A general all-skipped portable edge was not promoted without a current affected source trigger.
- Actual signed/notarized DMG, install, upgrade/relaunch, retained user data after upgrade, live GitHub run conclusions/environment protection/signing secrets, Homebrew server acceptance, and live/native model/App Intent qualification remain unverified by this read-only review.

## Final review state

At the end of the original audit, all 34 findings remained open. That review performed no production correction, commit, push, merge, release, or external-service mutation; it added only this Markdown artifact. Its independent consistency/guard review confirmed both P1 findings and added the configured-connection prerequisite for R01. All 34 index IDs and detail priorities matched the reviewed snapshot. The authorized source changes began afterward, as recorded below.

## Authorized remediation — 28 October 2026

Inventory is complete for the supplied 34 unique findings. A later GitHub dependency-alert pass added one distinct maintenance root cause (A01), bringing the remediation inventory to 35 items: 26 Fix now and 9 Fix if cheap; none deferred or ignored. This task concerns the local audit, with no existing PR or GitHub thread inventory identified. The later request to run UI tests on GitHub authorizes committing/pushing this remediation branch and dispatching the existing CI workflow. No existing PR or remote review threads were identified; replies, resolutions, issues, merge, and release remain outside this task.

Triage against `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`: **26 Fix now, 8 Fix if cheap, 0 Defer, 0 Ignore**. All 34 survived current-source false-positive checks; all small items remain bounded enough to implement. The user explicitly authorized fixing every verified finding.

- Fix now: R01, M01, M02, M03, M04, M05, E01, E02, E03, P01, P02, P03, P04, R02, R03, N01, N03, S01, S02, S03, S04, Q01, Q02, D01, D02, C01.
- Fix if cheap, included: M06, E04, E05, P05, P06, N02, S05, C02.

Every real finding retains high confidence, a reachable trigger, ruled-out false-positive explanation, consequence, and prevention recommendation in its detailed audit section. Fix briefs use those current/desired behaviors, keep public evidence/schema/authentication interfaces stable, and accept a change only when its regression demonstrates the desired behavior and preserved adjacent safeguards. Adjacent risks include draft/canonical authority, held-out ownership, legacy compatibility, immutable evidence, cancellation/lifetime joins, and failure propagation.

Implementation and ordinary integrated validation are complete in each owned subsystem. Manual qualification boundaries remain explicit below. The following final independently identified corrections have also been applied:

- R01: validate deterministic baseline approval admission as well as release evaluation.
- R03: invalidate cached calibration after the legacy correction-collection path; preserve reports on failed persistence.
- P01: freeze/revalidate export destination after the blocking store lock.
- P03: preserve unambiguous legacy cohort names containing `=`.
- M01 test fixture: set canonical image sharing false before changing its pending draft.
- E02: add positive image-object and image-array union transport regressions.

Independent stable-scope reviews found these concrete gaps; the implementation owners corrected and re-reviewed them. Other independent scope reviews found no additional material defect. Integrated tests also exposed the app/profile wrapper, managed production-export, restored-session initialization, and queue-ordering integration details recorded in the verification ledger.

Focused lane evidence is retained in `/tmp/intents-fixes-*.md`. Successful hosted CI, integrated results, and remaining qualification boundaries are recorded below. No signed-release or live external-provider qualification is claimed.

### Implementation acceptance ledger

Each row is an implemented fix brief. The audit sections above retain the original trigger, consequence, and false-positive checks. Confidence is high for every retained item. Validation columns name the smallest prevention suites; the final results ledger distinguishes executed evidence from outstanding qualification.

| ID | Desired behavior and acceptance | Stable interface and scope boundary | Prevention coverage | Adjacent risk |
| --- | --- | --- | --- | --- |
| R01 | Validate selected assessments and baseline approval for every scoring mode; keep original-score approval explicit. Incompatible and missing IDs reject; compatible/original approvals pass. | Run/assessment formats remain; evaluator and store admission only. | DevelopmentWorkflow, ReassessmentIntegrity | Legacy semantic contracts and original deterministic baseline scores. |
| M01 | Reject pending draft/buffered prompts before canonical consent; commit the exact inspected policy atomically. Changed destination/images/prompt and write failure leave canonical approval unchanged. | Confirmed MCP revisions/digest unchanged; UI draft approval retained. | MCPAppControl | Credential/destination binding, rollback, and failed-action side effects. |
| M02 | Freeze canonical dataset cases and native execution setup for the supplied revision. Dataset and context match canonical content while a different draft survives. | MCP schema unchanged; native UI still freezes its draft. | MCPAppControl | Image evidence verification and captured-job behavior. |
| M03 | Preserve server-owned regression source for matching case IDs during replacement. Rename/read-replace/reload retains provenance. | Legacy case schema and deletion confirmation unchanged. | MCPProviderConfiguration | Client provenance forgery and deliberate case replacement. |
| M04 | Recognize CRLF terminators without losing configuration source ranges. LF/CRLF install/update/inspection/removal remain valid TOML. | Installer API and managed markers unchanged. | CodexMCPInstaller | Quoted marker examples and unrelated configuration bytes. |
| M05 | Refuse ambiguous unmanaged tails and validate complete proposed TOML. Duplicate-key/table fixtures refuse without changing original bytes. | Managed-block ownership boundary unchanged. | CodexMCPInstaller | Section scope, conflicting ownership and rollback. |
| M06 | Copying manual configuration starts the authenticated connector for this session. Busy/read-only/failure paths preserve state and usable startup. | No automatic TOML mutation in manual fallback. | MCPTransportRegression | Credential privacy, repeated copy, and later-launch behavior. |
| E01 | Profiles own request settings in BOTH app and plugin wrappers; reserve reachable response capacity. Fresh/restored, streamed/ordinary phases observe override or inherited values. | Saved settings unchanged; ordinary nonprofile generation retained. | DynamicProfile, FeaturePersistence | Context budgets, tool policy and judge reservations. |
| E02 | Select unions by complete schema validity before image resolution. Image and nonimage object/array alternatives reach actual dispatch intact. | Tool schema and transport shapes unchanged. | SchemaBoundary, ImageTool | Constraints, definitions, ambiguity and image path privacy. |
| E03 | Preserve short source and bounded preceding context around a reference match. The fee amount remains in the returned annual-fee excerpt. | Lookup response byte cap unchanged. | ReferenceLookupTool | UTF-8 limits and excerpt framing. |
| E04 | Use consistent ranking and excerpt token boundaries. Late ASCII/curly possessive matches anchor at the relevant passage. | Ranking contract retained. | ReferenceLookupTool | Unicode token ranges and punctuation. |
| E05 | Classify malformed JSON envelopes as protocol errors before verdict repair. Malformed envelopes make one request and retain network/protocol attribution. | Valid verdict repair and SSE compatibility remain. | CompatibleJudgeClient | Cancellation, partial usage/cost and valid repair. |
| P01 | Freeze safe external paths across locking; use a typed bounded managed-export API for MCP. Store descendants/alias flips reject; managed export and read/list remain usable. | Public external export guard remains; generated managed UUIDs only. | ProductionWorkflow, MCPAppControl | Symlinks, canonical parent retargeting, retention and source snapshot lock. |
| P02 | Include control mutation identity in optimistic revision. Pause/resume/pause rejects a stale resume; same-state/cost behavior remains stable. | Control JSON and opaque revision length unchanged. | ProductionWorkflow | Replay safety and unrelated cost changes. |
| P03 | Group by typed cohort identity and resolve only unique observed legacy display names. Unambiguous equals-containing keys/values work; actual collisions cannot dilute outcomes. | Public policy/report strings remain compatible. | ProductionWorkflow | Required cohorts, distinct-source counts and legacy policies. |
| P04 | Compare integer count ratios against decimal policy allowance. Exactly 10 points passes a 0.1 limit; adjacent smaller limits still fail. | Policy values and exit-code contract unchanged. | ProductionWorkflow | Tiny allowances and bounded integer products. |
| P05 | Keep latency/cost aggregation finite and fail qualification on unrepresentable charges. Extreme inputs serialize; overflow cannot qualify or poison journals. | Accepted finite inputs and report schemas retained. | ProductionWorkflow | Cost retries, reconciliation and incomplete evidence. |
| P06 | Verify retained immutable bytes before successful import/upload completion reuse. Tamper then retry throws; intact current/legacy reuse succeeds. | Immutable revisions and retry IDs unchanged. | ProductionUpload, ProductionWorkflow | Existing storage damage and no destructive repair. |
| R02 | Expose durable explicit removal for unavailable judge examples. Delete source, remove orphan, enroll/change another case; failed write rolls back. | Human reviews and case-wide held-out ownership retained. | EvaluationReviewWorkflow | No silent held-out reassignment or unrelated review deletion. |
| R03 | Invalidate on source/selection/connection changes and recheck provenance before async publication. Successful changes clear; failed persistence/selection restores prior report. | Calibration report schema retained; UI never displays stale latest statistics. | MCPWorkspaceCompletion, ReassessmentIntegrity | In-flight edits, legacy correction collection and transactional state. |
| N01 | Preserve a usable authenticated snapshot on rediscovery of the same peer. Lost discovery then rediscovery keeps connected features and execution admission. | Pairing/protocol identity remains unchanged. | DeveloperRunnerClientRecovery | Different peers, invitation failure and trust renewal. |
| N02 | Read current Info.plist bytes and validate fresh executable metadata. Same-path rebuild with a new executable/identifier reloads current data. | Synchronous catalog API retained. | MacIntentTesting, ProductIdentity | Traversal, symlinks and product identity binding. |
| N03 | Inspect/hash off actor with owned cancellation, joining and lifecycle rechecks. Main actor remains available; replacement/close/cancel cannot publish stale work. | Sync library API retained; async variant and tracked UI loading added. | MacIntentStore, SubjectLifetime, ProductIdentity | Child-process ownership, cancellation summaries and reentrancy. |
| S01 | Serialize catalog admission with stable catalog-then-record locks. At4999 two writers admit exactlyone;5000plus transient works; real5001/corruption rejects. | Per-record CAS and record budget remain. | backend-catalog-capacity | Lock order, contention deadlines and malformed evidence. |
| S02 | Use one complete portable-bundle byte bound on both import and export. Near-limit successful export reimports; oversized inputs reject before extraction/writes. | Reference limits retained; JSON/transport capacity aligned. | backend-portable-bounds | Escaping, structured input and resource bounds. |
| S03 | Parse foreign read-only traces without resolving their project locally. Custom-project export previews in a fresh store with no writes. | Persisted import still validates/remaps local ownership. | backend-trace-projects | Portable metadata and explicit import selection. |
| S04 | Release only recovery-owned pause during joined teardown; retain failed dirty drafts for retry. Clean/dirty, concurrent close, late recovery, save failure and retry complete safely. | Ordinary mutation-owned autosave pauses preserved. | workspace-publication, ui-route-contracts | Pause-handle ownership, draft loss and resource disposal. |
| S05 | Document the actual default data directory. README agrees with store and launcher. | Runtime default unchanged. | Documentation comparison | Backup/recovery discoverability. |
| Q01 | Project/index review data once, reuse exact digest metadata, and precompute queue sort keys. Digest/order parity plus full10,112-sample paging fixture pass without starvation. | Version2source digest bytes and queue order unchanged. | EvaluationReviewWorkflow | Legacy/Unicode encoding and deterministic ordering. |
| Q02 | Cache bounded run summaries by verified filesystem identity metadata. 50 cold reads then0 unchanged; changed/corrupt/symlink evidence remains detectable. | Changed evidence still rereads/validates; no response cache. | backend-run-catalog | External edits, active-run recovery and serialized controls. |
| D01 | Move report tests into maintained inventory with package-safe imports/routes. Normal CI dispatcher discovers and runs both report modules. | Direct CLI entry points remain supported. | Python report/routing modules | Native report-input routing and accidental zero discovery. |
| D02 | Reconcile complete corpus, requested slots/outcomes and semantic receipts. Missing documents/slots/batches, impossible receipts and bool/int tricks reject. | Independent frozen controls retained; legacy proof limits explicit. | Document quality/semantic modules | Unicode rationale, historical formats and interrupted attempts. |
| C01 | Run production qualification in required source CI and require successful exact-source step evidence. Missing/failed/historical qualification blocks publication; full/version-only runs select it. | Existing terminal gates and immutable release source retained. | CI workflow/gate/release modules | No signing/release bypass and failure propagation. |
| C02 | Route CLI runtime changes to signal cleanup integration coverage. Signals/Main-only changes include NativeTestsSignalTests. | Path-based selection remains explicit. | CI route modules | Subprocess cancellation and narrower independent suites. |

### A01 — compatible development dependency correction

**Fix if cheap; high confidence in the vulnerable-version match, no demonstrated shipped runtime exposure.** GitHub reported five open advisories, all caused by the same nested development dependency: `jsdom` 30.1.2 resolved `undici` 8.11.2 in `plugins/apple-foundation-evals/package-lock.json`. The affected range is `>=8.0.0 <8.12.2`. The targeted lock refresh resolves **8.12.3** within JSDOM's existing `^8.11.2` constraint; only that package's version, archive URL, and integrity fields change. Package declarations and application sources are unchanged.

The five primary advisories concern [redirect/cache disclosure](https://github.com/nodejs/undici/security/advisories/GHSA-4w7w-5xrc-9h26), [custom TLS validation bypass](https://github.com/nodejs/undici/security/advisories/GHSA-2m5v-pch6-74hx), [TLS renegotiation crash](https://github.com/nodejs/undici/security/advisories/GHSA-qrxm-fqhp-jwvm), [WebSocket PONG memory exhaustion](https://github.com/nodejs/undici/security/advisories/GHSA-9fm3-97px-rjf6), and [content-encoding crash](https://github.com/nodejs/undici/security/advisories/GHSA-xjj6-f33q-929c). They are version matches rather than duplicate source bugs.

False-positive/exposure checks: JSDOM is used only in tests; current fixtures load local HTML without remote subresources, custom TLS verification, shared-cache redirect composition, or WebSocket connections. Production server/UI sources do not import JSDOM or this nested Undici, and the plugin package excludes `node_modules` and the lockfile. These facts limit current reachability but do not make the old version safe for future tooling use. No claim is made about Node's independently bundled Undici.

Prevention and acceptance: retain the semver-compatible development constraint and package boundary, verify the three-field-only lock diff, and run the complete Plugin workflow after `npm ci` installs the corrected resolution. The hosted Plugin workflow installed the corrected lock resolution and passed all 313 tests, native protocol checks, UI build, and packaging. The earlier local 313-test run used the previous lock resolution. Alerts on the default branch are not claimed resolved before merge; none were dismissed.

### Integrated validation evidence

**Both final hosted workflows succeeded on source commit `8e3b6f48d058d08e96de89b468c301fe0150f1bc`, branch `codex/prelaunch-review-fixes`:** [CI, including all UI shards](https://github.com/coryparrry/Intents/actions/runs/40690157962), [standalone Plugin](https://github.com/coryparrry/Intents/actions/runs/40690163673). All applicable jobs passed. The optional ten-repetition picker-stability job was intentionally not selected. Superseded preparatory runs were cancelled and are not used as success evidence.

The base remains `f26880d16aaedf4fdc99ec0d5d54e80a17202e97`. The final source manifest records every changed path, including explicit deletions, content hashes, and the two run URLs in `/tmp/intents-prelaunch-fixes-20261028/source-manifest.json`. Later changes to this report alone do not change that tested runtime source.

| Surface | Command or maintained entry point | Final evidence and boundary |
| --- | --- | --- |
| Python scripts, routing, release gates, and report tools | `CI_TEST_SELECTION=<all selected modules> python3 script/ci_run_tests.py python` | Local complete inventory: **407 passed**; GitHub workflow/script checks passed, with the macOS module stage also passing **13 tests**. Both document-report modules are now selected by the maintained inventory. |
| Portable Swift | `swift build --build-tests -j 2`; `CI_TEST_SELECTION='["*"]' python3 script/ci_run_tests.py swift` | **149 passed locally and on GitHub**, across four Swift Testing products: 46, 8, 59, and 36. Separate XCTest harnesses report zero because these cases use Swift Testing; actual executions are retained. |
| Production package | `swift test --package-path Packages/ProductionEvals -j 2` | **All 81 passed together on GitHub** in 230.795 seconds, including the unchanged 10,000-response scale fixture and all new storage/cohort/numeric/evidence regressions. Earlier local failure and correction are retained below. |
| Production CLI and worker integration | `swift build --product intents-evals -j 2`; `python3 script/test_production_evals.py .build/debug/intents-evals` | Build passed and **89 integration assertions passed locally and on GitHub**, using real custom-worker processes, bounded resume, backend isolation, capture/review, export, and timeout. The required qualification step and final aggregate gate both succeeded. |
| Plugin JavaScript and corrected dependency | `npm ci`; `npm test` | **313 passed on GitHub, zero failures/skips**, after installing the A01 lock correction. The earlier local serial run also passed 313; the strengthened capacity case passed again separately and is not added to the unique count. |
| Plugin types and UI bundle | `npm run typecheck`; `npm run build:ui` | Passed locally and on GitHub. Existing bundle-size and dependency `use client` warnings remain warnings rather than failures. |
| Plugin native engine and process protocol | `npm run test:native` | Passed locally and on GitHub: core 53 assertions; AppEngine boundaries; process protocol; app engine 59 assertions; actual workflows 16 assertions; revision/summary 81 assertions. The hosted Mac reported model unavailable and correctly exercised unavailable-model behavior; its app-engine/workflow scripts reported `inference=False`. A local basic model process smoke completed separately. Neither establishes the unrun live qualification suites. |
| Plugin archive | `node scripts/package.mjs <output.zip>` | Passed on GitHub for the tested source; local archive also repackaged after final canonical profile/provenance correction. Packaging success does not establish installation or release. |
| Shared app/plugin provenance | `python3 -m unittest script.tests.test_shared_app_sources` | **7 passed** after final hash refresh, and corresponding hosted script checks passed. Historical source/origin hashes were preserved. |
| Function documentation | `python3 script/docstring_coverage.py --minimum 81`; `python3 script/changed_function_docs.py --base f26880d16aaedf4fdc99ec0d5d54e80a17202e97` | **2,567/2,567 documented (100%)** and **360/360 changed functions documented**, including the new UI regression helpers. |
| Workflow, shell, and examples | Pinned `actionlint@v1.7.12` command from CI; `shellcheck script/*.sh`; `python3 -m compileall -q examples` | Passed locally and in the hosted workflow/script gate. |
| Website | Syntax checks, `node scripts/inline-styles.mjs --check`, `node --test tests/*.test.mjs` | **40 passed** in the original audit; those inputs were unchanged, and the hosted website check also passed. Rendered website qualification was not performed. |
| Native application and ordinary unit tests | Xcode 27.1 `FoundationEvals` scheme; maintained native CI runner | Build passed. Official hosted `.xcresult`: **971 total, 965 passed, 0 failed, 6 explicit opt-in skips**. Core AI resource loading was excluded by manual policy. Raw per-method log counting was one higher; the official bundle count is authoritative. |
| Profile and HTTP streaming regressions | Native profile suites and `runnerStreamingUpdatesRetainCaseNamesAcrossRepetitions()` | Fresh/restored × streaming/nonstreaming × inherited/explicit profile cases passed. The unchanged streaming test **passed on GitHub in 3.568 seconds**; two retained local timeouts were not reproduced on the hosted Mac. No assertion or timeout was weakened. |
| Interactive UI: review and runs | Maintained GitHub `UI tests (review+runs)` shard | Official bundle: **11 passed, 0 failed, 0 skipped**, including orphan removal, replacement collection, persistence, and relaunch. |
| Interactive UI: suite editor | Maintained GitHub `UI tests (suite-editor)` shard | Official bundle: **14 passed, 0 failed, 0 skipped**, including the App Intent catalog and explicit-case controls. |
| Interactive UI: traces | Maintained GitHub `UI tests (traces)` shard | Official bundle: **13 passed, 0 failed, 0 skipped**. Combined hosted UI total: **38 passed**. |
| Git whitespace and delivery | `git diff --check`; complete base-to-head diff review | Passed before each source commit/push; repeated after final report updates. No merge or publication was performed. |

#### Failures retained and corrections verified

- The first priority native run exposed a missed app response wrapper, managed MCP export integration, an incorrect missing-assessment test expectation, and main-actor starvation in the existing 10,112-sample paging fixture. Each had a distinct diagnosed cause. The wrapper now uses profile-owned options; MCP uses the narrow typed managed-export API; baseline tests follow explicit original-score selection; queue sort keys are computed once per sample. Assertions and large-data coverage were retained.
- A broader local native run then isolated restored-session profile initialization: setting an SDK session property before the session bound it did not restore its value. An immutable initial-history flag now owns that phase. A direct SDK fixture, the unchanged eight-case native matrix, and the complete hosted native run confirm the correction.
- The first full local production run passed 80 of 81 methods; its cancellation fixture raced an unrelated 100 ms request deadline under load. Only the private cancellation fixture now uses a 60-second request deadline. Its bounded early-return checks, required `CancellationError`, paused-job/evidence assertions, and eventual executor cleanup remain. Deadline tests keep the original 100 ms default. Independent review confirmed the separation. All three recovery methods passed locally, followed by all 81 production methods passing together on GitHub.
- The local UI run was stopped at the user's request. Eleven methods had passed. The new recovery case proved durable orphan removal, then failed because it searched an accessibility label while macOS exposed the collection control as a menu-button title. The selector was corrected; all activation, durable-state, partition, human-verdict, replacement-ID, and relaunch assertions were retained. Cancellation-related authorization/runner errors are not treated as product findings. The complete corrected UI suite passed on GitHub; no later UI tests ran locally.
- Two local loopback streaming runs reported a 30-second `URLError.timedOut` for one request. No fixture or adapter defect was proved from those logs. A bounded phase-tracing patch was prepared under `/tmp` but never applied or committed. The exact unchanged method passed on GitHub; the local environment cause remains unexplained rather than being relabeled fixed.
- An initial staging omission left the former quality-report test path tracked in the first push. A follow-up commit removed that old location before the final hosted runs. The final source branch includes the complete move; superseded runs were cancelled.

#### Hosted artifacts and visual inspection

Artifacts are bound to the tested commit through GitHub metadata. Downloaded ZIP digests matched GitHub's published SHA-256 values. Official `.xcresult` summaries, per-shard logs, exported screenshot manifests, and source manifest are retained under `/tmp/intents-prelaunch-fixes-20261028/`.

I personally inspected the hosted screenshots for:

- The unavailable calibration source, its Held-out partition, and the visible removal control.
- The replacement after relaunch: `Meeting date`, Development partition, retained failed human verdict, and saved review note.
- The App Intent fixture catalog, action/input fields, and enabled comparison control.

The two recovery screenshots belong to `EvaluationReviewUITests/testUnavailableJudgeExampleCanBeRemovedAndReplacedAfterRelaunch()` in `ui-results-review+runs`; the App Intent screenshot belongs to `MacIntentTestingUITests/testMacIntentTestingShowsInstalledAppAndExplicitCaseControls()` in `ui-results-suite-editor`. Screenshots and unit/source evidence complement rather than replace the completed UI interactions and persistence assertions.

#### Remaining qualification boundaries

Six document/model methods explicitly skipped because live opt-ins were absent: the on-device document run and five document quality/control methods. Core AI resource loading remains excluded by documented manual policy. The opaque-data SDK test is conditionally unavailable in the inspected SDK build. No skipped/manual method is counted as a passing runtime check.

The unexplained local HTTP timeout remains recorded above; the separate-host passing regression establishes the hosted result, not its local cause. Live external-provider qualification, signing/notarization, installation/update verification, and publication were not performed. These source fixes and successful ordinary CI do not constitute a signed-release or live-provider certification.
