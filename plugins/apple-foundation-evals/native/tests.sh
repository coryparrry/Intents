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
python3 "$native_dir/tests/sdk_surface.py"
python3 "$native_dir/tests/provenance.py"
sh "$native_dir/build.sh" "$test_dir/runner"
python3 "$native_dir/tests/protocol.py" "$test_dir/runner" "$@"

python3 "$native_dir/tests/app_protocol.py" "$test_dir/runner" "$@"
python3 "$native_dir/tests/workflows.py" "$test_dir/runner" "$@"

python3 "$native_dir/tests/revision_summary.py" "$test_dir/runner"
