# Repository working agreements

## Scope and source of truth

- Before editing, inspect `git status` and the relevant source, tests, and workflow. Preserve unrelated changes, untracked files, saved evaluations, credentials, and local configuration. Stage only the files belonging to the task.
- Use the current workflow definitions and scripts as the authority for check commands and routing. Start with `README.md`, `docs/ci.md`, and `.github/workflows/ci.yml`; use `docs/releasing.md` for releases. Update affected documentation when behavior or a workflow changes.
- Complete the authorized change through relevant validation. Distinguish implementation, local verification, current-head CI, and published release evidence; none substitutes for the others.

## Implementation standards

- Keep changes focused, follow existing patterns, and prefer the simplest complete solution. Keep UI state, asynchronous work, cancellation, and persistence ownership explicit. Add regression tests for changed behavior and relevant failure cases; use integration tests when a unit test cannot verify the interaction.
- Document new and changed functions with meaningful comments in the language's accepted format. Preserve documentation quality and existing coverage; the CI minimum of 81% is a floor, not a target. See `docs/DOCSTRING_COVERAGE.md`.
- Keep Xcode source membership, `Package.swift`, test discovery, and the dependency maps in `script/ci_routes.py` and `script/ci_native_routes.py` aligned when adding, moving, or renaming source or tests. A selected suite that runs zero eligible tests is not evidence that the change works.
- Shared app/plugin engine sources are owned by the canonical paths in `script/shared_app_sources.json`. Edit those files rather than recreating the former app copies. Keep current source hashes in `plugins/apple-foundation-evals/native/AppEngine/provenance.json` accurate without rewriting historical origin hashes, and verify both consumers.
- Use isolated fixtures and temporary storage for tests. Preserve the user's saved data and credentials; use synthetic or explicitly approved test content instead of private user data. Never expose secrets or private prompts, responses, files, or provider details in logs, telemetry, committed fixtures, or release evidence. Follow `docs/telemetry.md` when changing diagnostics.
- For substantial code changes, obtain an independent subagent review of the stable diff and verify material findings before completion. Keep review scope distinct from implementation work.

## Validation before pushing

