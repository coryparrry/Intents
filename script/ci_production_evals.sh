#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Qualify the current checkout's production storage, recovery, and CLI protocol.
# Main CI runs this path even when the release commit only changes its version.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4
swift test --package-path Packages/ProductionEvals -j 2
swift build -j 2 --product intents-evals
python3 script/test_production_evals.py .build/debug/intents-evals
