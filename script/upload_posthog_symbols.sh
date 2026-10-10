#!/usr/bin/env bash
set -euo pipefail

# Upload symbols only from the exact signed archive. This does not distribute an
# app or publish a GitHub release. Never use --include-source for Intents.
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != --verify-only ) ]]; then
  echo 'Usage: upload_posthog_symbols.sh Intents.xcarchive [--verify-only]' >&2
  exit 2
fi
archive="$1"
app="$archive/Products/Applications/Intents.app"
plist="$app/Contents/Info.plist"
dsym="$archive/dSYMs/Intents.app.dSYM"
[[ -f "$plist" ]] || { echo 'Archive is missing Intents.app.' >&2; exit 1; }
metadata="$(python3 - "$plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
assert p.get('CFBundleIdentifier') == 'com.coryparry.FoundationEvals', 'Not an Intents archive'
for k in ['CFBundleExecutable', 'CFBundleShortVersionString', 'CFBundleVersion']:
    v = p.get(k)
    assert isinstance(v, str) and v and '\n' not in v and '/' not in v, 'Invalid archive metadata'
    print(v)
PY
)"
executable="$(printf '%s\n' "$metadata" | sed -n '1p')"
version="$(printf '%s\n' "$metadata" | sed -n '2p')"
build="$(printf '%s\n' "$metadata" | sed -n '3p')"
binary="$app/Contents/MacOS/$executable"
dwarf="$dsym/Contents/Resources/DWARF/$executable"
[[ -f "$binary" && -f "$dwarf" ]] || { echo 'Archive binary or matching dSYM is missing.' >&2; exit 1; }
codesign --verify --strict --deep "$app"
signature="$(codesign -dvvv "$app" 2>&1)"
printf '%s\n' "$signature" | grep -q '^Authority=Developer ID Application:' || {
  echo 'Symbols require a Developer ID signed Release archive.' >&2; exit 1;
}
app_uuids="$(xcrun dwarfdump --uuid "$binary" | awk '/^UUID:/ { print $2, $3 }' | sort)"
dsym_uuids="$(xcrun dwarfdump --uuid "$dwarf" | awk '/^UUID:/ { print $2, $3 }' | sort)"
[[ -n "$app_uuids" && "$app_uuids" == "$dsym_uuids" ]] || {
  echo 'Archive binary and dSYM UUIDs/architectures do not match.' >&2; exit 1;
}
printf 'Verified Intents %s (%s) symbol UUIDs:\n%s\n' "$version" "$build" "$app_uuids"
[[ "${2:-}" != --verify-only ]] || exit 0

cli="${POSTHOG_CLI_PATH:-posthog-cli}"
command -v "$cli" >/dev/null || { echo 'Install posthog-cli 0.18.10 or later and authenticate for EU project 266962.' >&2; exit 1; }
export POSTHOG_CLI_HOST=https://eu.posthog.com
export POSTHOG_CLI_PROJECT_ID=266962
"$cli" dsym upload --directory "$archive/dSYMs" --main-dsym Intents.app.dSYM \
  --release-name com.coryparry.FoundationEvals --release-version "$version" --build "$build" \
  --info-plist "$plist"
