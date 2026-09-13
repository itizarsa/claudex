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
    claudex --rotate   # poll, then print what the rotation rule would do. Switches nothing
    claudex --login <claude|codex>   # run the CLI's own login in a throwaway config dir
    claudex --list     # stored accounts and last known usage
    claudex --appicon <path>         # write the app icon at 1024, for make icon

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
          LaunchAtLogin.swift     # SMAppService.mainApp
        Providers/
          Provider.swift          # protocol
          ClaudeProvider.swift
          CodexProvider.swift
        Auth/
          SandboxedLogin.swift    # spawn the CLI's own login into a throwaway config dir
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

### Why the Keychain is reached through a subprocess

The in-process route does not work for a locally built app, and the workaround is a subprocess.

macOS binds a Keychain item's access control to the calling binary's code signature. An
ad-hoc signed build gets a new signature every time it is rebuilt, so the system treats each
build as a different application and raises an authorisation prompt. A background poll or a
CLI invocation cannot answer that prompt, and `SecItemCopyMatching` simply never returns.
This was observed directly: the process parked in `mach_msg` inside
`ClientSession::decrypt`, waiting on `securityd`, indefinitely.

`/usr/bin/security` is Apple-signed with a stable identity, so spawning it performs the same
operations unprompted. Verified on 2026-09-12: reading Claude Code's own
`Claude Code-credentials` item, and creating, reading and deleting claudex's own items, all
returned exit 0 immediately. `SecurityCLI` wraps the subprocess and `KeychainItem` layers
generic-password access on top; no `SecItem` call remains in the app.

Two constraints come with that route. `security` prints a payload as hex when it is not UTF-8,
and it truncates large generic-password values, so claudex stores its own values base64-encoded
and splits anything over 2 KB across numbered chunk items behind a manifest. Secrets go in on
stdin via `security -i`, never in the argument vector, which `ps` can read; the one exception is
Claude Code's own item, whose exact JSON bytes cannot survive that parser, and which is
documented in `ClaudeCLIKeychain.writeRaw`.

Tokens therefore live in the Keychain. `Settings.allowKeychain` is on by default and switching
it off falls back to `vault.json` at mode 0600 inside the app container, which is where they
lived before. Accounts written under the old default migrate on first read: `Vault.load` moves a
file entry into the Keychain and deletes it from the file. `--vault` covers both the round trip
and the migration.

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
   notification per limit window, not once per poll. The window's own reset time is the key:
   a new five-hour window is a new situation, the same one is not.

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

## Visual parity with Claude Usage Tracker

Claude Usage Tracker is the reference look for both the menu-bar ring and the popover. The
figures below were measured off 2x screenshots of it, pixel by pixel, not copied from its source:
the ring from a menu-bar capture where its item sits beside ours, the palette and bar from a
capture of its popover. Point values are the pixel measurements halved.

### Menu-bar ring

Matched to the reference, with one deliberate exception: **no weekly underline bar.** The
reference draws a 22 pt green rule under the ring for the weekly window; claudex keeps weekly in
the popover only.

Reference, measured: 44 px outer diameter, 6 px stroke, no interior fill (its background is
within two RGB units of the bar behind it), 12 px cap height and 3 px stem on the alias, and an
11 x 5 px elapsed tick straddling the stroke and overhanging its outer edge by two pixels.

Which gives, in points:

- Canvas 22 pt tall and 24 pt wide. The extra width is where the tick's overhang goes; a square
  canvas clipped it flat against the edge. `AppDelegate` pins the status item to match.
- Ring: 3 pt stroke on a 9.5 pt centreline radius, so the outer edge lands on the canvas edge.
- Alias: fixed 11 pt regular. The reference's own alias is 8 pt semibold — a 12 px cap — but
  without its darker inner disc the letter floated in an empty ring at that size, so ours is set
  larger: a 17 px cap at the same 3 px stem, which is why the weight drops as the size rises.
  It is fixed rather than fitted because filling the interior is what made our earlier ring read
  as heavier than the reference's; the fit loop only shrinks a two-character alias that would
  not otherwise clear the ring, with two points of margin so it does not sit against the stroke.
- Tick: 2.5 pt wide, butt caps, spanning the centreline radius ± 2.75 pt.

Unverified: the track colour under the arc. Every capture of the reference is at 100%, where no
track is visible. White at 0.2 alpha is a judgement call, not a measurement.

### One ring per provider, one status item

The status item was a single ring chosen by `settings.menuBarProvider`, which made "active"
effectively global. It now draws one ring per provider that has an account, each from that
provider's own active account. `AccountStore.active` was already keyed by `ProviderKind`; the
menu bar was the only place that collapsed it. `settings.menuBarProvider` is gone.

