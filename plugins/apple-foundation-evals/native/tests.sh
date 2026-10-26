#!/bin/sh
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/apple-foundation-evals-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cache_dir=${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/apple-foundation-evals-swift-cache}
mkdir -p "$cache_dir"
xcrun swiftc -parse-as-library -module-cache-path "$cache_dir" \
  "$native_dir/RunnerCore.swift" "$native_dir/tests/TestCore.swift" -o "$test_dir/core-tests"
"$test_dir/core-tests"
# Compile the actual engine with a dedicated test entrypoint; request routing remains
# covered by the process protocol tests below.
(
  set -- "$native_dir/RunnerCore.swift" "$native_dir/tests/TestAppEngineBoundaries.swift"
  for source in "$native_dir"/AppEngine/*.swift; do
    case "$source" in
      */AppEngineBridge.swift|*/AppEngineWorkflows.swift) ;;
      *) set -- "$@" "$source" ;;
    esac
  done
  xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 \
    -module-cache-path "$cache_dir" "$@" -o "$test_dir/app-engine-boundary-tests"
)
"$test_dir/app-engine-boundary-tests"
sh "$native_dir/build.sh" "$test_dir/runner"
python3 "$native_dir/tests/protocol.py" "$test_dir/runner" "$@"

python3 "$native_dir/tests/app_protocol.py" "$test_dir/runner" "$@"
python3 "$native_dir/tests/workflows.py" "$test_dir/runner" "$@"

python3 "$native_dir/tests/revision_summary.py" "$test_dir/runner"
