# bb Account Pooler

Source inspected: bb 0.43.1's bundled `account-pool` plugin, version 0.1.0. The
implementation was recovered from its shipped JavaScript source map. This document copies the
plugin's operating notes into the project and records the parts relevant to claudex.

## Accounts and routing

The built-in Account Pooler plugin is disabled by default. Enable it, add Claude or Codex
credentials, and inspect its proxy routes and account quota with:

```sh
bb plugin enable account-pool
bb pool account add --provider claude --login
printf '%s\n' "$CLAUDE_AUTH_CODE" | bb pool account login-complete --session <id> --code-stdin
bb pool account add --provider codex --login
bb pool account login-poll --session <id>
bb pool account add --provider claude --import
bb pool account add --provider codex --import
printf '%s\n' "$ANTHROPIC_API_KEY" | bb pool account add --provider claude --api-key-stdin [--label <text>] [--priority <n>]
bb pool account add --provider claude --api-key <key> [--label <text>] [--priority <n>]
bb pool account list [--json]
bb pool account remove <id>
bb pool account enable <id>
bb pool account disable <id>
bb pool account priority <id> <n>
bb pool account reorder <claude|codex> <id>...
bb pool account refresh <id>
bb pool status [--json]
bb pool routing <claude|codex> [--off]
bb pool config
bb pool config set <anthropicUpstreamBaseUrl|codexUpstreamBaseUrl|switchThreshold> <value>
bb pool token rotate --machine <id-or-name>
bb pool bypass <thread-id> [--off]
```

Claude `--login` starts a PKCE session, prints a browser URL and session ID, then exits. The
manual callback code is piped to `account login-complete` with that session ID within ten
minutes. Codex `--login` prints a device verification URL, one-time code, session ID, and an
`account login-poll` command that waits for authorization. The Claude code stays out of process
arguments, and either browser may be on a different machine from the bb server.

Newly added or enabled accounts are available without a plugin reload. With an enabled account
whose secret file remains readable and valid, matching Claude Code or Codex sessions receive the
pool route and a distinct secret token for their machine.

Codex receives `CODEX_OPENAI_BASE_URL` and the secret `CODEX_POOL_AUTH_TOKEN`; bb applies them as
in-memory app-server configuration. Codex image generation and editing use the same authenticated
pool route. Claude Code receives `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`.

Tokens are never printed. `status` prunes tokens for unenrolled machines and shows token
timestamps plus recently routed threads whose machines need a local Claude login before the pool
can be disabled safely. Rotation keeps the prior token valid for ten minutes.

Agents should pipe API keys to `--api-key-stdin`. `--api-key <key>` is an unsafe compatibility
form that exposes the key in process arguments, shell history, and agent transcripts. Prefer
`--import` for an existing Claude Code login. The Codex import path reads `~/.codex/auth.json` on
the bb server host.

OAuth quota refreshes on add or enable and every five minutes while an account is idle. Use
`bb pool account refresh <id>` to request an immediate refresh for one account. Account tables
record model-family buckets. JSON status exposes their utilization, reset, status, observation
time, and source under `familyWeekly`. Selection skips an account whose requested family is spent
while retaining it for other families. A present `metadata.user_id` account UUID is aligned with
the selected OAuth account.

`bb pool config` displays the full routing configuration. The upstream URL settings are intended
for QA. `switchThreshold` must be greater than zero and at most one; its default is 0.98.

Accounts run sequentially per provider. Lower priority numbers run first, with ties following
insertion order. New conversations use the current account until it reaches the switch threshold
or fails. The pool then advances to the next eligible account and wraps at the end. It keeps using
that fallback even when an earlier account recovers.

Existing conversations stay pinned while their account remains eligible. Short temporary rate
limits wait on the same account once. Longer holds return `Retry-After` for pinned conversations
while new conversations can advance. A model-family limit detours only requests for that family
without moving the session's main pin or provider cursor. The cursor and session pins survive hub
restarts. Session pins expire after 30 idle minutes, and the pool retains the 4,096 most recently
used pins.

