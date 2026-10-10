#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 4 && "$1" == --app && "$3" == --identity ]] || { echo 'usage: automation_sign_runtime.sh --app staged.app --identity signing-identity' >&2; exit 2; }
APP="$2"; IDENTITY="$4"
[[ -f "$APP/Contents/Resources/Automation/runtime-manifest.json" ]] || { echo 'Runtime must be staged first.' >&2; exit 2; }
# Only Node receives its demonstrated JIT entitlement. No library-validation exception.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/Automation/node_modules/fsevents/fsevents.node"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/Automation/node_modules/@esbuild/darwin-arm64/bin/esbuild"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/agent-device-macos-helper"
codesign --force --options runtime --timestamp --entitlements "$ROOT/Integration/AutomationRuntime/Node.entitlements" --sign "$IDENTITY" "$APP/Contents/Helpers/IntentsAutomationNode"
python3 "$ROOT/Tools/IntentsAutomation/scripts/bundle_manifest.py" --app "$APP" --write
printf '%s\n' 'Nested runtime signed. Seal the app using its existing release signing policy, then run automation_verify_bundle.sh.'
