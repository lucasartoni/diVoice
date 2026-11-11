#!/bin/bash
# Downloads Sparkle 2.10.1 from the official GitHub release, verifies its SHA-256
# and prepares:
#   app/Vendor/Sparkle.xcframework     → linked by the app (Package.swift)
#   tools/sparkle/2.10.1/dist/bin/     → generate_keys, sign_update
#
#   scripts/fetch-sparkle.sh
set -euo pipefail

VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="$ROOT/tools/sparkle/$VERSION"
ARCHIVE="$DIR/Sparkle-$VERSION.tar.xz"
mkdir -p "$DIR"

if [ ! -f "$ARCHIVE" ]; then
  # -f: an HTTP error (for example a 504 page) doesn't become an "archive".
  if ! curl -fsSL --max-time 300 -o "$ARCHIVE.part" "$URL"; then
    # Fallback: the same file through the GitHub API, which redirects to another storage
    # (github.com/.../releases/download sometimes answers 504 on some networks).
    rm -f "$ARCHIVE.part"
    ASSET_ID=$(gh api "repos/sparkle-project/Sparkle/releases/tags/$VERSION" --jq ".assets[] | select(.name==\"Sparkle-$VERSION.tar.xz\") | .id")
    LOCATION=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 60 -H "Accept: application/octet-stream" \
      -H "Authorization: Bearer $(gh auth token)" "https://api.github.com/repos/sparkle-project/Sparkle/releases/assets/$ASSET_ID")
    curl -fsSL --max-time 300 -o "$ARCHIVE.part" "$LOCATION" || { rm -f "$ARCHIVE.part"; echo "Download failed"; exit 1; }
  fi
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "Wrong SHA-256 for $ARCHIVE: $ACTUAL (expected $SHA256). Archive removed."
  rm -f "$ARCHIVE"
  exit 1
fi

rm -rf "$DIR/dist"
mkdir -p "$DIR/dist"
tar -xJf "$ARCHIVE" -C "$DIR/dist"

# The distribution contains Sparkle.framework (universal) but not an .xcframework:
# it is wrapped in the standard manifest, which SwiftPM accepts as a local binaryTarget.
XCF="$ROOT/app/Vendor/Sparkle.xcframework"
rm -rf "$XCF"
mkdir -p "$XCF/macos-arm64_x86_64"
ditto "$DIR/dist/Sparkle.framework" "$XCF/macos-arm64_x86_64/Sparkle.framework"
cat > "$XCF/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>LibraryIdentifier</key>
      <string>macos-arm64_x86_64</string>
      <key>LibraryPath</key>
      <string>Sparkle.framework</string>
      <key>SupportedArchitectures</key>
      <array>
        <string>arm64</string>
        <string>x86_64</string>
      </array>
      <key>SupportedPlatform</key>
      <string>macos</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key>
  <string>XFWK</string>
  <key>XCFrameworkFormatVersion</key>
  <string>1.0</string>
</dict>
</plist>
PLIST
echo "Sparkle $VERSION ready: app/Vendor/Sparkle.xcframework and $DIR/dist/bin"
