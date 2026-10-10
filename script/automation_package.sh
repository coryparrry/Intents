#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 && "$1" == --app ]] || { echo 'usage: automation_package.sh --app built-Intents.app' >&2; exit 2; }
APP="$2"
[[ -d "$APP/Contents/MacOS" ]] || { echo 'Expected a built macOS app' >&2; exit 2; }
NODE="$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node"
HELPER="$ROOT/Tools/IntentsAutomation/.runtime/helper-bin/agent-device-macos-helper"
[[ -x "$NODE" && -x "$HELPER" ]] || { echo 'Verified Node and prebuilt helper must be provisioned at build time.' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Intel runtime packaging is unqualified.' >&2; exit 2; }
python3 "$ROOT/Tools/IntentsAutomation/scripts/verify_dependency_provenance.py"
RESOURCES="$APP/Contents/Resources/Automation"
[[ ! -e "$RESOURCES" ]] || { echo 'Automation assets already exist; refusing to overwrite a staged runtime.' >&2; exit 2; }
mkdir -p "$RESOURCES/dist" "$APP/Contents/Helpers"
mkdir -p "$RESOURCES/Notices" "$RESOURCES/HostTemplates"
cp "$ROOT/Integration/AutomationHost/"*.swift "$RESOURCES/HostTemplates/"
cp "$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/LICENSE" "$RESOURCES/Notices/Node-LICENSE.txt"
cp "$NODE" "$APP/Contents/Helpers/IntentsAutomationNode"
cp "$HELPER" "$APP/Contents/Helpers/agent-device-macos-helper"
cp "$ROOT/Tools/IntentsAutomation/package.json" "$ROOT/Tools/IntentsAutomation/package-lock.json" "$ROOT/Tools/IntentsAutomation/dependencies.lock.json" "$RESOURCES/"
cp -R "$ROOT/Tools/IntentsAutomation/provenance" "$RESOURCES/provenance"
cp -R "$ROOT/Tools/IntentsAutomation/dist/src" "$RESOURCES/dist/"
# Offline staging occurs on the release builder; the installed app never runs npm.
npm ci --prefix "$RESOURCES" --omit=dev --ignore-scripts --offline --cache "${INTENTS_AUTOMATION_NPM_CACHE:-/private/tmp/intents-automation-npm}"
python3 "$ROOT/Tools/IntentsAutomation/scripts/apply_sdk_lifecycle_patch.py" --package "$RESOURCES/node_modules/agent-device"
python3 "$ROOT/Tools/IntentsAutomation/scripts/apply_e2e_action_budget_patch.py" --package "$RESOURCES/node_modules/e2e"
python3 "$ROOT/Tools/IntentsAutomation/scripts/verify_dependency_provenance.py" --root "$RESOURCES"
python3 "$ROOT/Tools/IntentsAutomation/scripts/bundle_manifest.py" --app "$APP" --write
printf '%s\n' 'Runtime staged. Nested Developer-ID signing and package qualification are still required.'
