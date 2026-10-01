#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
commit="${1:?Pass the full release source commit}"
if [[ ! "$commit" =~ ^[a-f0-9]{40}$ ]]; then
  echo 'Release source must be a full Git SHA.' >&2
  exit 1
fi
repository="${GITHUB_REPOSITORY:-coryparrry/Foundation-Eval-Labs}"
branch="${RELEASE_BRANCH:-main}"
run_id="$(gh run list --repo "$repository" --workflow ci.yml --commit "$commit" \
  --branch "$branch" --event push --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
if [[ -z "$run_id" ]]; then
  echo "No successful $branch CI run for release commit $commit." >&2
  exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/foundation-source-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
gh run view "$run_id" --repo "$repository" --json jobs > "$work/jobs.json"
python3 script/release_validation.py checks "$work/jobs.json"
