#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION="Debug"
APP_NAME="FoundationEvals"
PRODUCT_NAME="Intents"
BUNDLE_ID="com.coryparry.FoundationEvals"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/FoundationEvals/FoundationEvals.xcodeproj"
BUILD_ROOT="$(mktemp -d /tmp/FoundationEvals-build.XXXXXX)"
trap 'rm -rf -- "$BUILD_ROOT"' EXIT
DERIVED_DATA="$BUILD_ROOT/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"
APP_BUNDLE="$ROOT_DIR/dist/$PRODUCT_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if pgrep -x "$APP_NAME" >/dev/null; then
  echo "Intents is already running. Finish or cancel its run, then quit it before rebuilding." >&2
  exit 3
fi

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
rm -rf -- "$APP_BUNDLE"
ditto "$BUILT_APP" "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

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
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    exit 2
    ;;
esac
