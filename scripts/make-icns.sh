#!/bin/bash
# Regenerates the app icon from logo.png.
#
#   scripts/make-icns.sh [logo.png]
#
# 1. make-icon.swift: logo on the macOS grid (824 squircle on 1024, transparent outside)
# 2. all the iconset sizes, from 16 to 1024 px
# 3. iconutil → app/Resources/AppIcon.icns, which build-app.sh copies into the bundle
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOGO="${1:-$ROOT/logo.png}"
RES="$ROOT/app/Resources"
MASTER="$RES/AppIcon-1024.png"

swift "$ROOT/scripts/make-icon.swift" "$LOGO" "$MASTER"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
trap 'rc=$?; rm -rf "$(dirname "$ICONSET")"; exit $rc' EXIT

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
echo "Wrote $RES/AppIcon.icns ($(ls "$ICONSET" | wc -l | tr -d ' ') images)"
