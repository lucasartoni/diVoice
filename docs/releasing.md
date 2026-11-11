# Releasing

This page is for maintainers who publish official builds. To build diVoice for yourself, see [Build from source](../README.md#build-from-source).

## Versions

- The version is in [`app/VERSION`](../app/VERSION), as `MAJOR.MINOR.PATCH`. Bump and commit it before every release.
- The build number (`CFBundleVersion`, which Sparkle compares) is derived from it: `MAJOR·10000 + MINOR·100 + PATCH` (0.4.0 → 400). It never depends on the git history. `MINOR` and `PATCH` stay below 100.
- Every release gets an entry in [`CHANGELOG.md`](../CHANGELOG.md). When it needs a newer organization server, the entry says which [diServer](https://github.com/tommasoseita/diServer) version, at least. diServer has its own versions and changelog: diVoice never sets them.

## Project settings

[`project.env`](../project.env) is the single place for:

| Setting | Purpose |
|---|---|
| `COPYRIGHT_HOLDER`, `COPYRIGHT_YEAR` | `LICENSE` (rendered by `scripts/render-license.sh`) and the app's About text |
| `TEAM_ID` | The Developer ID team that signs official builds |
| `NOTARY_PROFILE` | The `notarytool` keychain profile |
| `GITHUB_REPO` | Where releases and the public appcast live |

The bundle identifier and the signing team must never change: macOS ties the microphone and Accessibility permissions, and Keychain access, to them.

## Prerequisites

Once, on the Mac that publishes:

1. **Developer ID Application** certificate of the team, in the login keychain: `scripts/import-developer-id.sh <certificate.cer>`, or import the `.p12` backup.
2. **Notarization profile**, created with an App Store Connect API key:
   ```bash
   xcrun notarytool store-credentials <NOTARY_PROFILE> --key AuthKey_XXXX.p8 --key-id <id> --issuer <issuer>
   ```
3. **Sparkle's EdDSA private key** in `.signing/sparkle-eddsa.key`. The public key is in `app/Resources/SparklePublicKey.txt`. **If the private key is lost, installed apps can no longer be updated**: keep a copy in a password manager.
4. **Sparkle tools**: `scripts/fetch-sparkle.sh` downloads Sparkle 2.10.1 and verifies its checksum.
5. For GitHub releases: `gh auth login`. For releases hosted on an organization's server: `npx wrangler login`.

`.signing/` is ignored by git. Never commit certificates, keys or tokens.

## Publishing

```bash
echo 0.5.1 > app/VERSION
git commit -am "diVoice 0.5.1"
git push origin main
scripts/release.sh "One line on what changed"
```

`release.sh` refuses to run on a dirty tree, on a commit that isn't pushed, or for a version already released. Then it:

1. builds `diVoice.app` for Apple Silicon, signed with Developer ID, hardened runtime and secure timestamp, with Sparkle inside, signed from the inside out;
2. notarizes the app and staples the ticket;
3. builds the DMG, signs, notarizes and staples it;
4. signs the DMG for Sparkle (EdDSA) and writes the appcast, keeping every earlier version listed;
5. publishes them on the channel below.

### Channels

| Channel | Feed | How |
|---|---|---|
| GitHub Releases (default) | `https://github.com/<GITHUB_REPO>/releases/latest/download/appcast.xml` | A draft release `v<version>` with `diVoice.dmg` and `appcast.xml`, published once both are uploaded, with the version's `CHANGELOG.md` section as notes. Run it from a clone of `GITHUB_REPO` whose `HEAD` is pushed: the release tags that commit. |
| An organization's server | `<server>/updates/appcast.xml` | `DIVOICE_URL=https://diserver.acme.workers.dev DIVOICE_WRANGLER_CONFIG=path/to/wrangler.toml scripts/release.sh "…"` uploads the DMG and the appcast to the server's `UPDATES` namespace; its invite pages then serve that DMG. |

A build follows the channel it was published on: Sparkle reads the feed URL baked into it.

### Test builds

```bash
scripts/release.sh --local
```

stops after step 3: a notarized DMG in `dist/<version>-local/`, nothing published, nothing tagged. `DIVOICE_VERSION=0.4.1 scripts/release.sh --local` builds a version without bumping `app/VERSION`.

## Before every release

- [ ] `scripts/test-app.sh` passes.
- [ ] `python3 scripts/check-localization.py` reports no missing translation.
- [ ] Verify works for each step with both providers, on a build from `--local`.
- [ ] Installing the DMG on a clean account works, and updating from the previous version keeps permissions without prompts.
- [ ] `CHANGELOG.md` is updated.

## Why users don't see permission prompts after updates

- **Stable signature.** Every version is signed by the same Developer ID with the same bundle identifier, so its designated requirement doesn't change: macOS keeps the microphone and Accessibility permissions, and the Keychain keeps giving diVoice its keys without asking.
- **Installed in Applications.** An app dragged there belongs to the user, so Sparkle replaces it without an administrator password. diVoice asks to be moved there when it runs from anywhere else.
