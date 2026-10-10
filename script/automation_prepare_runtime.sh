#!/usr/bin/env bash
set -euo pipefail
[[ $# == 0 ]] || { echo 'usage: automation_prepare_runtime.sh' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Only the arm64 macOS runtime builder is qualified.' >&2; exit 2; }
# Build-time downloads only. The archive hash is verified before extracting this private Node.
python3 "$ROOT/Tools/IntentsAutomation/scripts/provision_runtime.py"
AUTOMATION_NODE_BIN="$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin"
export PATH="$AUTOMATION_NODE_BIN:$PATH"
[[ "$(node --version)" == v24.21.0 ]] || { echo 'Pinned private Node version mismatch.' >&2; exit 2; }
AUTOMATION_CACHE="${INTENTS_AUTOMATION_NPM_CACHE:-/private/tmp/intents-automation-npm}"
npm ci --prefix "$ROOT/Tools/IntentsAutomation" --ignore-scripts --no-audit --no-fund --cache "$AUTOMATION_CACHE"
"$ROOT/script/automation_build.sh"
