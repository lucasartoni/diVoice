# Self-hosting the organization server

diVoice's organization server is [diServer](https://github.com/tommasoseita/diServer): a Cloudflare Worker with a D1 database, one deployment per organization, shared with diMail. It has its own repository, documentation and releases, and is published on npm as `diserver`.

| What | Where |
|---|---|
| Deploying (with one click or by hand), where the data lives, configuration | [diServer › Setting up an organization server](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md) |
| Updating, backups, the server secret, recovering admin access | [setup.md › Updating](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md#updating) and the sections after it |
| What the server stores | [setup.md › What the server stores](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md#what-the-server-stores) |
| The API, and the relay protocol diVoice uses for each dictation | [diServer › API](https://github.com/tommasoseita/diServer/blob/main/docs/api.md) |

The quickest way to create one is from diVoice itself: see [Setting up a team](tutorials/setting-up-a-team.md).

## What diVoice needs from the server

- **Workers Paid.** diVoice's relay keeps a WebSocket open for each dictation and calls the providers from it, which needs the paid plan ($5/month). diMail alone works on the free plan.
- **A recent enough diServer.** When a diVoice release needs a newer server, its release notes say which diServer version, at least. Update the server before members update the app.
- **A Mistral key** for transcription through the server; cleanup and Scribe can also use OpenAI. Admins save the keys from **Settings › Organization**.

## The secret

New servers use `SERVER_SECRET`: diVoice's **Create an organization** generates it and asks you to paste it into Cloudflare. Servers set up before diServer use `DIVOICE_SECRET` for the same purpose, and it keeps working.

## Builds hosted on your server

An organization can serve its own diVoice builds from the server's `UPDATES` KV namespace: Sparkle's appcast and DMGs at `/updates/<file>`, and `updates/diVoice.dmg` as the download of invite pages. Most organizations don't need this: without it, invite pages serve the latest diVoice release from GitHub. See [Releasing](releasing.md#channels).
