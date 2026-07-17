#!/bin/zsh
# Signs with Developer ID + hardened runtime, notarizes, staples, and produces
# a distributable zip. Run after ./build.sh.
#
# Usage:
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" \
#   PROFILE="notary" \
#   ./notarize.sh
#
# DEV_ID  — identity from `security find-identity -v -p codesigning`
# PROFILE — notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials notary \
#     --apple-id you@example.com --team-id TEAMID \
#     --password <app-specific-password>
set -e
cd "$(dirname "$0")"
APP="Cadence Doctor.app"
: ${DEV_ID:?set DEV_ID to your Developer ID Application identity}
: ${PROFILE:?set PROFILE to your notarytool keychain profile name}

echo "Signing helpers…"
if [ -d "$APP/Contents/Helpers" ]; then
    for f in "$APP/Contents/Helpers"/*; do
        codesign --force --options runtime --timestamp -s "$DEV_ID" "$f"
    done
fi

echo "Signing app…"
codesign --force --options runtime --timestamp -s "$DEV_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "Submitting for notarization…"
ditto -c -k --keepParent "$APP" CadenceDoctor-submit.zip
xcrun notarytool submit CadenceDoctor-submit.zip --keychain-profile "$PROFILE" --wait
rm CadenceDoctor-submit.zip

echo "Stapling…"
xcrun stapler staple "$APP"

VERSION=$(defaults read "$(pwd)/$APP/Contents/Info.plist" CFBundleShortVersionString)
OUT="CadenceDoctor-v${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Distributable: $(pwd)/$OUT"
spctl -a -vv "$APP"
