#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ $# -lt 2 || "$1" != --scope ]]; then echo 'usage: automation_test.sh --scope portable|sidecar|integration|verify-report [--profile file]' >&2; exit 2; fi
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
    python3 Tools/IntentsAutomation/tests/verify_qualification_test.py
    python3 Tools/IntentsAutomation/tests/offline_harness_test.py
    python3 Tools/IntentsAutomation/tests/mac_snapshot_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_sdk_staging_test.py
    python3 Tools/IntentsAutomation/tests/private_mac_source_guard_test.py
    python3 Tools/IntentsAutomation/tests/private_sdk_lifecycle_patch_test.py
    python3 Tools/IntentsAutomation/tests/private_mac_runtime_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_helper_startup_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_daemon_provider_staging_test.py
    python3 Tools/IntentsAutomation/tests/mac_daemon_owned_mode_patch_test.py
    python3 Tools/IntentsAutomation/tests/private_mac_daemon_runtime_staging_test.py
    python3 Tools/IntentsAutomation/scripts/apply_sdk_lifecycle_patch.py --package Tools/IntentsAutomation/node_modules/agent-device
    python3 Tools/IntentsAutomation/scripts/apply_e2e_action_budget_patch.py --package Tools/IntentsAutomation/node_modules/e2e
    npm --prefix Tools/IntentsAutomation run build
    NODE="$ROOT/Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node"
    [[ -x "$NODE" ]] || { echo 'Verified private runtime is missing; build-time provisioning required.' >&2; exit 2; }
    "$NODE" --test --test-concurrency=2 Tools/IntentsAutomation/dist/tests/*.test.js
    "$NODE" --test --test-concurrency=2 Tools/IntentsAutomation/patches/*.test.mjs
    "$NODE" --test --test-concurrency=2 Tools/IntentsAutomation/patches/mac-ownership/*.test.mjs
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