The rings share one status item rather than taking one each. Separate items look identical but
behave as separate controls: two click targets opening the same panel, and two things to drag
into position, which can be separated by another app's item. `MenuBarIcon.rings` lays them out
at a 4 pt gap and `MenuBarIcon.width(forRings:)` gives the length the item is pinned to, since
`variableLength` pads the button and the click highlight fills whatever it is given.

### Palette

Sampled from the reference's pixels rather than taken from the system palette, which is darker
and more saturated and was most of why the same layout read as harsher here:

- Red (critical): `#FF6058`
- Green (safe): `#45CD72`
- Bar track: `#383636` over a `#212020` card. Ours sits on vibrancy rather than a flat fill, so
  it is expressed as white at 0.13 alpha, which lands on that grey over that background.

Amber is unmeasured — the reference was not captured in that band — and stays `systemOrange`.

### Popover

- The "5-hour rolling window" subtitle is gone. The row label and the reset line carry it.
- Bars are capsules, 4 pt tall, with the elapsed marker 3 pt wide standing 2 pt proud at each
  end. All three are the reference's measurements.
- Inactive accounts are no longer dimmed. The Active tag is the only signal of which account is
  live. The in-flight poll dim stays.

### Measuring against the reference again

`claudex --icon <path> <alias> <percent> <elapsed>` writes the menu-bar image to a PNG at 2x,
which is what makes a pixel comparison against a screenshot possible. Each of the three values
takes a comma-separated list, one element per ring — `--icon out.png A,PE 96,42 0.8,0.35` — so
the grouped layout can be checked as well as a single ring. Diagnostics only; nothing in the app
calls `Probe.renderIcon`.

## Adding accounts

Two paths, both needed.

`Import current CLI session` reads whatever `~/.claude` or `~/.codex` is signed into right
now, fetches identity, and stores it as a new account. Cheap, no OAuth code, and it is how
existing accounts get adopted on first run.

`Sign in` runs the CLI's own login against a throwaway config directory, so an account can be
added without disturbing the currently active one:

- Claude: `claude auth login --claudeai` with `CLAUDE_CONFIG_DIR` set to a temp directory, then
  read `.credentials.json` from it. Claude Code derives its Keychain service name from that
  directory, appending a hash of the canonical path, so the sandboxed login gets its own item.
- Codex: the equivalent with `CODEX_HOME`, then read `auth.json` from it.

Both paths delete the temp directory and its Keychain item once the credential is in the vault.
The refresh endpoints and client ids still live in one constants file for the refresh path, since
they are the pieces most likely to change under the app's feet.

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

Phase 2 — switching. **Done.** `Switcher.activate` drives it, `--switch <label>` exercises it
headlessly, and the popover now calls it: an inactive card is itself the control, offering
"Switch" under the pointer, showing "Switching…" while the call runs, and reporting a failure
in the panel's notice line. A success refreshes every account of that provider, because the
swap rotates tokens on both sides and leaves both snapshots stale. The order
inside `Switcher` carries the correctness, because refresh tokens rotate and the last write
wins: harvest the outgoing account's live CLI tokens into its vault entry, persist the incoming
account's refreshed tokens before handing them over, then record the change. Skipping the
harvest silently invalidates whichever account is switched away from.

The question of whether the file alone suffices is settled: it does not. Both stores must be
written. Claude Usage Tracker writes the Keychain item, `.credentials.json` and the
`oauthAccount` block on every switch, and records why — the CLI reads the file first, so a stale
file shadows a freshly written Keychain item. CCSwitcher writes the Keychain item and treats it
as authoritative. Since `security` removes the prompt that made the Keychain write costly, the
write stays in `activate` and the two are kept in step.

Writing an item another application owns turned out to cost nothing either. Verified on
2026-09-12 by switching the Claude CLI between two live accounts: `Claude Code-credentials` was
updated through `security` with no authorisation prompt, and a subsequent read returned the new
credentials. Nothing about the Keychain now distinguishes claudex's own items from a CLI's.

Phase 3 — automation. **Done.** `Rotator` evaluates after every successful poll of a
provider's active account, `--rotate` prints the same decision without acting on it, and the
popover's gear opens the settings that drive it.

`Rotator.decide` is pure and takes its clock as an argument, so the rule can be read without a
store, a socket or a timer behind it; the class around it holds only what the rule cannot
carry, which is when each provider last switched and which exhaustion notice has already been
sent. Two readings are deliberately asymmetric: an unknown percentage never counts as over
budget, because a window the API failed to report is not evidence that it is full, and it never
qualifies an account as a target either, because it is not evidence of headroom. A stale
snapshot disqualifies a target for the same reason.

