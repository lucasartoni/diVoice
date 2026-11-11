#!/bin/bash
# Publishes a diVoice version.
#
#   scripts/release.sh "One-line release notes"
#
# 1. build signed with Developer ID (hardened runtime, timestamp), Sparkle included
# 2. app notarization and ticket stapling
# 3. DMG signed, notarized and stapled
# 4. EdDSA signature of the DMG for Sparkle, and appcast.xml
# 5. publishing, on one of two channels:
#
#    GitHub Releases (default): a draft release v<version> of $GITHUB_REPO (project.env) with
#    diVoice.dmg and appcast.xml, published only once both are uploaded. The appcast keeps
#    every earlier version. Run it from a clone of $GITHUB_REPO whose HEAD is pushed: the
#    release tags that commit. The notes are the version's section of CHANGELOG.md, if any.
#
#    An organization's server (diServer): DIVOICE_URL=https://diserver.example.workers.dev
#    DIVOICE_WRANGLER_CONFIG=path/to/wrangler.toml scripts/release.sh "…" uploads the DMG and
#    the appcast to that server's UPDATES namespace; its invite pages then serve this DMG. It
#    uses the wrangler installed next to that config (npm install there first).
#    Builds published this way look for updates on that server.
#
#   scripts/release.sh --local      # only steps 1-3: notarized DMG in dist/<version>-local,
#                                   # nothing published (for tests)
#
# Prerequisites (once): the team's "Developer ID Application" identity in the Keychain
# (scripts/import-developer-id.sh), notarytool profile (NOTARY_PROFILE in project.env), Sparkle
# (scripts/fetch-sparkle.sh), EdDSA key in .signing/sparkle-eddsa.key; `gh auth login` for
# GitHub, `npx wrangler login` for an organization's server. See docs/releasing.md.
# The version is in app/VERSION: bump and commit it before every release.
# For a test build it can be forced with DIVOICE_VERSION=0.5.0.
set -euo pipefail

. "$(dirname "$0")/common.sh"
load_project_env
ROOT="$DIVOICE_ROOT"
LOCAL=0
if [ "${1:-}" = "--local" ]; then LOCAL=1; shift; fi
NOTES="${1:-Improvements and fixes.}"
PROFILE="$NOTARY_PROFILE"
SPARKLE_BIN="$ROOT/tools/sparkle/2.10.1/dist/bin"
ED_KEY="$ROOT/.signing/sparkle-eddsa.key"
VERSION=$(divoice_version)
BUILD=$(divoice_build_number "$VERSION")
TAG="v$VERSION"
export DIVOICE_VERSION="$VERSION"

fail() { echo "Error: $*" >&2; exit 1; }

# Channel: GitHub unless an organization's server is given.
ORG_URL="${DIVOICE_URL:-}"
ORG_URL="${ORG_URL%/}"
if [ -n "$ORG_URL" ]; then
  CHANNEL=org
  # The app looks for updates where this release is published.
  export FEED_URL="$ORG_URL/updates/appcast.xml"
  ENCLOSURE_URL="$ORG_URL/updates/diVoice-$VERSION.dmg"
else
  CHANNEL=github
  unset FEED_URL   # build-app.sh's default: the latest GitHub release of $GITHUB_REPO
  ENCLOSURE_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/diVoice.dmg"
fi

if [ "$LOCAL" = 0 ]; then
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || fail "there are uncommitted changes: a release starts from a specific commit"
  [ -x "$SPARKLE_BIN/sign_update" ] || fail "Sparkle is missing: run scripts/fetch-sparkle.sh"
  [ -f "$ED_KEY" ] || fail "missing EdDSA key $ED_KEY"
  if [ "$CHANNEL" = github ]; then
    command -v gh >/dev/null || fail "the GitHub CLI (gh) is missing"
    gh auth status >/dev/null 2>&1 || fail "run gh auth login first"
    ORIGIN=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
    case "$ORIGIN" in
      *"github.com/$GITHUB_REPO"|*"github.com/$GITHUB_REPO.git"|*"github.com:$GITHUB_REPO.git") ;;
      *) fail "run GitHub releases from a clone of $GITHUB_REPO (origin is '$ORIGIN')" ;;
    esac
    git -C "$ROOT" fetch --quiet --tags origin
    SHA=$(git -C "$ROOT" rev-parse HEAD)
    [ -n "$(git -C "$ROOT" branch -r --contains "$SHA")" ] || fail "push $SHA to origin first: the release tags that commit"
    git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 && fail "$TAG already exists: bump app/VERSION"
    gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 && fail "release $TAG already exists on GitHub"
  else
    [ -n "${DIVOICE_WRANGLER_CONFIG:-}" ] || fail "set DIVOICE_WRANGLER_CONFIG to the server's wrangler config"
    [ -f "$DIVOICE_WRANGLER_CONFIG" ] || fail "missing $DIVOICE_WRANGLER_CONFIG"
    WRANGLER_CONFIG=$(cd "$(dirname "$DIVOICE_WRANGLER_CONFIG")" && pwd)/$(basename "$DIVOICE_WRANGLER_CONFIG")
    WRANGLER_DIR=$(dirname "$WRANGLER_CONFIG")
    WRANGLER_BIN="$WRANGLER_DIR/node_modules/.bin/wrangler"
    [ -x "$WRANGLER_BIN" ] || fail "run npm install in $WRANGLER_DIR first: the release uses its wrangler"
  fi
