# Claudex

Claudex is a macOS menu bar app that shows the 5-hour and weekly limits of your
Claude accounts.

It reads them from [tokenmaxx](https://github.com/RubricLab/tokenmaxx), which owns
sign-in, credentials and account switching. Claudex displays and asks it to switch.

<p align="center">
  <img src="docs/screenshots/accounts.png" width="280" alt="Claudex usage panel with mock Claude accounts">
</p>

## Install

Requires Apple silicon, macOS 14 Sonoma or newer, and tokenmaxx with its daemon running:

```sh
bun add -g tokenmaxx
tokenmaxx daemon install
```

### Homebrew

Recommended. Two commands on first install:

Homebrew 7 asks you to trust third-party casks first. Trust only Claudex:

```sh
brew trust --cask itizarsa/tap/claudex
brew install --cask itizarsa/tap/claudex
```

Then open Claudex from Applications.

### mise

mise installs the same Homebrew cask. Add Claudex to `mise.toml`:

```toml
[bootstrap.packages]
"brew-cask:itizarsa/tap/claudex" = "latest"
```

Install it:

```sh
mise bootstrap packages apply --manager brew-cask
```

### First launch warning

Claudex is self-signed, not notarized. The Homebrew cask clears its quarantine flag,
so Homebrew and mise installs open without a prompt.

A zip downloaded in a browser is quarantined, and macOS shows:

> Apple could not verify "Claudex.app" is free of malware.

To open it once:

1. Try opening Claudex.
2. Open System Settings.
3. Go to Privacy & Security.
4. Find the Claudex message and click Open Anyway.

Do not disable Gatekeeper globally.

## First setup

1. Add accounts with tokenmaxx: `tokenmaxx login claude`.
2. Open Claudex from Applications. It lives in the menu bar, not the Dock.
3. Click its menu bar ring to see every account's limits.

## Features

- Show 5-hour and weekly limits for every tokenmaxx Claude account.
- A menu bar ring for the active account.
- Clicking an account card switches to it.
- Refresh asks tokenmaxx to re-probe usage; otherwise Claudex re-reads the tokenmaxx
  daemon's snapshot every minute and when the panel opens.
- Launch at login.

## Build from source

Requires Xcode Command Line Tools. Full Xcode is not needed.

```sh
make bundle     # build/Claudex.app
make zip        # build/Claudex-0.1.0.zip
make install    # copy to /Applications and launch
make run        # rebuild and launch
```

## Release

Push a semantic-version tag:

```sh
git tag -a v0.1.1 -m "v0.1.1"
git push origin v0.1.1
```

GitHub Actions runs tests, builds the versioned zip, and attaches it to a GitHub
Release for the Homebrew cask. The workflow also supports manual runs for an existing tag.

Releases are signed with the self-signed `claudex-codesign` certificate, read from the
`CODESIGN_P12_BASE64` and `CODESIGN_P12_PASSWORD` repository secrets. Every release must
use the same certificate, or macOS treats the update as a different app and drops Launch
at login. Local builds use the certificate when it is in your keychain and fall back to
ad-hoc otherwise.

## Diagnostic commands

| Flag | Effect |
| --- | --- |
| `--list` | Print every account and its limits as Claudex parsed them from the tokenmaxx daemon. |
| `--panelshot <path> [fixture]` | Render the panel to a PNG, optionally from a saved `tokenmaxx status` JSON. |

Regenerate the README screenshot from mock accounts:

```sh
swift run claudex --panelshot docs/screenshots/accounts.png docs/screenshots/status.fixture.json
```

## Data

Claudex stores nothing of its own and never touches credentials. Everything comes from
the tokenmaxx daemon's socket, `~/.tokenmaxx/runtime/manager.sock`.
