#!/bin/bash
# Dictation latency and accuracy with the app's own engine (app/Sources/DiVoiceBench).
#
#   scripts/bench.sh                                   # Mistral and OpenAI with their defaults
#   scripts/bench.sh --config openai --config "openai,mode=batch" --runs 3
#   scripts/bench.sh --help
#
# Keys are the ones saved in diVoice (macOS asks whether divoice-bench may read them),
# otherwise MISTRAL_API_KEY / OPENAI_API_KEY. The binary is signed with the app's identity
# when there is one, so "Always Allow" survives rebuilds.
set -euo pipefail
# No cd: relative paths in the options (--clips, --out) stay relative to the caller.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/app"
[ -d "$APP/Vendor/Sparkle.xcframework" ] || "$ROOT/scripts/fetch-sparkle.sh"

swift build -c release --package-path "$APP" --product DiVoiceBench >&2
BIN="$APP/.build/release/DiVoiceBench"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"$/\1/' || true)
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier divoice-bench "$BIN" 2>/dev/null \
    || echo "bench: not signed, macOS will ask again after each rebuild" >&2
fi

exec "$BIN" "$@"
