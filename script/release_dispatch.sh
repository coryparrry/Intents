#!/usr/bin/env bash
set -euo pipefail
script_directory="$(cd "$(dirname "$0")" && pwd)"
cd "${SOURCE_DIR:-$script_directory/..}"
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER}"
: "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY}"
: "${RELEASE_BRANCH:?Set the default branch}"
mode="${1:?Pass prepare or publish}"
if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Require a vMAJOR.MINOR.PATCH tag and positive build number.' >&2
  exit 1
fi
if [[ "$mode" != prepare && "$mode" != publish ]]; then
  echo 'Expected prepare or publish.' >&2
  exit 1
fi
if [[ "${GITHUB_REF:-}" != "refs/heads/$RELEASE_BRANCH" ]]; then
  echo 'Dispatch installer packaging from the default branch.' >&2
  exit 1
fi
source_commit="$(git rev-parse HEAD)"
# Release Please creates a draft first; GitHub may not create its tag yet.
draft_source="$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --json targetCommitish,isDraft --jq 'if .isDraft then .targetCommitish else error("Release is already published") end')"
if [[ "$draft_source" != "$source_commit" ]]; then
  echo 'Draft release must target the exact checked-out source.' >&2
  exit 1
fi
remote_tag="$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$RELEASE_TAG" \
  --jq ".[] | select(.ref == \"refs/tags/$RELEASE_TAG\") | .ref")"
if [[ -n "$remote_tag" ]]; then
  remote_commit="$(gh api "repos/$GITHUB_REPOSITORY/commits/$RELEASE_TAG" --jq .sha)"
  if [[ "$remote_commit" != "$source_commit" ]]; then
    echo 'Existing remote tag points to different source.' >&2
    exit 1
  fi
fi
if git show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  if [[ "$(git rev-parse "$RELEASE_TAG^{commit}")" != "$source_commit" ]]; then
    echo 'Existing local tag points to different source.' >&2
    exit 1
  fi
elif [[ "$mode" == prepare ]]; then
  git tag "$RELEASE_TAG" "$source_commit"
else
  echo 'Prepare the release candidate before uploading.' >&2
  exit 1
fi
if [[ "$mode" == prepare ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo 'Installer packaging requires a clean checkout.' >&2
    exit 1
  fi
  bash "$script_directory/verify_release_source.sh" "$source_commit"
else
  filename="Foundation-Evals-${RELEASE_TAG#v}-macOS-arm64.dmg"
  bash "$script_directory/verify_installer.sh" dist/release "$RELEASE_TAG" "$source_commit"
  if [[ -z "$remote_tag" ]]; then
    gh api "repos/$GITHUB_REPOSITORY/git/refs" --method POST \
      -f "ref=refs/tags/$RELEASE_TAG" -f "sha=$source_commit" >/dev/null
  fi
  remote_commit="$(gh api "repos/$GITHUB_REPOSITORY/commits/$RELEASE_TAG" --jq .sha)"
  if [[ "$remote_commit" != "$source_commit" ]]; then
    echo 'Remote tag does not match the verified installer source.' >&2
    exit 1
  fi
  # No --clobber: existing assets must never be silently replaced.
  gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    "dist/release/$filename" dist/release/SHA256SUMS.txt dist/release/appcast.xml
  # Asset uploads with GITHUB_TOKEN do not trigger a verification workflow.
  bash "$script_directory/verify_release.sh"
  gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    release_url="$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json url --jq .url)"
    printf '### Release published with verified installer\n\n[%s](%s) at %s. Native macOS 27 testing remains separate.\n' \
      "$RELEASE_TAG" "$release_url" "$source_commit" >> "$GITHUB_STEP_SUMMARY"
  fi
fi
