#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 && "$1" == --app ]] || { echo 'usage: automation_verify_bundle.sh --app built-Intents.app' >&2; exit 2; }
python3 "$ROOT/Tools/IntentsAutomation/scripts/bundle_manifest.py" --app "$2"
python3 "$ROOT/Tools/IntentsAutomation/scripts/verify_dependency_provenance.py" --root "$2/Contents/Resources/Automation"
