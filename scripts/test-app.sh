#!/bin/bash
# App tests with Swift Testing. With only the Command Line Tools (no Xcode)
# the Testing framework has to be specified by hand.
set -euo pipefail
cd "$(dirname "$0")/../app"
[ -d Vendor/Sparkle.xcframework ] || "../scripts/fetch-sparkle.sh"

CLT=/Library/Developer/CommandLineTools
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"

if xcode-select -p | grep -q "CommandLineTools" && [ -d "$FRAMEWORKS/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    "$@"
fi
exec swift test "$@"