Reordering changes the next failover sequence without moving the current account. The full order
must include disabled accounts too.

## Architecture

bb does not switch files in Claude Code's or Codex's credential stores. It turns the provider
session into a client of a local HTTP proxy:

1. bb injects a local base URL and a machine-specific hub token into each launched provider.
2. The hub authenticates that token, selects a pool account, and replaces the request's
   authentication headers with that account's OAuth access token.
3. The hub forwards the request to Anthropic or ChatGPT and records quota response headers.
4. The hub refreshes and persists the selected account's credentials when required.
5. Routing state advances only after the upstream accepts a request.

This gives bb sole ownership of each stored pool credential. Routed provider processes never
receive the provider refresh token. bb therefore avoids the active-account handoff problem that
claudex must solve when it changes a CLI's own credential store.

Account secrets live in bb's private data directory. The directory uses mode `0700`; individual
JSON files use mode `0600`. Updates write a temporary file and atomically rename it over the old
file.

One caveat remains. `--import` copies an existing CLI refresh token into bb without removing or
updating the original CLI copy. A standalone CLI outside bb and the pool can then race to rotate
the same refresh token. bb's direct PKCE and device-login flows avoid that shared ownership by
creating a separate login session.

## Best ideas worth borrowing

### Deduplicate refreshes per account

bb keeps one in-flight refresh operation per account. Concurrent requests await that operation
instead of presenting the same rotating refresh token multiple times. claudex should enforce the
same invariant across polling and switching, preferably behind a per-account actor or equivalent
serialized operation.

### Associate failures with the token that failed

After a `401`, bb rereads the stored secret and compares its current access token with the token
rejected upstream. It marks the account broken only when they still match. A late response from an
old request therefore cannot poison credentials that another request has already refreshed.

claudex should carry the attempted access-token fingerprint through usage failures and ignore an
authentication failure when the stored credential has since changed.

### Force one refresh after authentication rejection

Expiry timestamps are hints. bb force-refreshes once after `401`, even when the access token has
not reached its stated expiry, then retries the request once. claudex already follows this shape
for inactive-account usage polling and should preserve it as provider code is refactored.

### Persist rotated credentials before reuse

Both provider adapters write the refreshed secret before returning it to the request path. This
keeps the durable refresh token ahead of any operation that can fail or be cancelled after the
refresh. claudex follows this rule in `UsageEngine` and `Switcher`; tests should keep the ordering
explicit.

### Separate transient refresh backoff from permanent auth failure

bb treats timeouts, HTTP 408, HTTP 429, and server errors as transient refresh failures. It applies
bounded exponential backoff and honors `Retry-After`. A non-transient refresh error marks the
account unusable. Keeping these states separate prevents a brief provider outage from disabling a
valid account.

### Keep selection state stable until success

bb does not advance its active-account cursor merely because it selected another account. It
commits the new cursor only after an upstream request succeeds. claudex should likewise record an
account as active only after credentials have been refreshed, persisted, and written successfully
to every CLI store.

### Preserve conversation affinity when proxying

This does not apply to claudex's current credential-switching architecture, where a running process
keeps credentials loaded at startup. If claudex ever gains a proxy mode, it should copy bb's
session pinning: retain one account for an existing conversation, detour only when that account is
ineligible, and use a bounded idle TTL for stored pins.

## Difference from claudex

claudex changes the CLI's native credential state so future terminal sessions work without shell
configuration or a proxy. That requires an explicit ownership handoff: harvest the outgoing live
credential, refresh and persist the incoming credential, write every CLI credential store, then
record the account switch.

bb avoids that handoff by controlling provider launch configuration and keeping every routed
request behind its proxy. Adopting bb's full design would change claudex from a transparent menu
bar switcher into a proxy plus shell or process-launch integration. The concurrency and failure
handling ideas above transfer cleanly; the proxy architecture does not.
