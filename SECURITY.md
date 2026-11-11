# Security policy

diVoice handles your voice, your text and your API keys. We take reports seriously and appreciate responsible disclosure.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub: on the repository's **Security** tab, click **Report a vulnerability** ([direct link](https://github.com/tommasoseita/divoice/security/advisories/new)).

Include:

- what an attacker can do, and under which conditions;
- steps to reproduce, or a proof of concept;
- the diVoice version (menu bar › version) and, for the server, its diServer version.

We'll acknowledge your report, keep you informed while we work on a fix, and credit you in the release notes unless you prefer otherwise. Please give us reasonable time to release a fix before disclosing.

## Supported versions

Security fixes go into the latest release of the app and of the server. The app updates itself; organizations should keep their server on the latest version (see [Updating](https://github.com/tommasoseita/diServer/blob/main/docs/setup.md#updating) in diServer's documentation).

## In scope

- **The app:** exposure of API keys, organization tokens, dictated text or audio; insertion of text into the wrong app; bypass of the confirmation before joining an organization; update integrity.
- **The organization server** is [diServer](https://github.com/tommasoseita/diServer): report its vulnerabilities (authentication, invites, exposure of provider keys or of members' data, abuse of the relay, the setup claim) privately in that repository. If you're unsure which project an issue belongs to, report it here.

Out of scope: vulnerabilities in the AI providers' services, in macOS or in Cloudflare; denial of service against your own deployment; issues that require an already compromised Mac.

## How diVoice protects your data

- API keys and the organization token are stored in the macOS Keychain, readable only by diVoice's signature.
- Keys are sent only to their provider; error messages are scrubbed of anything that looks like a key or a bearer token; logs never contain dictated text.
- The server stores provider keys encrypted (AES-GCM, key derived from the deployment's secret), never returns them, and stores member tokens only as SHA-256 hashes.
- Joining an organization always asks for confirmation, showing the server's address, because that server will receive your audio.
- Updates are signed with EdDSA and notarized by Apple, and verified before they install.

See [Privacy](docs/privacy.md) for what data goes where.
