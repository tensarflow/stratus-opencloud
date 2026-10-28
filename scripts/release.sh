#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized and stapled Stratus-<version>.dmg in build/release/.
# Usage: scripts/release.sh <version> [--archive-only | --skip-notarize]
#   --archive-only   stop after the Release archive (works with a Development certificate)
#   --skip-notarize  sign and package, but do not notarize or staple
# Notarization reads an App Store Connect API key from the environment (never printed):
#   ASC_KEY_PATH (path to the .p8 file), ASC_KEY_ID, ASC_ISSUER_ID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--archive-only | --skip-notarize]}"
MODE="${2:-}"
OUT="build/release"
ARCHIVE="$OUT/Stratus.xcarchive"
DMG="$OUT/Stratus-$VERSION.dmg"
TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.xcconfig)"

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate
xcodebuild -project Stratus.xcodeproj -scheme Stratus -configuration Release \
  -derivedDataPath "$HOME/Library/Developer/Stratus/ReleaseData" -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" -allowProvisioningUpdates archive
[[ "$MODE" == "--archive-only" ]] && { echo "archived: $ARCHIVE"; exit 0; }

IDENTITY="$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\"/\1/p" | head -1)"
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity for team $TEAM in the keychain" >&2; exit 1; }

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
APP="$OUT/export/Stratus.app"
codesign --verify --deep --strict --verbose=2 "$APP"

STAGE="$OUT/dmg"
mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Stratus $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "$MODE" != "--skip-notarize" ]]; then
  : "${ASC_KEY_PATH:?set ASC_KEY_PATH}" "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
  xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG"