- Before every push, determine coverage for the complete proposed PR diff using `script/ci_routes.py`, including uncommitted changes, new files, deletions, and renames. Record the selected Python modules, Swift suites, native tests, UI shards, and additional workflow checks. Do not choose checks from the last commit or from labels such as "docs-only." `AGENTS.md` is currently an unclassified path and selects full coverage; main pushes also run full ordinary coverage.
- Fetch the actual PR target first (`origin/main` below; substitute the PR's base when different). The script's CLI reads GitHub event commit ranges and does not collect local changes. From the repo root, call its `coverage()` API with the union of committed, staged, unstaged, and nonignored untracked paths:

  ```sh
  git fetch origin main
  python3 - <<'PY' > /tmp/intents-prepush-coverage.json
  import json
  import os
  import subprocess
  from script.ci_routes import coverage

  commands = [
      ["git", "diff", "--no-renames", "--name-only", "-z", "origin/main...HEAD", "--"],
      ["git", "diff", "--no-renames", "--name-only", "-z", "--cached", "--"],
      ["git", "diff", "--no-renames", "--name-only", "-z", "--"],
      ["git", "ls-files", "--others", "--exclude-standard", "-z"],
  ]
  paths = {
      os.fsdecode(path)
      for command in commands
      for path in subprocess.check_output(command).split(b"\0")
      if path
  }
  print(json.dumps(coverage(sorted(paths)), indent=2))
  PY
  ```

  Inspect `/tmp/intents-prepush-coverage.json` and run its selections alongside the always-on checks below. NUL-separated output and disabled rename detection preserve unusual filenames and both sides of renames. A failed Git command stops this helper; resolve it before recording coverage.
- Run the always-on checks from `.github/workflows/ci.yml` and `.github/workflows/docstrings.yml` as well as every selected check. The affected-area table below adds to this baseline; it does not narrow it. The current baseline is:

  ```sh
  npm ci --prefix Tools/DocstringCoverage --ignore-scripts --no-audit --no-fund
  python3 script/docstring_coverage.py --minimum 81
  python3 -m unittest script.tests.test_docstring_coverage
  go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 -color -ignore 'label "xcode-27" is unknown'
  shellcheck script/*.sh
  python3 -m compileall -q examples
  (cd website && node --check dist/app.js && node --check dist/demo-data.mjs && node --check dist/demo-interactions.mjs && node scripts/inline-styles.mjs --check && node --test tests/*.test.mjs)
  git diff --check
  ```

- Validate the actual proposed PR title and body as described below. Run all selected Python/macOS modules and Swift/native/UI checks using the maintained CI runners and workflow commands, including any standalone plugin or production-fixture workflow selected by its own path filters. A successful build alone is not a passing test run.
- Treat validation as a push gate: do not commit and push a candidate with failed, missing, unfinished, or unverified required checks. Fix failures and recheck first. If a required environment or tool is unavailable, stop the push and report the exact blocker; do not use a new PR or a remote push to discover whether unchecked changes pass. An explicit user instruction can authorize an exception, which must be disclosed in the PR.
- Reuse a completed passing check only when its relevant source, tests, build inputs, workflow configuration, and environment remain valid. Identify the source and evidence being reused and explain why the new diff does not affect it. Do not call a skipped, blocked, or pending check a reused success. Rerun affected checks after changes or concrete review findings.
- Before pushing, record the required checks, commands, results, and any valid reused evidence. Apply this gate to the first PR push and every subsequent fix; do not wait for GitHub CI to catch locally detectable failures.

| Affected area | Local verification |
|---|---|
| Function declarations or documentation detector | `npm ci --prefix Tools/DocstringCoverage --ignore-scripts --no-audit --no-fund`, then `python3 script/docstring_coverage.py --minimum 81` and `python3 script/changed_function_docs.py --base "$(git merge-base origin/main HEAD)"` (includes test functions); run `python3 -m unittest script.tests.test_docstring_coverage script.tests.test_changed_function_docs` when changing either detector. |
| Python tools | Run the affected `script.tests.test_*` modules with `python3 -m unittest`; use the router's selection. Check example syntax with `python3 -m compileall -q examples` when changing examples. |
| Shell scripts | `shellcheck script/*.sh` and the affected script regression tests. |
| GitHub workflows or CI tooling | Run the affected routing, workflow, gate, and runner contract tests. Validate workflow YAML with the pinned command from CI: `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 -color -ignore 'label "xcode-27" is unknown'`. |
| Portable Swift source | Run the selected suites through `script/ci_run_tests.py swift` with `CI_TEST_SELECTION` set to the router's JSON suite list. This runner enforces discovery, limits Swift Testing concurrency, and applies the explicit manual-test policy. |
| Native app or native tests | Use Xcode 27 on macOS 27 with the maintained `FoundationEvals` scheme; run the affected unit tests. A portable Swift test pass does not verify app-only source. |
| Native UI | Run the affected UI tests on an interactive Mac with a signed runner, and inspect the changed user flow and screenshots. Selected UI tests must execute and pass. See `docs/ci-manual-tests.md`. |
| Production evaluation package or CLI | `swift test --package-path Packages/ProductionEvals -j 2`, `swift build --product intents-evals -j 2`, then `python3 script/test_production_evals.py .build/debug/intents-evals`. |
| Standalone plugin | In `plugins/apple-foundation-evals`, run `npm ci`, `npm run typecheck`, `npm run build:ui`, `npm test`, `npm run test:native`, and `node scripts/package.mjs /tmp/apple-foundation-evals.zip`. For shared engine changes also run `python3 -m unittest script.tests.test_shared_app_sources` from the repo root and affected native app tests. |
| Website | In `website`, run `node --check dist/app.js`, `node --check dist/demo-data.mjs`, `node --check dist/demo-interactions.mjs`, `node scripts/inline-styles.mjs --check`, and `node --test tests/*.test.mjs`; inspect rendered changes. |
| Documentation or metadata only | Check links and examples and validate PR release notes, in addition to the always-on checks and actual router selection. Documentation changes do not waive selected native or UI checks. |

- Build and test from the repository root unless a different directory is specified. Confirm toolchain and runtime prerequisites before starting expensive work; coordinate local builds and interactive tests with other active work. See `README.md` for native commands and signing requirements.
- Keep resource-dependent manual qualification separate from ordinary CI. The explicit opt-ins are in `script/ci_test_policy.py`; live Core AI resource loading and Mac App Intent invocation require their documented environments. Never report them verified from compilation or fixture tests alone.
- Review the final diff and run `git diff --check` before committing. State exact validation commands and results in the PR, including anything blocked or unverified.

## Pull request metadata

- Use a Conventional Commit title and `.github/pull_request_template.md`. Every ordinary PR needs exactly one active, nonempty `BEGIN_COMMIT_OVERRIDE` / `END_COMMIT_OVERRIDE` block, including docs, tests, CI, maintenance, and dependency PRs. Keep markers on their own lines outside HTML comments. Only the trusted Release Please generated PR is exempt.
- Match release entry types to the actual change and PR title: a `feat:` or `fix:` title requires an entry of that type, and a `fix:` PR cannot contain `feat:` entries. Do not introduce breaking-change markers unless explicitly requested.
- Validate the exact proposed title and body with `script.release_notes.validate_pull_request` before creating the PR. For an existing ordinary PR, save and validate its actual metadata:

  ```sh
  gh pr view <number> --json title,body --jq '{pull_request: .}' > /tmp/intents-pr-event.json
  python3 script/release_notes.py validate-event --event /tmp/intents-pr-event.json
  ```

- Revalidate after editing the title or body. A metadata edit triggers the release-note check; it does not prove the full code checks reran. Fix missing or invalid notes in the PR body rather than weakening validation or retrying unchanged inputs.

## Clear feature descriptions and release notes

- The agent owns release-note writing as part of the normal PR workflow. Before pushing a candidate for a new PR, prepare finished release-note entries for its actual changes; include them in the PR's `BEGIN_COMMIT_OVERRIDE` block when opening it. When pushing further changes to an existing PR, update that block to match the final scope and revalidate the actual PR metadata before reporting completion.
- Use the existing Release Please collection automatically: write the release copy during PR work, rather than leaving it for the user or a later release task. This workflow needs no separate scheduled Codex automation, model API call, or API key. Let Release Please assemble the changelog and published notes from the PR entries.

### What belongs in the published changelog

The changelog is for people using the app and its distributed CLI, SDK, plugin, or connector. Each entry must explain an actual change to that experience and answer: **What can I do now, what problem is fixed, or what do I need to do differently?**

| Include | Required content |
|---|---|
| New features | What users can now do, where to find or start it when needed, and why it is useful. Name supported inputs or targets when they define the capability. |
| User-facing fixes | The concrete symptom or failed task users experienced and the resulting behavior. Describe the effect, rather than the helper, guard, or algorithm changed. |
| Workflow and interface changes | The affected screen or task and how using it changes. Include meaningful removals or changed defaults and the replacement or migration step when applicable. |
| Compatibility and upgrade requirements | Affected platforms, versions, integrations, or file formats, plus any action users must take, such as rebuilding an SDK runner. Keep required technical identifiers when users need them to act. |
| Product performance improvements | Which user task becomes faster or more responsive, or uses fewer resources. Include measured numbers only when supported by actual evidence. |
| Product security and privacy changes | The protection or behavior that changes for users, plus any required action. Avoid sensitive implementation or exploit details. |

- Include only behavior implemented in the release being described. Do not announce planned work, unreleased experiments, or features still hidden behind a disabled release flag. State material prerequisites and limitations; distinguish implementation from live-provider, device, installer, or release qualification and never imply checks passed without evidence.
- Cover every independently useful user-facing change in the PR. Combine related implementation details into one entry about the user outcome; do not create a separate entry for each commit, helper, defensive check, or test.

### What stays out of the published changelog

- Exclude CI, signing-pipeline and release-automation maintenance, tests and coverage, refactoring, code cleanup, internal diagnostics and telemetry plumbing, repository or agent instructions, routine dependency bumps, and tooling used only to develop this repository. These belong in the PR description and verification evidence.
- A change to the distributed CLI, SDK, plugin, or connector can be a product change even when its users are developers. Judge the actual effect on those users, rather than treating all developer-facing work as internal.
- If internal work also fixes a product problem, describe only that product problem and its resolution. For example, publish that previously failing PDFs now open, rather than the dependency update that enabled the fix.
- Do not publish vague claims such as "quality improvements," "various fixes," "harden execution," or "improve reliability." Name the affected task and specific improvement. Avoid unexplained acronyms, internal component names, and implementation-only descriptions.

### Write and validate the actual release entries

- Put finished release copy in the actual `BEGIN_COMMIT_OVERRIDE` entries in the PR body, following `docs/releasing.md`. A clear PR summary alone is insufficient: Release Please uses the override entries for `CHANGELOG.md` and published release notes. Each entry must be a self-contained Conventional Commit line that makes sense without the PR, issue, diff, or commit history.
- Automatic filtering in `release-please-config.json` publishes only `feat:`, `fix:`, and `perf:` entries. Use those types only for product changes and match the PR title and actual behavior. Use hidden types such as `docs:`, `ci:`, `test:`, `refactor:`, `build:`, `chore:`, or `deps:` for internal work. A dependency update or revert that fixes a product problem needs a `fix:` entry explaining that problem.
- Every ordinary PR still needs its typed override block, including an internal-only PR. An internal-only PR should contribute no published changelog entry. Never relabel it as a feature or bug fix merely to make it appear in a release. Do not introduce breaking-change markers unless explicitly requested.
- Use plain English and lead with the capability or outcome. Prefer one concise sentence per entry; include a short example or required action when it makes the change understandable. These examples illustrate the expected wording and may be used only when the behavior is actually implemented and verified:

| Avoid | Expected wording |
|---|---|
| `feat: add document suite generation` | `feat: create an evaluation suite from a PDF, Markdown, or text file using From document in the suite manager, then review the proposed questions and answers before accepting them` |
| `fix: invalidate inspection cache` | `fix: show updated App Intent information after rebuilding an app in place` |
| `perf: index review evidence` | `perf: keep large saved-review collections responsive when opening the review queue` |
| `fix: migrate runner transport` | `fix: connect developer runners through authenticated Network.framework transport; rebuild runner apps with the updated SDK and the _intents-v2._tcp Bonjour declaration` |

- Before posting or updating the PR, read its release entries on their own. Check that every entry names a user capability, symptom, or required action; that all independently useful product changes are covered; that related details are combined; and that internal work and unsupported claims are absent. Revise failing entries and validate the exact PR metadata with `script.release_notes.validate_pull_request`.
- Before merging a release PR, inspect the generated notes for these same criteria. Correct unclear source entries and remove internal-only entries. If generation includes hidden internal types, correct the release-note filtering and its documentation before publishing. Do not rely on a later manual rewrite to make the normal PR notes usable.

## Pull request completion and merge requirements

- Diagnose CI from the failed workflow job and step, logs, and retained result bundles. `Compile app and tests` is an aggregate gate; its failure can reflect an upstream metadata, script, native, or UI failure rather than a compiler error. Fix the underlying cause.
- Do not make CI green by weakening assertions, excluding affected paths, lowering coverage, swallowing errors, or skipping failing selected tests. Change a requirement only when the authorized task calls for it and explain the rationale.
- Retry only with a changed condition or a concrete transient-failure hypothesis. Repeated test failures require investigation; missing runner access, approvals, signing, model resources, or interactive desktop access are blockers, not successful checks. Retain the failure evidence and report what is needed.
- Do not merge until every review comment is addressed, all review threads are resolved, and all applicable CI checks pass on the current PR head.
- A request to fix PR review comments includes the full workflow: verify the findings, implement valid fixes, run relevant checks, commit and push, reply with the fix and validation evidence, and resolve the addressed threads. Do not stop after pushing code while leaving fixed comments unresolved.
- For stale or incorrect findings, explain the current-code evidence before resolving the thread. Do not dismiss or resolve a valid finding without completing its fix.
- After each push, refetch GitHub review threads and CI results. Confirm resolved threads report `isResolved: true`; local tests and an earlier commit's checks do not replace current-head CI.
- Do not merge or report the PR as ready while review feedback or CI remains unresolved. Pending, queued, running, failed, cancelled, or timed-out applicable checks are not successful checks. Intentional path-based skips may remain skipped.
- Continue fixing failures within the authorized PR scope. If an external blocker prevents completion, report the exact blocker and leave the PR unmerged.
- Follow `docs/releasing.md` before merging a release PR. Successful source CI does not establish signing, notarization, installation, updater behavior, or live-provider qualification. Confirm the exact source and the relevant release evidence before claiming publication or readiness.
