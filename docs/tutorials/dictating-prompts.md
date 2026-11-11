# Tutorial: dictating prompts for an AI

Speaking is three to four times faster than typing, and a good prompt is mostly context: what you want, why, the constraints, what to avoid. With Scribe you can say all of it in whatever order it comes to mind, and get a clean prompt to send to Claude, ChatGPT or a coding agent.

## 1. Open the assistant and place the cursor

Click into the message field of the assistant, or the terminal where your coding agent runs. diVoice recognizes AI assistants and editors and treats them as "Code and AI assistants": it keeps technical terms, file names and commands exactly as you say them.

## 2. Hold Ctrl+Fn and think aloud

Don't compose: talk as you would to a colleague. For example:

> "Claude, you have to refactor the payments module, but without touching the public API, and before changing anything write the tests that cover the current behavior, then, ah, update the changelog too"

## 3. Release

Scribe rewrites what you said, keeping it a request:

> Claude, refactor the payments module without changing the public API. Before making any change, write the tests that cover the current behavior. Then update the changelog.

It **never answers the prompt or does the task**: "write an email to Sarah asking for the signed contract by Friday" comes back as that request, better written, not as the email. Questions stay questions.

## 4. Check, then send

The text lands in the field; read it and press Return. If Scribe wasn't right, ⌘Z undoes the insertion in most apps, and **Paste last dictation** in the menu bar inserts it again.

## Tips

- **Say the constraints as they come.** "Oh, and keep it under 100 words" at the end is fine: Scribe puts it where it belongs.
- **Mix languages freely.** Each part stays in the language you used.
- **For a quick prompt, plain dictation is enough.** Hold Fn without Ctrl: diVoice cleans up hesitations and punctuation but keeps your sentence structure.
- **Teach it your vocabulary.** Project names, library names, colleagues: add them to the [dictionary](your-first-dictionary.md) so they are spelled right every time.
- **To rework a prompt you already wrote,** select it, hold Ctrl+Fn and say what to change: "make it more specific", "add that the tests must not hit the network".
