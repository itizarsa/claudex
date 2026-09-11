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

Open the app and use "Import current" for each provider, or do it headlessly:

    ./build/Claudex.app/Contents/MacOS/claudex --import

## Headless flags

The same binary runs as a diagnostic tool.

| Flag | Effect |
| --- | --- |
| `--probe` | Read both CLIs, print parsed identity and usage. Writes nothing. |
| `--vault` | Round-trip a throwaway credential through the vault. |
| `--import` | Adopt whichever account each CLI is signed into. |
| `--poll` | One poll cycle through the vault, printing each step. |
| `--list` | Stored accounts and last known usage. |

`--probe` is the quickest way to tell whether the undocumented usage endpoints still return
the shape this app expects.

## Where state lives

    ~/Library/Application Support/claudex/accounts.json    metadata, ordering, active account
    ~/Library/Application Support/claudex/settings.json    thresholds, poll intervals
    ~/Library/Application Support/claudex/snapshots.json   last known usage
    ~/Library/Application Support/claudex/vault.json       tokens, mode 0600

Tokens are in a 0600 file rather than the Keychain because an ad-hoc signed build gets a new
code signature on every rebuild, which makes macOS treat it as a different application and
block on an authorisation prompt that a background poll cannot answer. `Settings.allowKeychain`
is off by default and gates every Keychain call in the app; turn it on once the app is signed
with a stable identity. See PLAN.md.

claudex never refreshes or writes the credentials of the account a CLI is currently signed
into — refresh tokens rotate, and the replacement could not be handed back without a Keychain
prompt. Those credentials are re-read from disk on each poll instead. Accounts that are not
active belong to claudex and are refreshed normally.

## Status

Phase 1 (read-only tracking) is done. Switching, automatic rotation and in-app sign-in are
described in PLAN.md.
