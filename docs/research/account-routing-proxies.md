# Account-routing proxies in TokenMaxx and bb

Research date: 2026-09-13.

## Question

Can claudex use a local proxy so Claude Code and Codex processes pick up an account switch
without restarting?

Yes. A process must start with its provider base URL pointed at the proxy once. After that, the
proxy can choose credentials for each HTTP request. Replacing the native CLI credential file is
no longer part of the request path.

This does not capture processes started before routing was installed. Those processes need one
restart. Nor can a proxy move a response that is already streaming. It can choose a different
account for the next request, or replay a request after an upstream rejection if no response body
has reached the client.

```text
Claude Code / Codex
        |
        | provider request plus local proxy credential
        v
loopback listener
        |
        | authenticate caller, select account, refresh if needed
        v
provider adapter
        |
        | strip client auth, inject selected account auth
        v
Anthropic / ChatGPT Codex backend
```

## Sources and versions

TokenMaxx findings use RubricLab/tokenmaxx commit
[`6cd7172`](https://github.com/RubricLab/tokenmaxx/tree/6cd7172d828c6a0b8378168671a36e2013d7e179),
package version `0.0.66`. Relevant primary sources are its
[`proxy.ts`](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/proxy.ts),
[`manager.ts`](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/manager.ts),
[`config-install.ts`](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/config-install.ts),
[`claude.ts`](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/claude.ts), and
[`codex.ts`](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/codex.ts).

bb findings use bb `0.43.1` and its bundled Account Pooler plugin `0.1.0`. The plugin ships at:

```text
/Applications/bb.app/Contents/Resources/app.asar.unpacked/node_modules/
  bb-app/server/dist/builtin-plugins/account-pool/
```

The primary implementation is recoverable from `dist/server.js.map`, whose embedded original
sources include `src/hub.ts`, `src/provider-adapter.ts`, `src/request-body.ts`,
`src/claude-adapter.ts`, and `src/codex-adapter.ts`. The bundled operating reference is
`skills/account-pool/references/accounts-and-routing.md`. A prior detailed extraction lives in
[bb-account-pool.md](./bb-account-pool.md).

## TokenMaxx implementation

### Client routing

TokenMaxx starts a Bun HTTP server on `127.0.0.1:8459` by default. `/openai/*` and
`/anthropic/*` select the provider. It refuses unknown route prefixes. The listener uses an
unlimited idle timeout so long responses can continue streaming.

Installation edits each native client configuration:

- Codex gets a `tokenmaxx` model provider whose `base_url` points to `/openai`, uses the
  Responses wire format, and still declares `requires_openai_auth = true`.
- Claude Code gets `ANTHROPIC_BASE_URL` pointing to `/anthropic`. TokenMaxx deliberately does not
  set `ANTHROPIC_AUTH_TOKEN`, because doing so changes Claude Code away from its claude.ai login
  path and can remove connectors and MCP behavior.
- Uninstall removes only TokenMaxx-managed configuration. A version stamp lets startup repair
  an already-installed route after configuration format changes.

Sources: [`config-install.ts` lines 78-178](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/config-install.ts#L78-L178),
[`proxy.ts` lines 513-530](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/proxy.ts#L513-L530).

### Request path

The manager reads the provider's active account every time `resolve(provider)` runs. The provider
adapter reads its credential from the Keychain-backed vault and refreshes an OAuth access token
when it is within two minutes of expiry.

The proxy then:

1. reads the complete request body;
2. removes hop-by-hop and length headers;
3. replaces provider authentication headers;
4. sends the request upstream;
5. forwards status and headers; and
6. streams the response body without waiting for completion.

Claude subscription requests go to `https://api.anthropic.com` with the selected OAuth bearer
token and OAuth beta header. The proxy removes any incoming `x-api-key`. Codex subscription
requests go to `https://chatgpt.com/backend-api/codex` with the selected bearer token and
`chatgpt-account-id`.

TokenMaxx also adapts third-party Responses requests for the ChatGPT Codex dialect. It lifts
system messages into `instructions` and removes `max_output_tokens`, while leaving developer
messages in `input` so Codex retains its tool contract.

Sources: [`manager.ts` lines 166-215](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/manager.ts#L166-L215),
[`claude.ts` lines 424-463](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/claude.ts#L424-L463),
[`codex.ts` lines 331-369](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/codex.ts#L331-L369),
[`proxy.ts` lines 347-503](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/proxy.ts#L347-L503).

### Switching and retries

TokenMaxx has no conversation pin. The selected account is the provider's current active account
when a request begins. A manual or automatic switch updates that pointer, so the next request from
every routed process uses the new account.

"Mid-turn" has two concrete meanings:

- An agent turn that makes several HTTP requests can change accounts between those requests.
- If an upstream request returns HTTP 429 before TokenMaxx forwards a body, TokenMaxx records the
  limit. Automation may switch the active account synchronously. The proxy resolves the account
  again and retries the same request once when resolution returns a different account.

A successful response already streaming stays on its original account. TokenMaxx does not replay
network failures. On HTTP 401 it refreshes once, resolves again, and retries once. This keeps
replay limited to explicit upstream rejections.

Sources: [`manager.ts` lines 436-462](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/manager.ts#L436-L462),
[`manager.ts` lines 540-646](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/manager.ts#L540-L646),
[`proxy.ts` lines 431-480](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/proxy.ts#L431-L480).

### Usage and secret handling

The proxy reads rate-limit headers from every response. It also observes SSE and JSON response
bodies to record input, output, cache-read, and cache-creation tokens. Its stream wrapper reports
Codex usage as soon as the terminal `response.completed` event arrives because Codex may close the
connection without waiting for EOF.

OAuth refreshes are serialized per credential reference. Refreshed credentials are written to
the macOS Keychain before the request path receives them. Large values are split into Keychain
chunks. TokenMaxx keeps account state and analytics in SQLite outside the credential vault.

Sources: [`proxy.ts` lines 34-172](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/proxy.ts#L34-L172),
[`vault.ts`](https://github.com/RubricLab/tokenmaxx/blob/6cd7172d828c6a0b8378168671a36e2013d7e179/src/vault.ts).

### Gaps worth noticing

The proxy binds only to loopback, but it does not authenticate local callers. Any local process
can send a request to port 8459 and receive traffic backed by the active subscription credential.
Loopback limits remote exposure; it does not establish caller identity.

The source has focused tests for dialect adaptation, usage parsing, listener identity, stream
cancellation, and configuration edits. At this commit, `proxy.test.ts` does not directly test the
full 401 or 429 replay paths. claudex should not copy that coverage gap.

## bb Account Pooler implementation

### Client routing and authentication

bb runs an authenticated HTTP hub at `/api/v1/plugins/account-pool/http`. It injects routing into
provider processes when bb launches them:

- Codex receives `CODEX_OPENAI_BASE_URL` and a `CODEX_POOL_AUTH_TOKEN` through in-memory app-server
  configuration.
- Claude Code receives `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`.

Each machine gets a distinct hub token. The hub accepts it through
`x-bb-account-pool-token` or a bearer header and resolves it to a bb host ID before routing. Token
rotation keeps the previous machine token valid for ten minutes. Provider processes receive no
provider refresh token.

Sources: bundled `accounts-and-routing.md`; embedded `src/hub.ts` lines 39-50 and 160-190;
[bb-account-pool.md](./bb-account-pool.md#architecture).

### Request parsing and account affinity

The hub reads the request body, then the provider adapter extracts a model family and conversation
affinity identifiers. Claude affinity comes from `metadata.user_id`; Codex affinity comes from
thread, session, parent-thread, turn-metadata, or prompt-cache identifiers.

Claude's `metadata.user_id` can encode the account UUID. bb rewrites that value for the selected
account before forwarding. TokenMaxx does not perform this account-body rewrite.

bb pins a conversation to one account while that account remains eligible. A child conversation
can inherit its parent's pin. Pins expire after 30 idle minutes, the hub retains at most 4,096,
and both pins and the provider cursor survive hub restarts.

Sources: embedded `src/request-body.ts`; embedded `src/hub.ts` lines 285-328 and 662-807;
bundled `accounts-and-routing.md`.

### Selection, pacing, and retries

Accounts are ordered by priority and insertion order. Selection removes disabled accounts,
accounts with permanent errors, accounts over shared quota, and accounts over the requested model
family's quota. New conversations start from the provider cursor. Pinned conversations prefer
their bound account.

For a short temporary 429, bb waits on the same account once, up to 20 seconds. Longer holds return
`Retry-After` to a pinned conversation while unpinned work can try another eligible account. Hard
quota rejection makes the account ineligible and permits selection to continue. A model-family
limit can detour one request without moving the conversation's main pin.

On HTTP 401, bb force-refreshes once and retries. Refresh operations are deduplicated per account.
Before marking authentication broken, bb rereads the stored secret and checks that the rejected
access token is still current. A late failure from an old token therefore cannot disable a newly
refreshed credential. Refresh failures use bounded backoff and treat timeouts, 408, 429, and 5xx
as transient.

The provider cursor and conversation binding advance only after an upstream success. Failed
attempts do not commit routing state.

Sources: embedded `src/hub.ts` lines 315-565, 610-660, and 662-940; embedded
`src/provider-adapter.ts`; bundled `accounts-and-routing.md`.

### Streaming and shutdown

bb forwards the upstream body as a `ReadableStream`. Client cancellation aborts the upstream
request. During shutdown the hub stops accepting requests, waits for in-flight work for a bounded
period, then aborts remaining upstream requests. SSE read failures become a final SSE error event
instead of an abruptly broken stream.

Source: embedded `src/hub.ts` lines 237-257 and the `fetchUpstream` and `clientResponse` methods.

## Comparison

| Concern | TokenMaxx | bb Account Pooler | Recommended claudex first version |
|---|---|---|---|
| Account choice | Current active account for every request | Conversation pin, provider cursor, model-family detours | Current active account for every request |
| Manual switch | Next request from all routed processes | Existing eligible pins stay put | Next request from all routed processes |
| Hard-limit handling | Resolve after 429, replay once if automation switched | Re-select by quota and affinity rules | Switch and replay once before body delivery |
| Temporary limit | Pass through unless rotation yields another account | One bounded inline wait; preserve pins | Pass through `Retry-After`; no hidden long wait |
| 401 | Force refresh and retry once | Token-aware force refresh and retry once | Copy bb's token-aware form |
| Caller authentication | Loopback binding only | Per-machine hub token | Random custom header in managed client configuration |
| Conversation identity | No pin or Claude account UUID rewrite | Persistent affinity plus Claude UUID rewrite | No pin initially; rewrite account-bound metadata |
| Usage | Response headers, API probes, streamed token accounting | Response headers, model-family quota, API probes | Keep existing usage polling; add response headers |
| Config integration | Persistent native config edits with uninstall and self-heal | Launch-time configuration controlled by bb | Managed native config block plus exact restore |
| Credential ownership | Proxy owns routed credentials | Hub owns pooled credentials | claudex owns every routed credential |

## Smallest responsible claudex proxy

The forwarding loop can stay small. The surrounding ownership and recovery rules cannot be
skipped. TokenMaxx's `proxy.ts` is 541 lines. Its proxy, configuration installer, manager, and two
provider adapters total about 3,700 lines before storage and UI. bb's hub, request parser, common
adapter, and two provider adapters total about 2,200 embedded source lines. These counts describe
scope, not quality.

A narrow first version should support only native Claude Code and Codex subscription clients. It
should not support arbitrary third-party harnesses or API-key accounts.

### Proposed modules

`AccountProxy` should be one deep module. Its public interface can stay at two lifecycle methods:

```swift
protocol AccountProxy: Sendable {
    func start() async throws -> ProxyEndpoint
    func stop() async
}
```

Its implementation owns listener security, request parsing, account selection, token refresh,
provider header and body adaptation, bounded replay, response streaming, quota observation,
cancellation, and shutdown drain. Callers should not coordinate those steps.

`CLIRoutingInstaller` should be a separate module because it changes persistent native client
configuration and has different failure and recovery rules:

```swift
protocol CLIRoutingInstaller: Sendable {
    func status(for provider: ProviderKind) throws -> RoutingStatus
    func install(_ endpoint: ProxyEndpoint, for provider: ProviderKind) throws
    func uninstall(for provider: ProviderKind) throws
}
```

The app composition root starts the proxy before usage polling and stops it during application
termination. Install and uninstall remain explicit user actions. Merely launching claudex must
not silently reroute native clients.

Claude Code supports `ANTHROPIC_CUSTOM_HEADERS`, so claudex can add an `X-Claudex-Token` header
without replacing the native claude.ai authorization header. Codex model providers support
literal `http_headers` and environment-backed `env_http_headers`. Because claudex does not launch
arbitrary terminal clients, a static local token must live in managed CLI configuration unless a
separate launcher exports it. The provider OAuth credentials can remain in the Keychain; the
local proxy token cannot remain Keychain-only and still be available to an independently launched
CLI.

Sources: [Claude Code LLM gateway configuration](https://code.claude.com/docs/en/llm-gateway-connect),
[Codex model provider configuration](https://github.com/openai/codex/blob/main/codex-rs/model-provider-info/src/lib.rs).

### Required behavior

1. Bind IPv4 loopback only. Reject every request without the claudex bearer token.
2. Buffer request bodies under an explicit size cap. Reject oversized bodies before upstream
   transmission.
3. Resolve the active account at request start and refresh under a per-account serialization lock.
4. Strip inbound provider auth and hop-by-hop headers. Inject only allowlisted provider headers.
5. Rewrite account-bound Claude metadata when present. Preserve Codex thread metadata.
6. Stream successful responses with backpressure. Never buffer a model response.
7. Record rate-limit response headers against the account that served the request.
8. On 401, refresh and retry once only when the rejected token still matches stored state.
9. On hard 429, switch and replay once only before any response bytes reach the client.
10. Never replay timeouts, connection failures, cancellations, or partially delivered responses.
11. Drain active requests on normal shutdown, then abort after a bounded deadline.
12. Install and restore CLI configuration transactionally. Detect foreign edits instead of
    overwriting them.

### Credential ownership change

Today claudex treats the native CLI's active credential as CLI-owned because a running process
holds its access token. Proxy mode reverses that rule. Every routed account becomes claudex-owned,
including the active account, because provider processes hold only a local routing credential.
The proxy can safely refresh and persist the selected provider credential before use.

Native file-switch mode and proxy mode should not share one implicit ownership policy. Keeping
both modes would require an explicit routing mode in account state and separate code paths in
`UsageReader` and `Switcher`. Replacing native switching entirely would make the model simpler,
but it would also mean Claude Code and Codex depend on claudex running whenever routing is
installed.

## Recommendation

Build proxy mode, but do not describe it as a tiny patch. Borrow TokenMaxx's request-level switch
semantics and narrow replay policy. Borrow bb's authenticated client route, account-aware Claude
body rewrite, token-aware refresh rejection handling, and commit-after-success rule.

Keep existing direct usage polling for the first version. Response headers can improve freshness,
but streamed token analytics and conversation affinity are separate features. Deferring them keeps
the first arrow segment focused on the original requirement: already-running routed sessions use
the newly selected account on their next provider request.

This document records research, not project intent. If proxy mode proceeds, update the project
design to allow changes to running CLI behavior and decide whether native file switching remains
as a fallback.
