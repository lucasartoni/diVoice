# Providers and models

diVoice uses three models, each for one step:

| Step | What it does |
|---|---|
| **Transcription** | Turns your voice into raw text, guided by your dictionary |
| **Cleanup** | Turns the raw text into what you meant to write (every dictation) |
| **Scribe** | Edits your dictation, or changes the selected text (Ctrl+Fn) |

Each step can use [Mistral](https://mistral.ai) or [OpenAI](https://openai.com), with any model the provider offers. Transcription can also use [ElevenLabs](https://elevenlabs.io) Scribe v2 (ElevenLabs has no chat models, so cleanup and Scribe stay with Mistral or OpenAI). Choose them in **Settings › Models**; **Use Mistral for everything** and **Use OpenAI for everything** restore the defaults.

![Models](images/settings-models-light.png)

## The defaults

The defaults come from measurements on real-world dictations (see [Latency](latency.md)).

| | Mistral | OpenAI |
|---|---|---|
| Transcription | `voxtral-mini-transcribe-realtime-3-0` while you speak, `voxtral-mini-transcribe-3-0` on the whole recording at release (hybrid) | `gpt-transcribe`, streaming |
| Cleanup | `mistral-small-2603`, with predicted outputs | `gpt-6-luna`, fast processing on |
| Scribe | `mistral-medium-2604` (Mistral Medium 3.5) | `gpt-6.1-sol` |
| Release → text, median | about 0.9–1.1 s | about 1.4 s |

**Mistral** is the faster default. **OpenAI** transcribes slightly more accurately on our test set, and its cleanup is slower unless fast processing is on.

### ElevenLabs Scribe v2

Choosing ElevenLabs for transcription uses `scribe_v2_realtime` while you speak and `scribe_v2` on the whole recording at release (hybrid, like Mistral). You need an ElevenLabs key for the transcription and a Mistral or OpenAI key for the cleanup and Scribe.

- **Dictionary:** your terms go to ElevenLabs as `keyterms`: at most 100 per dictation (50 while streaming, of up to 20 characters each). ElevenLabs charges 20% more for transcriptions with keyterms, and beyond 100 terms it bills every request as at least 20 seconds: diVoice never sends more than 100.
- **Context:** while streaming, the text already in the field goes as `previous_text`, so the transcription continues it.
- **Speed and accuracy:** measure them on your own voice with `divoice-bench elevenlabs` against `mistral` (see [Latency](latency.md)).

## Transcription modes

| Mode | How it works | When to use it |
|---|---|---|
| **Hybrid** (Mistral default) | Streams while you speak; at release, recordings up to 25 s are also transcribed in one piece by the file model, which is more accurate and, at that length, faster. Longer ones use the streaming result. Each is the other's fallback. | Almost always |
| **Streaming** (OpenAI default) | Streams while you speak and finishes at release | Long dictations; OpenAI |
| **File at the end** | Sends the whole recording at release | Unreliable connections |

## Options

- **Predicted outputs** (Mistral cleanup): the model is told the text will barely change, which makes it faster. diVoice turns it off automatically if Verify finds the model doesn't support it.
- **Fast processing** (OpenAI cleanup): OpenAI's priority tier. About half a second faster per dictation; cleanup costs about twice as much, which is still a few hundred tokens per dictation.

## Verify

Every step has a **Verify** button. diVoice:

1. synthesizes a test sentence with your Mac's built-in voice (no audio is shipped with the app);
2. runs it through the step with your key and the chosen model;
3. shows whether it worked, the transcript or the answer, and the time to connect, to the first token and in total.

Verify catches a wrong key, a misspelled model name, a model your account can't use, or a parameter a model doesn't accept, before you dictate. Its requests are never counted in your statistics.

## Keys

Your API keys are stored in your Mac's Keychain, readable only by diVoice, and sent only to their provider. diVoice never logs them; error messages from providers are cleaned of anything that looks like a key.

Get a key:

- Mistral: [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys)
- OpenAI: [platform.openai.com/api-keys](https://platform.openai.com/api-keys)
- ElevenLabs: [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys)

## Cost

You pay the provider for what you use, at their prices. As an order of magnitude, a dictation of 15 seconds is a few hundred tokens of cleanup plus 15 seconds of transcription: a full day of dictation typically costs a few cents. The text on screen used as context adds a few hundred tokens to each cleanup, and learning from corrections adds an occasional short request. Check your provider's pricing page for current prices.

## In an organization

The admin chooses the models for everyone, and the organization's server holds the keys. **Settings › Models** shows the models in use, read-only, with Verify. Transcription through an organization's server uses Mistral, or ElevenLabs with [diServer](https://github.com/tommasoseita/diServer) 0.6.0 or later (the admin saves its key and picks it in Settings › Organization); cleanup and Scribe can use Mistral or OpenAI. See [Organizations](organizations.md).
