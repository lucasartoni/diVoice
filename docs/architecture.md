# Architecture

diVoice is a native macOS app that talks directly to AI providers, plus an optional server for organizations, [diServer](https://github.com/tommasoseita/diServer), shared with diMail. All the dictation logic (prompts, guards, styles, dictionary handling) lives in the app, in one engine shared by both modes.

```text
                     personal mode
 ┌──────────────┐   ───────────────────────────────▶  Mistral / OpenAI
 │  diVoice.app │
 │  (Swift)     │   organization mode
 └──────────────┘   ── WebSocket /v2/relay ──▶ ┌──────────────────────┐ ──▶ Mistral / OpenAI
                                               │ diServer             │
                                               │ Cloudflare Worker+D1 │
                                               └──────────────────────┘
```

## Repository layout

| Path | Contents |
|---|---|
| `app/` | The macOS app, a Swift package built with the Command Line Tools (no Xcode project) |
| `scripts/` | Build, test, signing, notarization, release and checks |
| `docs/` | This documentation |

## The app

Swift package targets:

| Target | Role |
|---|---|
| `DiVoiceCore` | Pure logic: hotkey state machine, PCM audio, timing, smart spacing, invite links |
| `DiVoiceEngine` | The AI pipeline: transcription, cleanup, Scribe, providers, prompts, dictionary, verify. Foundation only, Swift 6 strict concurrency |
| `DiVoiceKit` | AppKit pieces testable without the app (the main menu) |
| `DiVoice` | The app: menu bar item, overlay, settings and onboarding (SwiftUI), audio capture, Accessibility, insertion, Keychain, Sparkle |
| `DiVoiceBench` | A command-line bench that runs real clips through the same engine (see [Latency](latency.md)) |

### One dictation

1. **Key down.** A `CGEventTap` sees Fn (or right ⌘/⌥). A quick release may be the first of a double tap: the recording goes on for 0.4 s, and a second press locks it hands-free until the key is pressed again; without one, a press shorter than 150 ms is ignored. Esc cancels; another key cancels a held dictation (it was a shortcut) but not a hands-free one. The state machine is `HotkeyStateMachine` in DiVoiceCore.
2. **Context.** Through Accessibility, the app reads the active app, the window title, the selection and the characters before the cursor, each with a 150 ms timeout.
3. **Audio.** `AVAudioEngine` captures the microphone, converted to 16-bit mono PCM (16 kHz for Mistral, 24 kHz for OpenAI) and streamed in 100 ms chunks. The microphone is prepared in advance, so the first syllable isn't lost.
4. **Transcription while you speak.** A realtime WebSocket to the provider receives the audio and the dictionary terms as bias.
5. **Key up.** In hybrid mode, recordings up to 25 s are also transcribed whole by the provider's file model, which is more accurate; the streaming result is the fallback, and vice versa.
6. **Cleanup.** A chat model rewrites the transcript into written text with the style of the app's category. Guards reject an answer that looks like a reply instead of a rewrite, or a translation (under 50% word overlap): diVoice then inserts the raw transcript.
7. **Insertion.** The text goes on the clipboard through a lazy provider and the app sends ⌘V. The moment the target app reads the clipboard, diVoice restores what was there before. If nothing reads it within a second (a password field, an app that ignores paste), the text stays on the clipboard for a manual paste.

Scribe follows the same path, with an editor prompt instead of the cleanup; its answer goes into the app when it is complete.

### Providers

`DiVoiceEngine` has one adapter per provider (Mistral and OpenAI) for transcription, both realtime and file, and for chat completions. Network access goes through small protocols (`HTTPClient`, `WebSocketConnector`, `TranscriptionService`, `ChatService`): in personal mode they reach the provider directly with the key from the Keychain; in organization mode the relay implementations carry the same requests over the organization's WebSocket. The pipeline doesn't know which one it's using.

### Verify

Each step can be verified from Settings. The app synthesizes a test sentence in the dictation language with `AVSpeechSynthesizer` and runs it through the real pipeline, measuring connection, first token and total time. If a model rejects predicted outputs, Verify turns them off.

## The organization server

The organization server is [diServer](https://github.com/tommasoseita/diServer), in its own repository: TypeScript, [Hono](https://hono.dev), Cloudflare Workers and D1, one deployment per organization. It serves diVoice and diMail. For diVoice it holds no prompts and no dictation logic. It holds:

- the **provider keys**, encrypted with AES-GCM (key derived with HKDF from `SERVER_SECRET`, or `DIVOICE_SECRET` on servers set up before diServer), cached decrypted in memory for 60 seconds, never returned by the API;
- the **models** the admins choose, which override whatever the app asks for;
- **members, roles and invites**;
- the **team dictionary**;
- **statistics**: one row of counts per dictation, never text.

### The relay

Each dictation opens a WebSocket to `/v2/relay` (protocol: [diServer › API](https://github.com/tommasoseita/diServer/blob/main/docs/api.md#divoices-relay)). The app side is `RelayConnection` in `DiVoiceEngine`. The app sends `start`, then the audio. The server:

1. opens the provider's realtime transcription and warms an HTTPS connection to the provider's API;
2. forwards the audio and keeps a copy in memory;
3. at `finish`, runs the same hybrid logic as the app, transcribing the copy at release so the audio isn't uploaded twice;
4. relays the app's cleanup or Scribe request, after sanitizing it: only known fields pass, the model, service tier and predicted outputs come from the organization's settings, and the response length is capped;
5. records the statistics the app sends, and closes.

The relay adds about 50 ms to a dictation compared with calling the provider directly. See [Latency](latency.md#through-an-organizations-server-9-november-2026).

### Invites and joining

Invite codes are random, stored with their kind, allowed emails, uses and expiry. The invite page's download is served under a file name that carries the server's host and the code (`diVoice (Acme) [host code].dmg`). At first launch the app finds that disk image among the mounted ones (`hdiutil info`), reads the invite, and offers to join, so a new member doesn't have to find the link again. A `divoice://join` URL does the same for an installed app.

Joining returns a token (`dv_…`), stored in the Keychain; the server keeps only its SHA-256 hash.

## Updates

The app uses [Sparkle](https://sparkle-project.org) 2. Each release is a notarized DMG signed with EdDSA, listed in an appcast. Public builds read the appcast from GitHub Releases; builds published on an organization's server read it from that server's `/updates/`. See [Releasing](releasing.md).

## Tests

| Suite | Runs with | Covers |
|---|---|---|
| `app/Tests` | `scripts/test-app.sh` (Swift Testing) | Hotkeys, PCM, spacing, invite links, the engine with simulated providers, prompts and guards, statistics, the main menu |
| `scripts/check-localization.py` | Python 3 | Every interface string has an Italian translation |

The server's tests run in [diServer](https://github.com/tommasoseita/diServer).
