# claudex

macOS menu bar app that tracks 5-hour and weekly usage across multiple Claude and Codex
accounts, and rotates the active account when usage crosses a configured threshold.

Replaces Claude Usage Tracker and tokenmaxx. Deliberately drops their historical-stats
features; keeps only live limits and switching.

## Scope

In scope:

- Multiple Claude accounts and multiple Codex accounts.
- Several accounts may share one email address (account identity is a local UUID, not the email).
- Claude: claude.ai subscription accounts only (Pro / Max / Team seat). No API keys, no Bedrock/Vertex.
- Codex: ChatGPT sign-in only (`auth_mode: chatgpt`). No `OPENAI_API_KEY`.
- Menu bar item visualises the active account's 5-hour usage.
- Clicking it shows 5-hour and weekly usage for every account, both providers.
- Automatic switch to another account when the active one exceeds a configured percent.

Out of scope:

- Token/cost accounting, per-model breakdowns, daily charts, session history, CSV export.
- Windows and Linux.

## Verified integration facts

Confirmed by direct calls against the live account on 2026-09-10.

### Claude

    GET https://api.anthropic.com/api/oauth/usage
    Authorization: Bearer <claudeAiOauth.accessToken>   # sk-ant-oat01...

Response fields used:

    five_hour.utilization        # 0-100
    five_hour.resets_at          # ISO 8601
    seven_day.utilization
    seven_day.resets_at
    limits[].severity            # normal | warning | critical
    limits[].kind                # session | weekly_all | ...

Identity and subscription gating:

    GET https://api.anthropic.com/api/oauth/profile
    -> account.email, account.uuid, account.has_claude_pro, account.has_claude_max
    -> organization.uuid, organization.name, organization.rate_limit_tier, organization.seat_tier

Credential storage, both of which Claude Code reads and must be kept in sync:

