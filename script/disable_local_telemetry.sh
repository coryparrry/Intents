#!/usr/bin/env bash
set -euo pipefail
# Host-local, current-user preference; no hardware identifier enters app payloads.
defaults -currentHost write com.coryparry.Intents.LocalTelemetry disabled -bool true
# Also exclude older Intents builds that predate the host policy.
defaults write com.coryparry.FoundationEvals optionalTelemetryEnabled -bool false
defaults write com.coryparry.FoundationEvals optionalDiagnosticsEnabled -bool false
python3 - <<'PY'
from pathlib import Path
import shutil
p = Path.home() / 'Library/Caches/com.plausiblelabs.crashreporter.data/com.coryparry.FoundationEvals'
if p.exists():
    shutil.rmtree(p)
PY
printf 'Intents sharing disabled for this account on this Mac. Restart any running Intents app.\n'
