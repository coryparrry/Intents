# Workflow measures

Use existing Git, PR, and CI records. The maintainer can compare the first changes using this workflow once those changes have completed. Measurements and targets are pending that baseline.

| Question | Measure and source |
| --- | --- |
| Where does work wait? | Time from intent draft to acceptance, spec draft to acceptance, and plan acceptance to first implementation checkpoint. Use artifact history and linked review decisions. |
| Does the first candidate meet the change? | Share of first PR heads with all selected checks passing, and number of Important findings that require rework. Use exact-head workflow results and review threads. |
| Does the release evidence hold up? | Time from authorized release PR merge to verified publication, plus release failures and recovery time. Use Release Me, package jobs, GitHub release records, and the incident timeline. |
| Do recurring mistakes decrease? | Count repeat findings and time from incident confirmation to linked permanent regression. Use lessons, fix PRs, and agent-eval results when available. |

Record the observation period, available sources, and gaps. Code volume and agent response counts are outside these measures.
