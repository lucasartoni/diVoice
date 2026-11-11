# Latency

**Goal:** about 1 s from releasing the key to the text appearing in the app you're typing in.

**Acceptance:** p50 ≤ ~1.0 s and p95 ≤ 1.6 s on real dictations of 3–20 s.

## What happens in a dictation

1. **Key press.** The microphone is already prepared, so no speech is lost. diVoice reads the text on screen (150 ms at most); the streaming transcription socket opens once the names on screen are in its vocabulary, 250 ms after the press at most, and the audio recorded meanwhile follows at once. It flows to the socket while you speak.
2. **Release.** It depends on the transcription mode:
   - **hybrid** (Mistral default): recordings up to 25 s are uploaded once more to the batch model, which is more accurate and, at that length, also faster. Longer ones use the streaming result, which is almost complete at release. Each path is the other's fallback.
   - **realtime** (OpenAI default): the buffer is committed and the streaming model finishes, with no second upload.
3. **Cleanup.** A chat model removes hesitations, applies self-corrections and fixes punctuation:
   - the stable part of the prompt (rules and dictionary) comes first, so the provider caches it; the text on screen goes after it, in the request's last message;
   - Mistral also gets the transcript as predicted output;
   - the transcript's language, detected on the Mac, is named in the request, so the model doesn't translate;
   - the raw transcript is used instead after 8 s, or when the answer looks wrong (empty, inflated, truncated or in another language).
4. **Paste** into the focused app, about 50 ms.

## Budget (p50, Mistral)

| Step | Budget |
|---|---|
| Release → transcript (batch) | 300–500 ms |
| Cleanup (Small with predicted output) | 350–550 ms |
| Paste | ~50 ms |
| **Total** | **~0.9–1.1 s** |

## Where it's measured

- **App:** Settings › Latency shows the timings of recent dictations. The log has one line per dictation with the same timings and never the text:

  ```bash
  log show --last 1h --style compact --predicate 'subsystem == "app.wibo.divoice"'
  ```

- **Bench:** `scripts/bench.sh` drives the app's own engine with recorded or synthetic clips, directly or through an organization's server (`--server`); see below.

## The bench

```bash
scripts/bench.sh                                          # Mistral and OpenAI, default models
scripts/bench.sh --config openai --config "openai,fast=off"   # compare configurations
scripts/bench.sh --help
```

- **Method:** each clip is streamed at real-time pace in 100 ms blocks, as the microphone would, then the dictation ends. Times run from the release to the final text, so paste is excluded. One untimed dictation per configuration warms the connections first, as in daily use.
- **Clips:** 15 built-in dictations of 2–15 s, synthesized with the macOS voices:
  - Italian, Italian mixed with English, and English;
  - invented product names as dictionary terms;
  - each with the cleaned text the rules allow, in one or more acceptable variants.

  `--clips <folder>` uses a `clips.json` with your own recordings instead.
- **Configurations:** a provider plus options: transcription mode and models, cleanup model (also from the other provider), predicted output, OpenAI fast tier.
- **Keys:** the ones saved in diVoice; macOS asks once whether the bench may read them. Otherwise `MISTRAL_API_KEY`, `OPENAI_API_KEY` and `ELEVENLABS_API_KEY`; for an OpenAI-compatible server, `COMPATIBLE_API_KEY` and its address in `COMPATIBLE_BASE_URL` (for example `mistral,cleanup=compatible/my-model`).
- **Report:** per configuration:
  - p50 and p95 from release to text;
  - transcription and cleanup times;
  - raw WER, comparing the transcript before cleanup with the clip's text;
  - cleanup WER, comparing the final text with the closest expected text, and a strict rate that also counts capitals and punctuation;
  - dictionary terms spelled right in the final text;
  - fallbacks and errors.

## Results (9 November 2026)

From Milan, direct to the providers, the first 10 built-in clips × 3 runs per configuration, with the Italian prompts used until then.

| Configuration | p50 | p95 | Transcription p50 | Cleanup p50 | Cleanup first token p50 | Raw WER | Terms | Fallbacks |
|---|---|---|---|---|---|---|---|---|
| **Mistral** (default) | **940** | 2013 | 474 | 517 | 371 | 4.8% | 36/36 | 1 |
| **OpenAI**, standard tier | **1899** | 3147 | 684 | 1065 | 918 | 3.6% | 36/36 | 0 |
| OpenAI, hybrid | 1660 | 3460 | 527 | 1032 | 790 | 3.4% | 36/36 | 0 |
| **OpenAI, fast tier** (now the default) | **1406** | 1911 | 720 | 691 | 527 | 3.8% | 36/36 | 0 |
| OpenAI, `gpt-5.4-mini` cleanup | 1518 | 2224 | 712 | 813 | 694 | 3.8% | 36/36 | 0 |
| OpenAI transcription, Mistral cleanup | 1235 | 2493 | 730 | 504 | 337 | 3.6% | 36/36 | 2 |

Times in ms.

**What we learned**