Notifications go through `Notifier`, which gates every call on the process having an
application bundle — `UNUserNotificationCenter.current()` raises without one, and the headless
flags run from the bare executable. `LaunchAtLogin` wraps `SMAppService.mainApp` behind the
same gate, and reports a refusal in the panel rather than leaving a toggle claiming something
that did not happen.

The settings live in the popover rather than a window: every control here is one line, and a
separate window for that is a second thing to find and close. Sliders write to memory as they
move and to disk when the drag ends; toggles and pickers save on the spot. `Settings.allowKeychain`
stays without UI on purpose — switching it off strands accounts whose tokens are already in the
Keychain, so it remains a file-level escape hatch.

Phase 4 — in-app sign-in. **Done.** `SandboxedLogin` runs the CLI's own login against a
throwaway config directory — `CLAUDE_CONFIG_DIR` for `claude auth login --claudeai`, `CODEX_HOME`
for `codex login` — and adopts whatever lands there. Verified on 2026-09-12 that both CLIs read a
fresh directory as signed out, which is what keeps the live account out of the flow. `PKCE.swift`
and `LoopbackServer.swift` never existed and are not coming: no loopback listener, no code
verifier, no client ids to keep current.

Both logins are interactive, and a menu bar app has no terminal to hand them, so the command goes
to Terminal.app and claudex watches the directory rather than the process. The user sees what the
CLI says when something goes wrong, which a captured pipe would swallow.

Claude Code derives its Keychain service name from the config directory, so a sandboxed login
leaves an item under a name claudex cannot compute. The set of `Claude Code-credentials…`
services is recorded before the login and diffed after it; whichever is new is the one to read
and then delete. `security dump-keychain` without `-d` lists attributes only, so that costs no
secret and no prompt. The directory's `.credentials.json` is still tried first, since it is there
whenever the CLI writes both.

The new account is stored **inactive**. Adding an account is not a request to switch to it, and
the switch is one click away in the panel. Gating is unchanged and happens before anything is
stored, because it lives in `fetchIdentity`.

Phase 5 — packaging. **Done.** `make bundle` assembles the `.app`, stamps the version, and
ad-hoc signs it; `make verify` checks the signature; `make install` puts it in `/Applications`
and relaunches it; `make uninstall` takes it back out. No `xcodebuild`: SwiftPM plus the
Makefile is the whole toolchain, which is the point of not needing the IDE.

The marketing version is set by hand and the build number is the commit count, which rises on
every commit and never repeats — macOS compares it when deciding whether a registered login
item has changed. `/Applications` is not a preference: `SMAppService` keys the registration to
the bundle's path, so an app that is run from `build/` loses "launch at login" on the next
rebuild.

The icon is drawn by the binary itself — `--appicon` writes 1024 px, `make icon` scales the set
with `sips` and hands it to `iconutil`. Authoring it as an asset would let it drift from the
ring in the menu bar; rendering it from the same code cannot. It is the ring at size on the
panel's own surface, with no alias in the middle, because the letter identifies an account and
the app icon identifies the app. A menu bar app's icon is seen in the login-items list, in a
notification and in Finder, and in all three it only has to say which app this is.

Sparkle is still deliberately left out until there is a second user.

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
CLI's store, and was dropped when writing another application's Keychain item looked impossible.
That obstacle is gone, but the ownership rule above stands on its own: two processes refreshing
the same rotating refresh token race, whatever the mechanism. Phase 1 performs no writes outside
its own container.

A switch is the one moment the rule hands over, and the handover is why `Switcher` harvests
before it overwrites. Between claudex's last look and the switch, the CLI has been refreshing
the outgoing account's token; that newer copy exists only in the CLI's store and is about to be
replaced. Reading it back into the vault first is what makes the account still usable when it is
switched to again.

## One switch for every Keychain call

`Settings.allowKeychain` gates every Keychain call in the app — claudex's own vault items and
Claude Code's `Claude Code-credentials` item alike. It is on by default. `Vault` routes to the
file store when it is off, and `KeychainVault` and `ClaudeCLIKeychain` each re-check the flag
before spawning `security`, so a single setting still decides the behaviour of every call site.

Every invocation is bounded by an 8-second timeout. `security` itself has been observed to hang
indefinitely on some macOS builds, and a Keychain call that stalls a poll is worse than one that
fails: the timeout turns the former into the latter.

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
