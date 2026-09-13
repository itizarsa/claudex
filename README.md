# claudex

A macOS menu bar app that tracks 5-hour and weekly usage across multiple Claude and Codex
accounts, and switches the active account when usage crosses a threshold.

Claude accounts must be claude.ai subscriptions; Codex accounts must be ChatGPT sign-ins.
API keys are rejected. Several accounts may share one email address.

## Build

Requires the Xcode Command Line Tools. Xcode itself is not needed.

    make bundle     # build/Claudex.app
    make install    # copy to /Applications
    make run        # rebuild and launch

## First run

Open the app and use the plus button for each provider, or do it headlessly:

    ./build/Claudex.app/Contents/MacOS/claudex --login claude
    ./build/Claudex.app/Contents/MacOS/claudex --login codex

## Headless flags

The same binary runs as a diagnostic tool.

| Flag | Effect |
| --- | --- |
| `--probe` | Read both CLIs, print parsed identity and usage. Writes nothing. |
| `--vault` | Round-trip a throwaway credential through the vault. |
| `--poll` | One poll cycle through the vault, printing each step. |
| `--switch <label>` | Sign a CLI into a tracked account. |
| `--rotate` | Print the current automatic-rotation decision without switching. |
| `--login <provider>` | Add an account through the provider CLI's browser login. |
| `--list` | Stored accounts and last known usage. |

`--probe` is the quickest way to tell whether the undocumented usage endpoints still return
the shape this app expects.

## Where state lives

    ~/Library/Application Support/claudex/accounts.json    metadata, ordering, active account
    ~/Library/Application Support/claudex/settings.json    thresholds, poll intervals
    ~/Library/Application Support/claudex/snapshots.json   last known usage

Tokens live in one macOS Keychain item per account. claudex reaches the Keychain through
`/usr/bin/security`, whose stable Apple signature allows locally built versions to use those
items without an authorization prompt. Older `vault.json` entries migrate into the Keychain on
first read and are then deleted.

claudex never refreshes or writes the credentials of the account a CLI is currently signed
into. Refresh tokens rotate, and a running CLI keeps its old token in memory even after claudex
writes the replacement to disk and Keychain. Active credentials are re-read and mirrored on each
poll. Accounts that are not active belong to claudex and are refreshed normally.

## Status

Tracking, switching, automatic rotation, and in-app sign-in are implemented. See PLAN.md for
design details.
