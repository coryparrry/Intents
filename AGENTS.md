# Repository working agreements

## Pull request completion and merge requirements

- Do not merge until every review comment is addressed, all review threads are resolved, and all applicable CI checks pass on the current PR head.
- A request to fix PR review comments includes the full workflow: verify the findings, implement valid fixes, run relevant checks, commit and push, reply with the fix and validation evidence, and resolve the addressed threads. Do not stop after pushing code while leaving fixed comments unresolved.
- For stale or incorrect findings, explain the current-code evidence before resolving the thread. Do not dismiss or resolve a valid finding without completing its fix.
- After each push, refetch GitHub review threads and CI results. Confirm resolved threads report `isResolved: true`; local tests and an earlier commit's checks do not replace current-head CI.
- Do not merge or report the PR as ready while review feedback or CI remains unresolved. Pending, queued, running, failed, cancelled, or timed-out applicable checks are not successful checks. Intentional path-based skips may remain skipped.
- Continue fixing failures within the authorized PR scope. If an external blocker prevents completion, report the exact blocker and leave the PR unmerged.