- `~/.claude/.credentials.json`, key `claudeAiOauth`
  (`accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `scopes`,
  `subscriptionType`, `rateLimitTier`)
- macOS Keychain generic password, service `Claude Code-credentials`, account = the
  local Unix username. Verified byte-identical to the JSON file.

`~/.claude.json` also carries an `oauthAccount` block (email, display name, account UUID,
organization). Claude Code rewrites it after login; claudex should update it on switch so
the CLI does not show a stale identity.

### Codex

    GET https://chatgpt.com/backend-api/wham/usage
    Authorization: Bearer <tokens.access_token>
    chatgpt-account-id: <tokens.account_id>

Response fields used:

    rate_limit.primary_window.used_percent       # window 18000s  = 5h
    rate_limit.primary_window.reset_at           # unix seconds
    rate_limit.secondary_window.used_percent     # window 604800s = 7d
    rate_limit.secondary_window.reset_at
    plan_type, email, account_id

Identity comes free from the `id_token` JWT payload: `email`,
`https://api.openai.com/auth`.`chatgpt_account_id`, `.chatgpt_plan_type`.

Credential storage: `~/.codex/auth.json`
(`auth_mode`, `OPENAI_API_KEY`, `tokens.{id_token,access_token,refresh_token,account_id}`,
`last_refresh`).

### Known behavioural constraint

A running `claude` or `codex` process reads its credentials at startup and holds the
token in memory. Rewriting the Keychain or `auth.json` mid-session does not move that
session to the new account. A switch therefore applies to the *next* session. claudex
notifies on switch and never kills running processes.

## Toolchain

No Xcode on this machine, only the Command Line Tools, and SwiftUI compiles fine against
that SDK. So the build is plain SwiftPM plus a Makefile that assembles the `.app` bundle,
rather than XcodeGen. One executable target, `make bundle` to build, `make install` to drop
it in `/Applications`. Nothing about the app needs the full IDE.

The binary doubles as its own diagnostic tool. With no arguments it launches the menu bar
app; with flags it runs headless:

    claudex --probe    # read both CLIs, print parsed identity and usage. Writes nothing.
    claudex --vault    # round-trip a throwaway credential through the vault
    claudex --import   # adopt whatever the CLIs are signed into
    claudex --poll     # one poll cycle through the vault, printing each step
    claudex --list     # stored accounts and last known usage

`--probe` in particular is how to check, in one second, whether the undocumented usage
endpoints still return the shape this app expects.

## Architecture

    claudex/
      Package.swift
      Makefile                    # build, bundle, install
      Resources/Info.plist        # LSUIElement
      Sources/
        App/
          ClaudexApp.swift        # MenuBarExtra scene
          MenuBarLabel.swift      # ring + percent, severity colour
          UsagePopover.swift      # all accounts, 5h + weekly
          SettingsView.swift      # thresholds, poll interval, launch at login
        Core/
          Account.swift           # id: UUID, provider, label, email, plan, org
          AccountStore.swift      # accounts.json + Keychain, ordering
          KeychainVault.swift     # per-account token items
          UsageSnapshot.swift     # fiveHour/weekly percent + resetsAt
          Poller.swift            # timer, staggering, backoff
          Rotator.swift           # threshold evaluation, target selection
          Notifier.swift          # UNUserNotificationCenter
        Providers/
          Provider.swift          # protocol
          ClaudeProvider.swift
          CodexProvider.swift
        Auth/
          PKCE.swift
          LoopbackServer.swift    # NWListener, one-shot callback
          ClaudeAuth.swift
          CodexAuth.swift
          CLIImport.swift         # adopt whatever the CLI is signed into now

Provider protocol, one seam per CLI:

    protocol Provider {
        var kind: ProviderKind { get }                                  // .claude | .codex
        func fetchUsage(_ creds: Credentials) async throws -> UsageSnapshot
        func fetchIdentity(_ creds: Credentials) async throws -> Identity
        func refresh(_ creds: Credentials) async throws -> Credentials
        func activate(_ creds: Credentials, identity: Identity) throws  // write CLI state
        func readCurrentCLICredentials() throws -> Credentials?         // for import
    }

`activate` is the only writer of CLI state. For Claude it writes
`.credentials.json`, the Keychain item, and the `oauthAccount` block in `.claude.json`,
in that order, each as atomic replace. For Codex it writes `auth.json` atomically and
sets `last_refresh`.

State:

    ~/Library/Application Support/claudex/accounts.json   # metadata + order + active ids
    ~/Library/Application Support/claudex/settings.json   # thresholds, intervals
    ~/Library/Application Support/claudex/snapshots.json  # last known usage, for launch
    ~/Library/Application Support/claudex/vault.json      # tokens, mode 0600

### Why the tokens are not in the Keychain

This was the plan, and it does not work for a locally built app.

macOS binds a Keychain item's access control to the calling binary's code signature. An
ad-hoc signed build gets a new signature every time it is rebuilt, so the system treats each
build as a different application and raises an authorisation prompt. A background poll or a
CLI invocation cannot answer that prompt, and `SecItemCopyMatching` simply never returns.
This was observed directly: the process parked in `mach_msg` inside
`ClientSession::decrypt`, waiting on `securityd`, indefinitely.

The same applies to reading Claude Code's own `Claude Code-credentials` item from claudex.
So `ClaudeProvider` reads `~/.claude/.credentials.json` first and only falls back to the
Keychain if the file is missing. The two stores hold identical bytes, so nothing is lost.

Tokens therefore live in `vault.json` at mode 0600 inside the app container. The exposure is
unchanged from what already exists on the machine: Claude Code keeps its tokens in
`~/.claude/.credentials.json` and Codex in `~/.codex/auth.json`, both 0600, both readable by
any process running as this user. The file vault adds no new class of reader, but it is a
genuine downgrade from the Keychain and should be reversed once the app is signed with a
stable identity. `Settings.useKeychain` switches back with no other change.

There is exactly one active account per provider, so a Claude switch never disturbs Codex.

## Rotation rule

Evaluated after every successful poll of the active account:

1. If `fiveHour >= fiveHourThreshold` or `weekly >= weeklyThreshold`, the active account
   is over budget. Defaults: 5-hour 85%, weekly 90%, both configurable per provider.
2. Candidates are the other enabled accounts of the same provider whose last snapshot is
   fresh (under 10 minutes) and under both thresholds.
3. Pick the candidate with the lowest 5-hour utilisation. Tie-break on lowest weekly, then
   on the user's manual ordering.
4. Call `activate`, mark it active, post a notification naming the old and new account and
   reminding that running sessions keep the old one.
5. If no candidate qualifies, do nothing and post one "all accounts over threshold"
   notification per limit window, not once per poll.

A 60-second cooldown after any switch prevents flapping when two accounts sit near the line.
Manual switch from the popover is always allowed and resets the cooldown.

## Polling

- Active accounts every 60 s. Inactive accounts every 300 s, spread across the interval so
  requests do not burst.
- Refresh a token proactively when `expiresAt` is under 5 minutes away, and on any 401.
  Inactive accounts get refreshed on their slow schedule so their refresh tokens stay alive.
- On HTTP 429 or 5xx, exponential backoff to a 15-minute ceiling, per account.
- Snapshots are cached in memory only, plus one last-known copy on disk so the menu bar
  shows something useful at launch before the first poll lands.
- No request is made while the machine is asleep; the poller resubscribes on wake and polls
  immediately.

## Interface

Menu bar: a thin ring showing the active account's 5-hour percent, with the number beside it.
Green under 60, amber 60-85, red above 85. Optional short account label for when several
accounts are in play. Weekly severity shows as a small dot on the ring when weekly is
critical but the 5-hour window is calm — that is exactly the current 26% / 94% situation,
and it is the case both existing apps render badly.

Popover, grouped by provider, ordered by the user's arrangement:

    Claude
      ● work (arshath@superfans.io, Team)      5h ▓▓░░░░░░░░  26%   resets 19:10
                                             week ▓▓▓▓▓▓▓▓▓░  94%   resets Fri 17:00
        personal (arshath@superfans.io, Pro)   5h ░░░░░░░░░░   4%   resets 20:05
                                             week ▓▓░░░░░░░░  18%   resets Sat 09:00
    Codex
      ● main (arshath@superfans.io, Plus)      5h ▓▓▓░░░░░░░  34%   resets 19:31
                                             week ▓▓░░░░░░░░  21%   resets Mon 14:09

Row actions: make active, rename, disable, remove. Footer: add account, settings, quit.

## Adding accounts

Two paths, both needed.

`Import current CLI session` reads whatever `~/.claude` or `~/.codex` is signed into right
now, fetches identity, and stores it as a new account. Cheap, no OAuth code, and it is how
existing accounts get adopted on first run.

`Sign in` runs the CLI's own public-client PKCE flow against a loopback redirect, so an
account can be added without disturbing the currently active one:

- Claude: authorize at `https://claude.ai/oauth/authorize`, exchange at
  `https://platform.claude.com/v1/oauth/token`, client id
  `9d1c250a-e61b-44d9-88ed-5944d1962f5e`.
- Codex: authorize at `https://auth.openai.com/oauth/authorize`, exchange at
  `https://auth.openai.com/oauth/token`, client id `app_EMoamEEZ73f0CkXaXp7hrann`,
  redirect `http://localhost:1455/auth/callback`.

Both flows verify the `state` parameter and bind the code verifier to a single one-shot
listener. Client ids and endpoints live in one constants file, since they are the pieces
most likely to change under the app's feet.

Gating on add: a Claude account is rejected unless the profile reports a claude.ai
subscription (`has_claude_pro`, `has_claude_max`, or a team seat tier); an `sk-ant-api`
key is rejected outright. A Codex account is rejected unless `auth_mode` is `chatgpt`.

## Phases

Phase 1 — read-only. **Done.** SwiftPM project, account model, Keychain vault, both providers'
usage and identity calls, CLI import, poller, menu bar ring, popover. At the end of this
phase the app shows correct numbers for every imported account and changes nothing on disk
outside its own container.

Verified end to end against live accounts: both CLIs imported, both usage endpoints parsed,
the menu bar app polling on its timer and writing snapshots. The one write outside the
container that Phase 1 does perform is the refresh mirror described below.

Phase 2 — switching. `activate` is already written for both providers, with atomic writes
and a backup of the file it replaces; what remains is wiring it to a manual switch in the
popover and verifying it. Verify by switching, starting a fresh `claude` and `codex`, and
confirming each reports the expected identity.

Open question to settle first by experiment, not by guessing: whether writing
`~/.claude/.credentials.json` alone is enough for Claude Code, or whether the Keychain item
must be updated too. Updating it means a prompt, for the same code-signature reason above.
If the file alone suffices, the Keychain write can be dropped from `activate` entirely.

Phase 3 — automation. Rotator, thresholds in settings, cooldown, notifications, launch at
login via `SMAppService`.

Phase 4 — in-app sign-in. PKCE flows for both providers, so accounts can be added without
touching the CLI.

Phase 5 — packaging. `xcodebuild` release, ad-hoc signature, a `make install` that drops
the bundle in `/Applications`. Sparkle is deliberately left out until there is a second
user.

## Token ownership

Access tokens last hours and refresh tokens rotate: the token endpoint issues a replacement
and retires the one presented. Whoever refreshes must therefore also be able to store the
result, or the other holder is left with a dead token.

That settles who owns what:

- **The active account belongs to the CLI.** claudex re-reads its credentials from disk on
  every poll and never refreshes or writes them. The CLI renews its own access token as it
  runs. If the token has expired because the CLI has not been used in a while, the popover
  says so and asks for one CLI run, which is a better failure than a silent sign-out.
- **Inactive accounts belong to claudex.** Nothing else holds them, so they are refreshed
  here and stored in the vault, with no CLI contact at all.

An earlier design had claudex refresh the active account and mirror the result back into the
CLI's store. That does not work, because Claude Code keeps a second copy in a Keychain item
and writing another application's Keychain item raises an authorisation prompt. Phase 1 now
performs no writes outside its own container.

## No Keychain calls

`Settings.allowKeychain` is off by default and gates every SecItem call in the app —
claudex's own vault items and Claude Code's `Claude Code-credentials` item alike. `Vault`
routes around the Keychain when it is off, and `KeychainVault` and `ClaudeCLIKeychain` each
re-check the flag before touching the Security framework, so no future call site can
reintroduce a prompt by accident.

Turn it on only once the app is signed with a stable identity, at which point the vault
moves back to the Keychain and `activate` can update both of Claude Code's stores together.

## Risks

The usage endpoints are undocumented and can change field names without notice. Both
providers are therefore parsed leniently: unknown keys ignored, a missing window rendered
as "unknown" rather than 0%, and a parse failure surfaced in the popover instead of
silently reporting healthy. A false 0% is the one failure mode that would trigger a wrong
switch, so it is treated as an error state, never as a low reading.

Writing the Claude Keychain item and `.credentials.json` out of sync would log the CLI out.
Every activation writes to a temp file and renames, keeps a `.claudex-backup` of the
previous credentials, and rolls back if the Keychain write fails after the file write
succeeded.
