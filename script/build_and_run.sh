#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    exit 2
    ;;
esac
[[ $# -le 1 ]] || { echo "Expected at most one run mode." >&2; exit 2; }
if [[ -n "${INTENTS_LOCAL_DERIVED_DATA:-}" ]]; then
  [[ "$INTENTS_LOCAL_DERIVED_DATA" == /* && ( ! -e "$INTENTS_LOCAL_DERIVED_DATA" || -d "$INTENTS_LOCAL_DERIVED_DATA" ) ]] || {
    echo "INTENTS_LOCAL_DERIVED_DATA must name an absolute directory." >&2
    exit 2
  }
fi
CONFIGURATION="Debug"
APP_NAME="FoundationEvals"
PRODUCT_NAME="Intents"
BUNDLE_ID="com.coryparry.FoundationEvals"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_HELPER="$ROOT_DIR/script/local_app_build.py"
if [[ -z "${INTENTS_LOCAL_BUILD_LOCK_FD:-}" ]]; then
  exec python3 "$BUILD_HELPER" --run "$0" "$@"
fi
python3 "$BUILD_HELPER" --check-lock "$INTENTS_LOCAL_BUILD_LOCK_FD"
PROJECT="$ROOT_DIR/FoundationEvals/FoundationEvals.xcodeproj"
APP_BUNDLE="$ROOT_DIR/dist/$PRODUCT_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Refuse to replace a running app and return contention status before build publication.
require_stopped_app() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Intents is already running. Finish or cancel its run, then quit it before rebuilding." >&2
    exit 3
  fi
}
require_stopped_app

BUILD_ROOT="$(mktemp -d /tmp/FoundationEvals-build.XXXXXX)"
STAGE_ROOT=""
PUBLISHED=false
# Restore the previous app after interrupted publication, remove owned staging/build paths, and preserve failure status or recovery evidence.
cleanup() {
  result=$?
  # If publishing was interrupted between the two moves, restore the old app.
  if [[ "$PUBLISHED" == false && -n "$STAGE_ROOT" \
    && ( -e "$STAGE_ROOT/previous.app" || -L "$STAGE_ROOT/previous.app" ) ]]; then
    if ! python3 "$BUILD_HELPER" --rename-exclusive "$STAGE_ROOT/previous.app" "$APP_BUNDLE"; then
      echo "Previous app retained for recovery: $STAGE_ROOT/previous.app" >&2
      STAGE_ROOT=""
      result=1
    fi
  fi
  [[ -z "$STAGE_ROOT" ]] || rm -rf -- "$STAGE_ROOT"
  rm -rf -- "$BUILD_ROOT"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
DERIVED_DATA="${INTENTS_LOCAL_DERIVED_DATA:-$BUILD_ROOT/DerivedData}"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"

XCODEBUILD_ARGUMENTS=(
  -jobs 2
  -project "$PROJECT"
  -scheme "$APP_NAME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
)
xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" build
/usr/bin/codesign --verify --strict --deep "$BUILT_APP"

mkdir -p "$ROOT_DIR/dist"
STAGE_ROOT="$(mktemp -d "$ROOT_DIR/dist/.Intents-stage.XXXXXX")"
STAGED_APP="$STAGE_ROOT/$PRODUCT_NAME.app"
ditto "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"
/usr/bin/codesign --verify --strict --deep "$STAGED_APP"
require_stopped_app
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  python3 "$BUILD_HELPER" --rename-exclusive "$APP_BUNDLE" "$STAGE_ROOT/previous.app"
fi
python3 "$BUILD_HELPER" --rename-exclusive "$STAGED_APP" "$APP_BUNDLE"
PUBLISHED=true
# Retain ownership through launch/debug/verification and cleanup, so another
# invocation cannot replace the verified artifact before this invocation uses it.

# Launch the verified published app as a new instance while this invocation retains its build lock.
open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build-only)
    echo "Built and verified: $APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
