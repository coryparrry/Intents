# Agent-configuration regression evals

This directory has no real-task suite until the team supplies one. The scaffolding is not an evaluation result.

The playbook (pp. 34-35) calls for 20-50 real recent tasks and accepted outcomes. Use `docs/sdlc/templates/eval-case.json` as a schema sketch, tailoring it to the actual runner. Each case needs a prompt, immutable starting state, independently checked outcome, owner, and applicable policy. Keep expected checks out of the agent's mutation scope. Give every case a fresh isolated workspace and approved time/cost bounds.

Run on the adopted schedule and relevant instruction, skill, hook, prompt, model/runtime configuration changes. Compare with a reviewed baseline/threshold. Gate configuration changes according to the actual CI policy and log exact versions and results. A successful model response or zero process exit is not a substitute for independent checks.

Each production incident adds a permanent case. Keep the suite discriminating as models and workflows improve. The suite can run offline on an approved cadence where continuous execution is unsuitable.

Document the runner command, CI trigger, budget owner, result location, and pass policy in the [setup record](../docs/sdlc/setup.md). Keep the eval control pending adoption in the [control register](../docs/sdlc/controls.md) until those prerequisites have been tested.