fi
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"$/\1/')
[ -n "$IDENTITY" ] || fail "missing Developer ID Application identity for team $TEAM_ID"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "the notarytool profile \"$PROFILE\" does not work"

OUT="$ROOT/dist/$VERSION"
[ "$LOCAL" = 1 ] && OUT="$ROOT/dist/$VERSION-local"
rm -rf "$OUT"
mkdir -p "$OUT"
APP="$ROOT/build/diVoice.app"
DMG="$OUT/diVoice-$VERSION.dmg"

notarize() {
  local file="$1"
  local result id status
  result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 30m --output-format json)
  id=$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  status=$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
  echo "Notarization of $(basename "$file"): $status ($id)"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    fail "notarization rejected"
  fi
}

echo "== 1. Build $VERSION ($BUILD) signed with: $IDENTITY"
SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" >/dev/null || fail "Sparkle is not in the app"
echo "Updates from: $(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist")"

echo "== 2. App notarization"
ditto -c -k --keepParent "$APP" "$OUT/diVoice-notarize.zip"
notarize "$OUT/diVoice-notarize.zip"
rm "$OUT/diVoice-notarize.zip"
xcrun stapler staple "$APP"

echo "== 3. DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/diVoice.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "diVoice" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

if [ "$LOCAL" = 1 ]; then
  echo
  echo "diVoice $VERSION ($BUILD) notarized, not published: $DMG"
  exit 0
fi

echo "== 4. Sparkle signature and appcast"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$ED_KEY" "$DMG")
SIZE=$(stat -f%z "$DMG")
PREVIOUS="$OUT/previous-appcast.xml"
: > "$PREVIOUS"
if [ "$CHANNEL" = github ]; then
  # The latest release's appcast, if any: its versions stay listed.
  gh release download --repo "$GITHUB_REPO" --pattern appcast.xml --output "$PREVIOUS" --clobber >/dev/null 2>&1 || : > "$PREVIOUS"
fi
/usr/bin/python3 -I "$ROOT/scripts/appcast.py" --previous "$PREVIOUS" --out "$OUT/appcast.xml" \
  --version "$VERSION" --build "$BUILD" --notes "$NOTES" --url "$ENCLOSURE_URL" --signature "$SIGNATURE"
rm -f "$PREVIOUS"
plutil -lint "$OUT/appcast.xml" >/dev/null 2>&1 || xmllint --noout "$OUT/appcast.xml"

echo "== 5. Publishing ($CHANNEL)"
if [ "$CHANNEL" = github ]; then
  ASSETS="$OUT/github"
  mkdir -p "$ASSETS"
  cp "$DMG" "$ASSETS/diVoice.dmg"
  cp "$OUT/appcast.xml" "$ASSETS/appcast.xml"
  # Release notes: the version's section of CHANGELOG.md, else the one-line notes.
  /usr/bin/python3 -I - "$ROOT/CHANGELOG.md" "$VERSION" "$NOTES" "https://github.com/$GITHUB_REPO/blob/$TAG/" > "$OUT/notes.md" <<'PY'
import re, sys
path, version, fallback, base = sys.argv[1:5]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    text = ""
match = re.search(rf"^## \[?{re.escape(version)}\]?[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
notes = match.group(1).strip() if match and match.group(1).strip() else fallback
# Relative links point into the repository at this release's tag.
print(re.sub(r"\]\((?!https?:|mailto:|#)([^)]+)\)", lambda m: f"]({base}{m.group(1)})", notes))
PY
  gh release create "$TAG" --repo "$GITHUB_REPO" --target "$SHA" --draft \
    --title "diVoice $VERSION" --notes-file "$OUT/notes.md" "$ASSETS/diVoice.dmg" "$ASSETS/appcast.xml"
  # Publish only if both files arrived whole.
  UPLOADED=$(gh release view "$TAG" --repo "$GITHUB_REPO" --json assets \
    --jq '[.assets[] | select((.name == "diVoice.dmg" and .size == '"$SIZE"') or .name == "appcast.xml")] | length')
  [ "$UPLOADED" = 2 ] || fail "the draft release $TAG is missing files: check it on GitHub, then delete it and retry"
  gh release edit "$TAG" --repo "$GITHUB_REPO" --draft=false --latest >/dev/null
  git -C "$ROOT" fetch --quiet --tags origin
  echo
  echo "diVoice $VERSION ($BUILD) published: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
else
  wrangler() { (cd "$WRANGLER_DIR" && "$WRANGLER_BIN" "$@" --config "$WRANGLER_CONFIG"); }
  wrangler kv key put "updates/diVoice-$VERSION.dmg" --binding UPDATES --remote --path "$DMG" \
    --metadata "{\"contentType\":\"application/x-apple-diskimage\",\"size\":$SIZE}"
  # The fixed name invite pages download (diserver's src/pages.ts).
  wrangler kv key put "updates/diVoice.dmg" --binding UPDATES --remote --path "$DMG" \
    --metadata "{\"contentType\":\"application/x-apple-diskimage\",\"size\":$SIZE}"
  APPCAST_SIZE=$(stat -f%z "$OUT/appcast.xml")
  wrangler kv key put "updates/appcast.xml" --binding UPDATES --remote --path "$OUT/appcast.xml" \
    --metadata "{\"contentType\":\"application/xml; charset=utf-8\",\"size\":$APPCAST_SIZE}"
  echo
  echo "diVoice $VERSION ($BUILD) published on $ORG_URL from commit $(git -C "$ROOT" rev-parse --short HEAD)."
fi
echo "DMG for new installs: $DMG"
