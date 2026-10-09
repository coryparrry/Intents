#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ ! -d Tools/IntentsAutomation/node_modules ]]; then
  echo 'Missing build dependencies. Prepare the pinned package-lock with npm ci --ignore-scripts in Tools/IntentsAutomation.' >&2
  exit 2
fi
python3 Tools/IntentsAutomation/scripts/apply_sdk_lifecycle_patch.py --package Tools/IntentsAutomation/node_modules/agent-device
python3 Tools/IntentsAutomation/scripts/apply_e2e_action_budget_patch.py --package Tools/IntentsAutomation/node_modules/e2e
npm --prefix Tools/IntentsAutomation run build
swift build --target IntentsAutomationCore --jobs 2
if [[ "$(uname -s)" == Darwin ]]; then
  SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  SDK_PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
  swiftc -typecheck -module-cache-path /private/tmp/intents-automation-module-cache \
    -target arm64-apple-ios27.0-simulator -sdk "$SDK" \
    -F "$SDK_PLATFORM/Developer/Library/Frameworks" \
    Integration/AutomationHost/*.swift
  swift build --package-path Tools/IntentsAutomation/node_modules/agent-device/apple/macos-helper \
    --scratch-path Tools/IntentsAutomation/.runtime/helper --configuration release --jobs 2
  HELPER_OUTPUT="$(swift build --package-path Tools/IntentsAutomation/node_modules/agent-device/apple/macos-helper \
    --scratch-path Tools/IntentsAutomation/.runtime/helper --configuration release --show-bin-path)"
  mkdir -p Tools/IntentsAutomation/.runtime/helper-bin
  cp "$HELPER_OUTPUT/agent-device-macos-helper" Tools/IntentsAutomation/.runtime/helper-bin/agent-device-macos-helper
fi
