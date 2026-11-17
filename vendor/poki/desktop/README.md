# Poki Setup

The desktop companion for the Poki iPhone app, for macOS and Windows. One click installs Poki on an iPhone with your own Apple ID, pairs the phone, keeps the app signed, and manages your relay and connector links. It is what SideStore and AltServer do for sideloading, done for Poki, and it is the way in for iPhones below iOS 27 (which cannot pair with themselves) and for free Apple IDs (which must re-sign every 7 days).

```
desktop/
  core/   poki-setup-core: everything, no UI (Rust)
  cli/    poki-setup: the same steps on the command line
  app/    Poki Setup: Tauri 2 shell + React page in the iPhone app's design
```

## What it does

| Step | How |
|---|---|
| Finds the iPhone | usbmuxd over the cable (macOS has it; Windows gets it with iTunes or Apple Devices); Wi-Fi with a saved pairing record |
| Pairs | lockdown pairing; the person taps Trust once; the record is saved for Poki |
| Developer Mode | turned on through AMFI; the phone restarts once and asks |
| Signs in | Apple's GSA (SRP-6a, 2FA by trusted device or SMS); anisette from macOS itself, or an anisette v3 server on Windows |
| Developer portal | registers the phone, makes an RSA key and certificate for this computer, App IDs `nz.zheha.poki.<TEAM>` and `.widgets`, the app group, team profiles |
| Signs Poki | the newest Beta release from R2, with GitHub as a network-failure fallback; re-signs the external edition with the existing signing identity |
| Installs | installation_proxy, profiles through misagent |
| Pairing file | written straight into Poki's container, and offered as a `poki://pairing?url=…&sha256=…` QR on the LAN |
| Keeps it alive | the phones this computer set up, with their expiry; renewal is due with 2 days left and runs by itself every 6 h when the password is kept |
| Relay | deploys `deploy/cf-relay/worker.js` to your own Cloudflare account through the API and shows the `poki://setup?relay=` QR |
| Connectors | keeps links the phone made, runs the OAuth round and `tools/list` through the phone, writes client snippets |
| Debug | live syslog, developer disk image, support bundle for private review before sharing |

## For agents

Poki Setup ships its command line tool, `poki-setup`, inside the app: `/Applications/Poki Setup.app/Contents/MacOS/poki-setup` on macOS and `%LOCALAPPDATA%\Poki Setup\poki-setup.exe` on Windows. An agent on the computer (Claude Code, Codex and the like) can run the whole setup with it:

- `poki-setup next --json` reads the computer's state and lists what is done, what comes next, who has to act and the command to run. It changes nothing.
- With `--json`, every command prints its result on stdout and its progress on stderr, one JSON object per line. Exit codes: 0 done, 1 failed, 2 a person has to act, 3 waiting for Apple's sign-in code.
- Sign-in works without a terminal: `login <email> --password-stdin`, then `login --code <code>` when Apple asks for one. The person can also run `login <email>` in their own terminal, which keeps the password out of the agent.
- `poki-setup update` updates Poki Setup itself to the newest Beta.
- `poki-setup prompt` prints the instructions to hand an agent ([AGENT-PROMPT.md](AGENT-PROMPT.md)). The app copies the same text: Poki > Copy Prompt for Your Agent on a Mac, Settings > Use an agent on Windows.

## Build

```sh
cd desktop
cargo test -p poki-setup-core            # unit tests (POKI_SETUP_FILE_SECRETS=1 on a headless box)
cargo run -p poki-setup-cli -- --help     # the CLI
cd app && npm ci && npm run tauri dev     # the app (needs Rust, Node 22, and on Linux webkit2gtk-4.1)
npm run tauri build                       # DMG / MSI; .github/workflows/desktop.yml does this for both OSes
```

Data lives in the OS app-data directory (`POKI_SETUP_HOME` overrides it): pairing records, keys (0600), the release cache, state. The Apple session and, if chosen, the password are in the OS keychain.

## Release approval

Uploading Poki Setup installers requires the repository owner's approval. The Windows workflow
uses the protected `stable` environment. The macOS workflow only creates Actions artifacts.
For app channels, Pre-alpha is automatic; Alpha, Beta, and Stable require the owner's approval.
See [Release channels](../docs/release-channels.md).

## Licences

The crate is AGPL-3.0-only like Poki. Logic ported from: SideStore's icloud-auth and omnisette (MPL-2.0; GSA and anisette protocol), Dadoum's Sideloader (GPL-3.0; developer portal shapes), AltSign (AGPL-3.0; the entitlement rule). Apple's corecrypto and ldid are not used. See THIRD_PARTY_NOTICES.md.
