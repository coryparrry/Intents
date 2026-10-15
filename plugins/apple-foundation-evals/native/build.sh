#!/bin/sh
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-/tmp/apple-foundation-evals-native}
cache_dir=${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/apple-foundation-evals-swift-cache}
mkdir -p "$cache_dir"
xcrun swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
  -module-cache-path "$cache_dir" \
  "$native_dir/RunnerCore.swift" "$native_dir/FoundationModelsRunner.swift" "$native_dir"/AppEngine/*.swift -o "$output"