1. **Mistral is close to the goal in personal mode:** p50 940 ms on the built-in clips, plus paste.
   - On the clips of the first spike (below), the direct engine measured p50 1118 ms. The earlier server-side pipeline measured 861 ms on those clips the day before.
   - Most of the gap is cleanup: 496 ms against 377. Transcription is 492 against 456.
   - The server couldn't be measured again the same day, so part of the gap may be day-to-day variation. Repeat the comparison when release 2 brings the server back.
2. **OpenAI takes twice as long, mostly in cleanup:**
   - `gpt-6-luna` needs about 1 s to the first token;
   - the fast tier halves that (p50 1.4 s) at twice the price of cleanup, which is a few hundred tokens per dictation. It is now the default, and Settings › Models says what it costs;
   - transcription takes about 700 ms after release, against Mistral's ~470 ms with batch.
3. **Hybrid helps OpenAI less than Mistral.** It saves about 150 ms on transcription but pays for the audio twice, and OpenAI's streaming model doesn't lose sentence beginnings the way Mistral's does. So realtime stays the OpenAI default.
4. **Accuracy is similar:** WER of 3.4–4.8% on synthetic voices, and every configuration spelled all dictionary terms right.
5. **Cleanup must not translate.** With the Italian prompt, Mistral Small translated the English clip into Italian in 3 cleanups out of 6, despite the rule against it. A guard now discards those answers and inserts the raw transcript (these are the fallbacks in the table). The cause is fixed by the next section's changes.
6. **The tail is the provider's.** Mistral's p95 is about 2 s. In an earlier run, `gpt-6-luna` gave no first token for 8 s on two dictations in a row; the timeout inserted the raw transcript.

## Prompt language (9 November 2026)

**Question:** can the prompts be in English without the Italian cleanup getting worse? The rule was to adopt them only if it didn't.

**Method:**
- all 15 clips × 3 runs, Mistral and OpenAI with the fast tier;
- the same bench with the Italian prompts, then with the English ones;
- cleanup WER and strict rate per clip group.

**English prompts alone weren't enough.** Mistral Small then translated a short English sentence into Italian ("Thanks. I'll send it over tonight." became "Grazie. Lo invio stasera."). The Italian examples in the rules probably pulled it there. The fix: the transcript's language, detected on the Mac with `NLLanguageRecognizer`, goes into the request ("Transcript language: English. Keep it…"), outside the cached system prompt.

**Result** (English prompts with the language line, against the Italian prompts):

| Provider | Clips | Cleanup WER, Italian prompts | Cleanup WER, English prompts | Strict, Italian prompts | Strict, English prompts | Translations |
|---|---|---|---|---|---|---|
| Mistral | Italian | 5.4% | **2.2%** | 8.1% | **5.0%** | 0 → 0 |
| Mistral | Mixed | 9.1% | 9.1% | 11.3% | 10.4% | 0 → 0 |
| Mistral | English | 0.0% | 0.0% | 6.8% | 6.5% | 0 → 0 |
| OpenAI | Italian | 1.2% | **1.0%** | 2.9% | **1.9%** | 0 → 0 |
| OpenAI | Mixed | 5.0% | **3.0%** | 6.6% | **3.9%** | 0 → 0 |
| OpenAI | English | 0.0% | 0.0% | 6.2% | 7.0% | 0 → 0 |

The Italian cleanup improved with both providers, and latency didn't change (Mistral p50 1072 ms, OpenAI 1508 ms). The English prompts are adopted.

**Remaining misses, the same with both prompt languages:**
- a hesitation transcribed as a lone "M" is left in;
- two adjacent product names are merged by the transcription ("Nimbly Orbix");
- Mistral Small sometimes drops an opening phrase.

## Through an organization's server (9 November 2026)

