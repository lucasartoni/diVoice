# Contributing to diVoice

Thank you for helping. diVoice is a small project with high standards for latency, privacy and polish; this guide explains how to work on it so your change lands quickly.

## Before you start

- **Bugs:** search the [issues](https://github.com/tommasoseita/divoice/issues) first, then open one with the bug report form. Logs help a lot (see [Troubleshooting](docs/troubleshooting.md#collecting-logs)).
- **Features:** open an issue to discuss the idea before writing code. diVoice deliberately does few things; a short conversation saves you a pull request that can't be merged.
- **Security issues:** never in public issues. See [SECURITY.md](SECURITY.md).

## Setting up

You need:

- macOS 14 or later on Apple Silicon;
- Apple's Command Line Tools (`xcode-select --install`). Xcode works too but isn't required;
- Python 3, for the localization check.

```bash
git clone https://github.com/tommasoseita/divoice.git
cd divoice
```

### The app

```bash
scripts/test-app.sh            # all Swift tests
scripts/build-app.sh --debug   # build/diVoice.app
open build/diVoice.app
```

`scripts/fetch-sparkle.sh` runs on its own the first time, to download Sparkle and verify its checksum.

**Signing and permissions.** macOS ties the Accessibility and microphone permissions to the app's signature. With an ad-hoc signature, every build looks like a new app and asks again. Run `scripts/create-dev-cert.sh` once: it creates a local "DiVoice Dev" certificate that `build-app.sh` then uses, so permissions survive rebuilds.

**Screenshots.** The app renders its own screens with sample data, which is how the images in `docs/images` are made:

```bash
build/diVoice.app/Contents/MacOS/DiVoice --render-screens /tmp/screens -AppleLanguages "(en)"
```

### The server

The organization server is [diServer](https://github.com/tommasoseita/diServer), in its own repository with its own setup and tests. Changes to the server, or to the API and relay the app uses, start there.

### The bench

Changes to prompts, models or the pipeline need numbers. `scripts/bench.sh` runs synthesized and real clips through the same engine as the app and reports latency and quality; see [Latency](docs/latency.md#the-bench). It uses your own API keys from the Keychain.

## Making a change

- **One topic per pull request**, with a description of what changes for the user and how you tested it.
- **Tests.** Add or update tests for logic in `DiVoiceCore` and `DiVoiceEngine`. UI changes need a screenshot (light and dark if the look changes).
- **Prompts and models.** Include bench results before and after, on both Italian and English clips. A prompt change is accepted only if quality doesn't drop in any language.
- **Latency.** The budget is about one second from releasing the key to the text. Don't add network round trips or work on the critical path without measuring them.
- **Privacy.** Never log, store or send dictated text, audio or keys beyond what [Privacy](docs/privacy.md) describes. If your change affects what leaves the Mac, update that page.
- **Strings.** The interface is in English with an Italian translation. Every new string needs its entry in `app/Resources/it.lproj/Localizable.strings`; `python3 scripts/check-localization.py` must report nothing missing.
- **Docs.** If you change behavior, update the matching page in [`docs/`](docs).

### Style

- Swift: 2-space indentation; Swift 6 strict concurrency in `DiVoiceCore` and `DiVoiceEngine`; keep the engine Foundation-only, so it stays testable without the app.
- TypeScript: strict mode, no new runtime dependencies without discussion.
- Comments explain *why*, not what. Code, comments, commits and docs are in English.
- Commit messages: a short summary line in the imperative or descriptive mood ("Scribe keeps the order of steps"), then details if needed.

## Checks

Every pull request runs:

- the Swift tests on macOS;
- the localization check.

Run them locally before pushing:

```bash
scripts/test-app.sh
python3 scripts/check-localization.py
```

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) of the project.

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
