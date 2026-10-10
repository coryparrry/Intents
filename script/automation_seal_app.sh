#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 && "$1" == --app && "$3" == --identity ]] || { echo 'usage: automation_seal_app.sh --app built.app --identity signing-identity' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$2"; IDENTITY="$4"
[[ -d "$APP/Contents/MacOS" && -n "$IDENTITY" ]] || { echo 'Expected a built app and signing identity.' >&2; exit 2; }
AUTOMATION_NODE_BIN="$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin"
[[ -x "$AUTOMATION_NODE_BIN/node" ]] || { echo 'Prepare the private runtime before sealing.' >&2; exit 2; }
export PATH="$AUTOMATION_NODE_BIN:$PATH"
"$ROOT/script/automation_package.sh" --app "$APP"
"$ROOT/script/automation_sign_runtime.sh" --app "$APP" --identity "$IDENTITY"
# Preserve the application's existing identity, entitlements and designated requirement.
# Node's demonstrated JIT entitlement stays on Node; it is never copied onto the app.
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --preserve-metadata=identifier,entitlements,requirements "$APP"
"$ROOT/script/automation_verify_bundle.sh" --app "$APP"
