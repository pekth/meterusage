# Privacy & security design

meterusage reads AI coding-assistant usage from your own machine. That means it
runs in close proximity to live credentials, so its boundaries are deliberate
and narrow. This document states exactly what it does and does not do, and how
each claim is enforced rather than merely promised.

## What meterusage never does

- **Never reads your credentials.** It does not open `~/.codex/auth.json`,
  `~/.claude/.credentials.json`, or any macOS Keychain item. It holds no token
  of any kind, at rest or in memory.
- **Never asks you to paste a key.** There is no login screen, no token field,
  and no account connection flow.
- **Never uses undocumented provider APIs.** It does not reuse another
  application's OAuth client id, and it does not call private endpoints.
- **Never sends your data anywhere.** No telemetry, no analytics, no crash
  reporting, no update pings. It has no server.
- **Never reads your prompts or code.** It parses only usage and metadata
  fields from local transcripts. Message content is skipped, not stored.

## Where the numbers actually come from

| Source | Mechanism | Network? |
|---|---|---|
| Codex quota | Spawns `codex app-server --stdio` and makes a JSON-RPC `account/rateLimits/read` call. This is a supported CLI surface; the subprocess authenticates itself using your existing `codex login`. meterusage never sees the token. | Yes, by the CLI subprocess |
| Claude activity | Streams your own transcript files under `~/.claude/projects/`, summing token-usage fields. | No |
| Claude quota *(optional)* | If a usage JSON file happens to exist, its percentages are displayed. Absent by default and never requested. | No |
| Service health | Public, unauthenticated Statuspage JSON at `status.claude.com`. | Yes |

### Why there is no "sign in with Claude" button

Anthropic publishes no supported API for Claude subscription quota. The only
sanctioned channel is Claude Code's own statusline. A third-party app could
reach the same numbers by lifting Claude Code's OAuth token out of the Keychain
and calling an undocumented endpoint with Anthropic's first-party client id —
meterusage deliberately does not, because that impersonates the official client
and can break without notice.

The consequence is honest rather than hidden: Codex shows real live quota,
Claude shows locally-computed activity, and Claude quota bars appear only if a
usage file is already present. Nothing is silently estimated and labelled as
authoritative.

## Cost figures are estimates

Costs are computed locally from token counts against a rate table in
`Sources/MeterUsage/Services/Pricing.swift`. Published rates change, and the
table can drift. Treat every cost in this app as an approximation for
awareness — never as a billing figure. Your provider's dashboard is the only
source of truth for what you owe.

## What leaves your machine

Two outbound requests, both of which you can verify in the source:

1. The `codex` CLI subprocess contacts OpenAI's backend to read your rate
   limits. This is the same call the CLI makes for itself.
2. meterusage fetches `https://status.claude.com/api/v2/components.json`, a
   public status feed. No credentials, no identifiers, no usage data is sent.

Nothing else. There is no analytics endpoint to disable because there is none.

## The one file we read that also contains personal data

To show which plan you're on (Pro, Max 5×, Max 20×), meterusage reads a single
value from `~/.claude.json`: `oauthAccount.organizationRateLimitTier`, with
`seatTier` and `userRateLimitTier` as fallbacks.

That file also contains your email address, display name, account UUID,
organization UUID, and organization name. None of them are read — and that is
structural, not a promise:

`ClaudePlanSource` decodes with a `Decodable` struct declaring **only** the
three tier keys. Swift's `Decodable` silently drops every undeclared key, so
the identifying fields are never materialised into a Swift value at all. There
is no dictionary decode, no `[String: Any]`, and no code path that could read
them. Tests feed a fixture containing an obviously-identifying email and org
name, then assert neither can appear in the produced value.

If you extend that struct, you break this guarantee. The file says so in a
header comment for exactly that reason.

## Identifying data is stripped at the boundary

Provider payloads and local transcripts both carry material that should not
reach the screen, a cache, or a screenshot. `Privacy` in
`Sources/MeterUsage/Services/DataSource.swift` is the single chokepoint:

- Absolute paths contain your OS username, so project directories are reduced
  to their final component before entering the model layer.
- Session UUIDs are replaced with opaque, non-reversible ids used only for list
  diffing.
- The Codex RPC handshake returns a machine `installationId`, a hostname, and a
  user-agent string identifying your terminal. All three are dropped on read.

Because these conversions happen in the source layer rather than the view
layer, there is no code path that renders the raw value.

## How this is enforced

Stated policy is not a control. These are:

- **Tests** assert that no `SessionSummary` contains a path separator or the
  substring `Users`, and that parsed quota carries no hostname or installation
  id.
- **A pre-commit hook** (`.githooks/pre-commit`) scans staged diffs for token
  prefixes, JWTs, private-key blocks, `/Users/<name>/` paths, Apple team ids,
  and credential-shaped filenames. It fails closed.
- **`.gitignore`** refuses credential-shaped files by name as a second layer.
- **Test fixtures are synthetic.** Captured live payloads are excluded by
  `.gitignore`; fixtures are hand-written with invented values.

## Reporting a problem

If you find a case where meterusage exposes something it should not, please
open an issue. If it involves a live credential, do not paste it into the
issue — describe the shape and location instead.
