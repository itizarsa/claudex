# Claudex

Claudex is a macOS menu bar app that shows the 5-hour and weekly limits of your
Claude and Codex accounts.

It reads them from [tokenmaxx](https://github.com/RubricLab/tokenmaxx), which owns
sign-in, credentials and account switching. Claudex only displays.

<p align="center">
  <img src="docs/screenshots/accounts.png" width="280" alt="Claudex usage panel with mock Claude and Codex accounts">
</p>

## Install

Requires Apple silicon, macOS 14 Sonoma or newer, and tokenmaxx:

```sh
bun add -g tokenmaxx
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

Add Claudex to `mise.toml`:

```toml
[bootstrap.packages]
"brew-cask:itizarsa/tap/claudex" = "latest"
```

Install it:

```sh
mise bootstrap packages apply --manager brew-cask
```

### DMG

[Download latest release](https://github.com/itizarsa/claudex/releases/latest), open
the DMG, then drag Claudex into Applications.

### First launch warning

Claudex 0.1.0 is ad-hoc signed and not notarized. macOS may show:

> Apple could not verify "Claudex.app" is free of malware.

To open it once:

1. Try opening Claudex.
2. Open System Settings.
3. Go to Privacy & Security.
4. Find the Claudex message and click Open Anyway.

Do not disable Gatekeeper globally. Homebrew and mise install the same DMG, so
they cannot remove this warning.

## First setup

1. Add accounts with tokenmaxx: `tokenmaxx login claude`, `tokenmaxx login codex`.
2. Open Claudex from Applications. It lives in the menu bar, not the Dock.
3. Click its menu bar ring to see every account's limits.

## Features

- Show 5-hour and weekly limits for every tokenmaxx Claude and Codex account.
- One menu bar ring per provider, for its active account.
- Refresh asks tokenmaxx to re-probe usage; otherwise Claudex re-reads
  `tokenmaxx status` every minute and when the panel opens.
- Launch at login.

## Build from source

Requires Xcode Command Line Tools. Full Xcode is not needed.

```sh
make bundle     # build/Claudex.app
make dmg        # build/Claudex-0.1.0.dmg
make install    # copy to /Applications and launch
make run        # rebuild and launch
```

## Release

Push a semantic-version tag:

```sh
git tag -a v0.1.1 -m "v0.1.1"
git push origin v0.1.1
```

GitHub Actions runs tests, builds the versioned DMG, and attaches it to a GitHub
Release. The workflow also supports manual runs for an existing tag.

Builds remain ad-hoc signed until Developer ID signing and Apple notarization are
configured.

## Diagnostic commands

| Flag | Effect |
| --- | --- |
| `--list` | Print every account and its limits as Claudex parsed them from `tokenmaxx status`. |
| `--panelshot <path> [fixture]` | Render the panel to a PNG, optionally from a saved `tokenmaxx status` JSON. |

Regenerate the README screenshot from mock accounts:

```sh
swift run claudex --panelshot docs/screenshots/accounts.png docs/screenshots/status.fixture.json
```

## Data

Claudex stores nothing of its own and never touches credentials. Everything comes from
`tokenmaxx status`.
