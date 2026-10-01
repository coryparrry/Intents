#!/usr/bin/env bash
set -euo pipefail

# Package locally or on a trusted release runner using a disposable keychain.
RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
: "${RELEASE_TAG:?Missing release tag}"
: "${BUILD_NUMBER:?Set the positive integer build number}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${CERTIFICATE_P12_BASE64:?Set packaging credentials}"
: "${CERTIFICATE_PASSWORD:?Missing CERTIFICATE_PASSWORD}"
: "${NOTARY_KEY_P8:?Missing NOTARY_KEY_P8}"
: "${NOTARY_KEY_ID:?Missing NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?Missing NOTARY_ISSUER_ID}"
if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Release tags must have the form v1.0.0.' >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo 'BUILD_NUMBER must be a positive integer.' >&2
  exit 1
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
cd "${SOURCE_DIR:-$script_directory/..}"
source_commit="$(git rev-parse "$RELEASE_TAG^{commit}")"
if [[ "$(git rev-parse HEAD)" != "$source_commit" || -n "$(git status --porcelain)" ]]; then
  echo 'Package from a clean checkout of the exact release tag.' >&2
  exit 1
fi
version="${RELEASE_TAG#v}"
work="$(mktemp -d "$RUNNER_TEMP/foundation-evals-release.XXXXXX")"
keychain="$work/signing.keychain-db"
keychain_password="$(openssl rand -hex 24)"
existing_keychains=()
keychain_list="$(security list-keychains -d user)"
while IFS= read -r existing_keychain; do
  existing_keychains+=("$existing_keychain")
done < <(printf '%s\n' "$keychain_list" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
cleanup() {
  result=$?
  security list-keychains -d user -s "${existing_keychains[@]}" || result=1
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$result"
}
trap cleanup EXIT
umask 077
printf '%s' "$CERTIFICATE_P12_BASE64" | base64 --decode > "$work/signing.p12"
printf '%s' "$NOTARY_KEY_P8" > "$work/notary.p8"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/signing.p12" -P "$CERTIFICATE_PASSWORD" -t cert -f pkcs12 \
  -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${existing_keychains[@]}"
identity="$(security find-identity -v -p codesigning "$keychain" |
  awk -v team="($APPLE_TEAM_ID)" '/Developer ID Application:/ && index($0, team) {print $2}')"
if [[ ! "$identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
  echo 'The P12 must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID.' >&2
  exit 1
fi

xcodebuild -version
mkdir "$work/source"
git archive "$source_commit" | tar -x -C "$work/source"
xcodebuild archive \
  -project "$work/source/FoundationEvals/FoundationEvals.xcodeproj" -scheme FoundationEvals \
  -configuration Release -destination 'generic/platform=macOS' \
  -disableAutomaticPackageResolution \
  -derivedDataPath "$work/build" -archivePath "$work/FoundationEvals.xcarchive" \
  ARCHS=arm64 CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  FOUNDATION_EVALS_SOURCE_COMMIT="$source_commit"

export APPLE_TEAM_ID
python3 - "$work/ExportOptions.plist" "$identity" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'method': 'developer-id', 'signingStyle': 'manual',
                  'teamID': os.environ['APPLE_TEAM_ID'],
                  'signingCertificate': sys.argv[2]}, output)
PY
xcodebuild -exportArchive -archivePath "$work/FoundationEvals.xcarchive" \
  -exportPath "$work/export" -exportOptionsPlist "$work/ExportOptions.plist"
mkdir -p "$work/payload"
app="$work/payload/Foundation Evals.app"
ditto --norsrc --noextattr "$work/export/FoundationEvals.app" "$app"
xattr -cr "$app"
codesign --verify --strict --deep "$app"
test -f "$app/Contents/Resources/AppIcon.icns"
ln -s /Applications "$work/payload/Applications"
dmg="$work/Foundation-Evals-$version-macOS-arm64.dmg"
hdiutil create -volname 'Foundation Evals' -srcfolder "$work/payload" -format UDZO "$dmg"
codesign --sign "$identity" --timestamp "$dmg"

notary_auth=(--key "$work/notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --timeout 30m \
  --output-format json > "$work/notarization.json"
python3 - "$work/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('Apple notarization:', result.get('status'), result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; inspect the submission in Apple Notary.')
PY
xcrun stapler staple "$dmg"
mkdir "$work/verified"
filename="$(basename "$dmg")"
cp "$dmg" "$work/verified/"
(cd "$work/verified" && shasum -a 256 "$filename" > SHA256SUMS.txt)
# Sign the final, stapled installer with the configured Sparkle key.
sparkle_bin="$work/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
sparkle_key_args=(--account foundation-evals)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" > "$work/sparkle.key"
  sparkle_key_args=(--ed-key-file "$work/sparkle.key")
fi
"$sparkle_bin/generate_appcast" "${sparkle_key_args[@]}" \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/coryparrry/Foundation-Eval-Labs/releases/download/$RELEASE_TAG/" \
  "$work/verified"
EXPECTED_TEAM_ID="$APPLE_TEAM_ID" bash "$script_directory/verify_installer.sh" "$work/verified" "$RELEASE_TAG" "$source_commit"
mkdir -p dist/release
cp "$work/verified/$filename" "$work/verified/SHA256SUMS.txt" "$work/verified/appcast.xml" dist/release/
