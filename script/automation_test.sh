#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ $# -lt 2 || "$1" != --scope ]]; then echo 'usage: automation_test.sh --scope portable|sidecar|staging|integration|verify-report [--profile file]' >&2; exit 2; fi
SCOPE="$2"; shift 2
case "$SCOPE" in
  portable)
    [[ $# == 0 ]] || exit 2
    python3 Tools/IntentsAutomation/tests/integration_contracts_test.py
    python3 Tools/IntentsAutomation/tests/bundle_manifest_test.py
    python3 Tools/IntentsAutomation/tests/sdk_lifecycle_patch_test.py
    python3 Tools/IntentsAutomation/tests/e2e_action_budget_patch_test.py
    python3 -m unittest discover -s script/tests -p test_automation_release_pipeline.py
    swift test --jobs 2 --filter IntentsAutomationCoreTests
    ;;
  sidecar)
    [[ $# == 0 ]] || exit 2
    python3 Tools/IntentsAutomation/scripts/verify_dependency_provenance.py
    python3 Tools/IntentsAutomation/tests/dependency_provenance_test.py
    python3 Tools/IntentsAutomation/tests/provision_runtime_test.py
    python3 Tools/IntentsAutomation/tests/offline_harness_test.py
    python3 Tools/IntentsAutomation/tests/mac_snapshot_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_sdk_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_sdk_session_patch_test.py
    python3 Tools/IntentsAutomation/tests/mac_owned_scroll_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_owned_fill_staging_test.py
    python3 Tools/IntentsAutomation/tests/private_mac_source_guard_test.py
    python3 Tools/IntentsAutomation/tests/private_sdk_lifecycle_patch_test.py
    python3 Tools/IntentsAutomation/tests/private_mac_runtime_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_helper_startup_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_daemon_provider_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_daemon_owned_mode_patch_test.py
    python3 Tools/IntentsAutomation/tests/private_mac_daemon_runtime_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_helper_swift_tests_test.py
    python3 Tools/IntentsAutomation/tests/automation_scope_test.py
    python3 Tools/IntentsAutomation/scripts/apply_sdk_lifecycle_patch.py --package Tools/IntentsAutomation/node_modules/agent-device
    python3 Tools/IntentsAutomation/scripts/apply_e2e_action_budget_patch.py --package Tools/IntentsAutomation/node_modules/e2e
    npm --prefix Tools/IntentsAutomation run build
    NODE="$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node"
    [[ -x "$NODE" ]] || { echo 'Verified private runtime is missing; build-time provisioning required.' >&2; exit 2; }
    "$NODE" --test --test-concurrency=2 Tools/IntentsAutomation/dist/tests/*.test.js
    "$NODE" --test --test-concurrency=2 Tools/IntentsAutomation/patches/*.test.mjs
    "$NODE" --test --test-concurrency=2 Tools/IntentsAutomation/patches/mac-ownership/*.test.mjs
    python3 Tools/IntentsAutomation/scripts/run_mac_helper_tests.py --package Tools/IntentsAutomation/node_modules/agent-device
    INTENTS_NODE="$NODE" python3 Tools/IntentsAutomation/tests/private_mac_runtime_import_check_test.py
    if [[ -n "${INTENTS_PRIVATE_MAC_RUNTIME:-}" ]]; then
      HELPER="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["helperRelativePath"])' "$INTENTS_PRIVATE_MAC_RUNTIME/intents-private-runtime.json")"
      AGENT_DEVICE_MACOS_HELPER_BIN="$INTENTS_PRIVATE_MAC_RUNTIME/$HELPER" "$NODE" Tools/IntentsAutomation/tests/private_mac_runtime_import_test.mjs "$INTENTS_PRIVATE_MAC_RUNTIME"
      AGENT_DEVICE_MACOS_HELPER_BIN="$INTENTS_PRIVATE_MAC_RUNTIME/$HELPER" "$NODE" Tools/IntentsAutomation/tests/private_mac_sdk_adapter_test.mjs "$INTENTS_PRIVATE_MAC_RUNTIME"
    else
      echo 'Skipping staged private Mac runtime checks: INTENTS_PRIVATE_MAC_RUNTIME is unset.'
    fi
    ;;
  staging)
    [[ $# == 0 ]] || exit 2
    python3 Tools/IntentsAutomation/tests/staged_mac_ownership_suites_test.py
    NODE="$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node"
    [[ -x "$NODE" ]] || { echo 'Verified private runtime is missing; build-time provisioning required.' >&2; exit 2; }
    PATH="$(dirname "$NODE"):$PATH" python3 Tools/IntentsAutomation/scripts/run_staged_mac_ownership_tests.py
    ;;
  verify-report)
    [[ $# == 2 && "$1" == --profile ]] || { echo 'An exact authorised integration profile is required.' >&2; exit 2; }
    python3 Tools/IntentsAutomation/scripts/verify_qualification.py --profile "$2"
    ;;
  integration)
    [[ $# == 2 && "$1" == --profile ]] || { echo 'An exact authorised integration profile is required.' >&2; exit 2; }
    python3 Tools/IntentsAutomation/scripts/apply_sdk_lifecycle_patch.py --package Tools/IntentsAutomation/node_modules/agent-device
    python3 Tools/IntentsAutomation/scripts/apply_e2e_action_budget_patch.py --package Tools/IntentsAutomation/node_modules/e2e
    npm --prefix Tools/IntentsAutomation run build
    python3 Tools/IntentsAutomation/scripts/run_integration.py --profile "$2"
    ;;
  *) echo 'Unknown scope' >&2; exit 2;;
esac
