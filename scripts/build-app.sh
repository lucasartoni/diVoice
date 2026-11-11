#!/bin/bash
# Builds diVoice.app (Apple Silicon), bundling Sparkle and signing it.
#
#   scripts/build-app.sh            # release
#   scripts/build-app.sh --debug
#
# Signing identity, in order: $SIGN_IDENTITY, then a "Developer ID Application" in the
# Keychain, then the local "DiVoice Dev" certificate (scripts/create-dev-cert.sh),
# otherwise an ad-hoc signature. With an ad-hoc signature macOS asks for the
# Accessibility permissions again on every build.
#
# With Developer ID: hardened runtime and timestamp on all the code, as notarization
# requires. With development certificates there is no hardened runtime: library
# validation would prevent loading Sparkle.framework, which has no Team ID.
set -euo pipefail

. "$(dirname "$0")/common.sh"
load_project_env
ROOT="$DIVOICE_ROOT"
CONFIG=release
[ "${1:-}" = "--debug" ] && CONFIG=debug
# Version from app/VERSION (or from $DIVOICE_VERSION for test builds); the build number
# derives from it (0.3.0 -> 300) and doesn't depend on the git history.
VERSION=$(divoice_version)
BUILD=$(divoice_build_number "$VERSION")

cd "$ROOT/app"
[ -d Vendor/Sparkle.xcframework ] || "../scripts/fetch-sparkle.sh"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="$ROOT/build/diVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiVoice" "$APP/Contents/MacOS/DiVoice"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
# Interface translations (en is the development language, it is the translation).
for lproj in Resources/*.lproj; do ditto "$lproj" "$APP/Contents/Resources/$(basename "$lproj")"; done

# Sparkle: the framework copied by SwiftPM next to the executable.
SPARKLE_FW=""
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
  SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE_FW"
fi

PLIST="$APP/Contents/Info.plist"
# Where Sparkle looks for updates: GitHub Releases, or the channel given by release.sh
# (builds published on an organization's server update from there).
FEED_URL="${FEED_URL:-https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml}"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s|__FEED_URL__|$FEED_URL|" Resources/Info.plist > "$PLIST"
KEY_FILE=Resources/SparklePublicKey.txt
if [ -n "$SPARKLE_FW" ] && [ -f "$KEY_FILE" ]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $(tr -d '[:space:]' < "$KEY_FILE")" "$PLIST"
else
  # Without Sparkle or without a public key, updates stay off.
  for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUScheduledCheckInterval SUAllowsAutomaticUpdates SUVerifyUpdateBeforeExtraction; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
  done
fi
# Copyright from project.env: until the holder is decided, the key is absent.
/usr/libexec/PlistBuddy -c "Delete :NSHumanReadableCopyright" "$PLIST" 2>/dev/null || true
if [ -n "${COPYRIGHT_HOLDER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string © $COPYRIGHT_YEAR $COPYRIGHT_HOLDER" "$PLIST"
fi
plutil -lint "$PLIST" >/dev/null

IDENTITY="${SIGN_IDENTITY:-}"
IDENTITY_LABEL="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  VALID=$(security find-identity -v -p codesigning 2>/dev/null || true)
  # The self-signed certificate is not "trusted" and doesn't show up with -v, but codesign uses it:
  # look for it among all identities and refer to it by hash, unambiguously.
  ALL=$(security find-identity -p codesigning 2>/dev/null || true)
  if echo "$VALID" | grep -q "Developer ID Application"; then
    IDENTITY=$(echo "$VALID" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/')
    IDENTITY_LABEL="$IDENTITY"
  elif echo "$ALL" | grep -q '"DiVoice Dev"'; then
    IDENTITY=$(echo "$ALL" | grep '"DiVoice Dev"' | head -1 | awk '{print $2}')
    IDENTITY_LABEL="DiVoice Dev ($IDENTITY)"
  else
    IDENTITY="-"
    IDENTITY_LABEL="ad-hoc"
  fi
fi

RUNTIME=()
if [[ "$IDENTITY" == Developer\ ID* ]]; then RUNTIME=(--options runtime --timestamp); fi
sign() {
  codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$@"
}

# Sign from the inside out, in the order given by Sparkle's documentation.
if [ -n "$SPARKLE_FW" ]; then
  B="$SPARKLE_FW/Versions/B"
  sign "$B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$B/XPCServices/Downloader.xpc"
  sign "$B/Autoupdate"
  sign "$B/Updater.app"
  sign "$SPARKLE_FW"
fi
sign --entitlements Resources/DiVoice.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "diVoice $VERSION ($BUILD), signature: $IDENTITY_LABEL, Sparkle: $([ -n "$SPARKLE_FW" ] && echo yes || echo no)"
echo "$APP"