**Method:**
- the same 15 clips × 3 runs, through an organization's server on Cloudflare Workers, with the organization's models (Mistral's defaults);
- run as Verify sessions, which never reach the team's statistics;
- the server reports its own timings, so its share can be separated from the provider's.

| | Release → text p50 | p95 | Transcription p50 | Cleanup first token p50 |
|---|---|---|---|---|
| Direct from the Mac (same morning, previous section) | 1072 | 2356 | 479 | 382 |
| Through the server | 1295 | 2289 | 601 | 423 |
| **Through the server, connection to the provider opened at the key press** | **1060** | **1767** | 492 | 414 |

1. **The connection between the app and the server costs little:** about 22 ms on the transcription and 32 ms on the cleanup. The provider key is cached on the server for a minute (0 ms).
2. **Most of the extra time was the server opening a new connection to Mistral at release.** It now opens one while the user speaks, so the batch transcription and the cleanup find it ready. That brought the server's transcription from 580 to 430 ms, and the total back to the direct level.
3. **Scribe through the server** (Mistral Large 4, 3 drafts × 3):
   - first token p50 2.5 s, p95 12.5 s for an email;
   - Mistral starts answering in about 0.6 s: the rest is the model's reasoning;
   - no answer cut off, since requests leave room for the reasoning on top of the answer's limit. Before, a 120-token Verify ended after two words.

## Scribe models (9 November 2026)

**Goal:** the first word in under 1.5 s, without Scribe answering instead of writing, inventing facts or changing the meaning.

**Method:**
- 20 realistic requests × 2 runs, direct (`scripts/bench.sh --scribe`):
  - drafts (emails, Slack, a LinkedIn post, notes);
  - rewrites of a selected text (shorten, more formal, translate, fix typos, friendlier, bulleted list);
  - two questions for colleagues, which Scribe must write rather than answer;
- automatic flags (assistant-style openings, numbers not in the request, facts lost);
- every answer also read side by side.

| Scribe | First token p50 | p95 | Total p50 | p95 | Under 1.5 s | Invented facts (read) |
|---|---|---|---|---|---|---|
| Mistral Small, no reasoning | 469 | 1049 | 784 | 2157 | 38/40 | yes, in both runs |
| Mistral Small, reasoning "high" | 1840 | 4350 | 2090 | 4605 | — | yes |
| **Mistral Medium 3.5** (`mistral-medium-2604`) | **434** | **1129** | **753** | **1480** | **40/40** | **none** |
| Mistral Large 4, reasoning "low" (previous default) | 5025 | 11961 | 5331 | 12068 | — | none |

Times in ms.

- **Small invents with the dictionary at hand.** Examples: "Marco has been working on the Kestrel project", "your recent work on Orbix and Zentrix", the surname "Rossi", a collaboration "between [Orbix] and [Zentrix]" in a thank-you note, a reason for moving a meeting that wasn't given. Reasoning doesn't fix it.
- **Medium stays faithful and is as fast as Small.** It is sometimes terse: "make it friendlier" barely changes the tone, and a bulleted list dropped its opening sentence.
- **No model answered the two questions instead of writing them,** and none was cut off.

**Choice:** Mistral Medium 3.5 is Scribe's default, also on organization servers. Its text goes into the app when it is complete.

## Scribe as an editor (9 November 2026)

**What changed:** Scribe no longer writes a text from an intention. It edits what was dictated:
- it reorders, fixes muddled sentences, makes it concise and uses lists when helpful;
- it keeps the content, the intent, the language and the person;
- it never carries out the dictation: a dictated prompt ("write an email to Marco…") stays a prompt.

With selected text, the dictation is still an instruction on how to change it.

**Method:**
- 20 new dictations: muddled or repetitive messages, prompts for an AI, questions, texts to reorder, in Italian, English and mixed;
- plus 6 rewrites of a selected text;
- 2 runs each, all answers read.

| Scribe, final prompt | First word p50 | Under 1.5 s | Carried out instead of edited | Meaning changed or facts added (read) |
|---|---|---|---|---|
| Mistral Small, no reasoning | 435 ms | 51/52 | 5 | several |
| **Mistral Medium 3.5** | **401 ms** | **47/52** | **0** | 3 minor ones, in both runs |

- **Small carries the request out:** it answered a question, wrote the email or the post it was asked to request, and opened with "Here's the rewritten text".
- **Medium kept every prompt a prompt and every question a question.**
- **Medium's remaining slips:**
  - a mixed Italian/English prompt that asks for "a summary in English" came out all in English;
  - a final step ("then update the changelog") was grouped with the steps before it;
  - "for tomorrow" was dropped from a to-do list.

**Medium stays Scribe's default.**

## From the first latency spike (8 November 2026)

Measured through the earlier server-side version, with the same streaming method:

1. **Mistral's streaming model loses sentence beginnings.** "Ho appena mandato" became "Atena mandato", and an opening "Ciao, ehm, ti confermo che…" could vanish entirely. The batch model sees all the audio and gets them right; hence hybrid.
2. **Up to ~25 s batch is also faster than streaming.** Beyond that streaming wins, because at release it has almost finished. On a 57 s clip:

   | | Transcription | Total |
   |---|---|---|
   | Batch | 1.35–1.6 s | 2.9–3.6 s |
   | Streaming | 0.42 s | 1.6–1.7 s |
3. **Starting the microphone at the key press lost the first ~300 ms of speech** ("Chavo" for "Ciao"). The audio engine is now prepared in advance, and the start sound plays when it is really recording: that's the signal to speak.
4. **Cleanup was too aggressive.** It removed greetings and opening phrases along with self-corrections, and the prompt rules are now more precise. Mistral Small still occasionally drops an opening phrase such as "ti confermo che".
5. **Scribe on `mistral-large-4-0` takes 3–12 s**, almost all of it reasoning before the first token. `mistral-small-2603` answers in 0.6–2 s but takes more liberties: once it replied to the message instead of writing it.

## Levers if over budget, in order

1. **Fast path:** short, clean sentences skip the model (`fastPathMaxWords`). It is off by default, because the model also fixes recognition errors (about 350 ms).
2. **Prompt cache:** the stable prefix comes before the transcript (`prompt_cache_key`).
3. **A cleanup model from the other provider,** for OpenAI transcription: Mistral Small cleans up in about 500 ms.
4. **Batch per segment:** transcribe finished segments at each pause while speaking, so at release only the last one is left. This would also give batch accuracy beyond 25 s.
