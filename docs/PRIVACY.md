# Privacy & security design

meterusage reads AI coding-assistant usage from your own machine. That means it
runs in close proximity to live credentials, so its boundaries are deliberate
and narrow. This document states exactly what it does and does not do, and how
each claim is enforced rather than merely promised.

## What meterusage never does

- **Never reads Codex or Claude credentials.** It does not open
  `~/.codex/auth.json`, `~/.claude/.credentials.json`, or any macOS Keychain
  item. OpenRouter is the explicit exception: when configured, it reads an
  existing `OPENROUTER_API_KEY` or supported local key file in memory only to
  call OpenRouter's aggregate usage and balance endpoints; it never displays, logs, or
  stores that key.
- **Never asks you to paste a key.** There is no login screen, no token field,
  and no account connection flow.
- **Never uses undocumented provider APIs.** It does not reuse another
  application's OAuth client id, and it does not call private endpoints.
- **Never sends prompts or code anywhere.** Provider requests are limited to
  the documented Codex/OpenRouter usage calls and public status feeds. There
  is no telemetry, analytics, crash reporting, or update ping; it has no
  server.
- **Never reads your prompts or code.** It parses only usage and metadata
  fields from local transcripts. Message content is skipped, not stored.

## Where the numbers actually come from

| Source | Mechanism | Network? |
|---|---|---|
| Codex quota | Spawns `codex app-server --stdio` and makes a JSON-RPC `account/rateLimits/read` call with the CLI's experimental rate-limit detail capability enabled. That returns general/model-specific windows and earned reset-credit expiry details when the account provides them. This is a supported CLI surface; the subprocess authenticates itself using your existing `codex login`. meterusage never sees the token. | Yes, by the CLI subprocess |
| OpenRouter quota | Calls the documented `/api/v1/key` and `/api/v1/credits` endpoints with an existing API key and retains only aggregate dollar usage, account balance, optional limit, and reset cadence. It does not send prompts or model requests. | Yes |
| Grok quota | Calls the billing endpoint the Grok CLI itself uses (`cli-chat-proxy.grok.com/v1/billing`). The OIDC bearer token is re-read from `~/.grok/auth.json` on every refresh — never cached from launch — and is sent only in the request Authorization header. Only the allowance percent, period type, and reset time are retained; no prompts or model requests are sent. | Yes |
| Claude activity | Streams your own transcript files under `~/.claude/projects/`, summing token-usage fields. | No |
| Codex activity | Counts sessions per day from `~/.codex/sessions/**/*.jsonl`, reading only the start timestamp on each rollout's first event (falling back to the file's modification date). Session payloads are never opened. | No |
| Claude quota *(optional)* | Read-only parse of a local usage snapshot if a companion already wrote one (`~/.claude/claudewatch-usage.json` or `~/.claude/meterusage-usage.json`). Supports legacy `five_hour` / `seven_day` / `weekly` shapes and, when present, a `limits[]` array (session / weekly_all / weekly_scoped, including Fable). meterusage does **not** fetch Anthropic quota and does **not** read Claude credentials. Absent by default and never requested. | No |
| Antigravity usage | Reads only conversation-id grouping and timestamps from agy's `history.jsonl`, preferring the native `~/.gemini/antigravity-cli/` location and falling back to the `antigravity-config` container volume when agy is containerised. Prompt text and workspace paths in the history lines are never read. No prompt, code, or token fields are needed; token totals remain unknown. | No |
| Grok usage | Reads only date and message-count fields from `~/.grok/sessions/**/summary.json`. It does not open chat-history content or context-window signal files. | No |
| OpenCode Go usage | Invokes the local `opencode db --format json` command with a read-only SQL query selecting numeric token/cost fields, message counts, and timestamps from `session`. It never selects message bodies, prompts, tool arguments, or paths. | No |
| Codex service health | Public, unauthenticated Statuspage JSON at `status.openai.com`, filtered to Codex, CLI, and login components. | Yes |
| Claude service health | Public, unauthenticated Statuspage JSON at `status.claude.com`, filtered to Claude/API components. | Yes |

### Optional Claude quota file (including Fable)

Claude quota bars are a pure bonus. A companion tool must already have written
a small JSON snapshot to disk; meterusage never prompts for it and never
creates it. Implementation lives in
`Sources/MeterUsage/Services/OptionalQuotaFileSource.swift`.

Honest limits of that path:

- **No direct Anthropic quota fetch.** meterusage does not call the usage API
  and does not open `~/.claude/.credentials.json` or Keychain items for this
  purpose (or any other).
- **`limits[]` is parsed when present.** When the snapshot includes a non-empty
  `limits` array, those windows fully replace legacy 5-hour / 7-day / weekly
  keys so the same window is not drawn twice. A `weekly_scoped` entry with
  `scope.model.display_name == "Fable"` can render as a real Fable plan-
  allowance bar.
- **Fable display depends on the writer.** The parser can handle `limits[]`,
  but the bar only appears if the local companion emits that shape. Current
  claudewatch JSON may still contain only legacy fields (`five_hour`,
  `seven_day`, `extra_usage`); until a writer includes `limits[]` (or an
  equivalent weekly breakdown), no Fable quota bar is shown.
- **Credits stay orthogonal.** Extra-usage / credit balance is separate from
  plan windows and is not how Fable is labelled.

### Why there is no "sign in with Claude" button

Anthropic publishes no supported API for Claude subscription quota. The only
sanctioned channel is Claude Code's own statusline. A third-party app could
reach the same numbers by lifting Claude Code's OAuth token out of the Keychain
and calling an undocumented endpoint with Anthropic's first-party client id —
meterusage deliberately does not, because that impersonates the official client
and can break without notice.

The consequence is honest rather than hidden: Codex shows real live quota,
including Codex's 2,500-credits-to-$100 display conversion;
OpenRouter shows provider-reported dollar usage and remaining account balance,
local usage rows show only the
fields each provider can prove, and Claude quota bars appear only if a usage
file is already present — and only with the windows that file actually
contains. Nothing is silently estimated and labelled as authoritative.

## Cost figures are estimates

Costs are computed locally from token counts against a rate table in
`Sources/MeterUsage/Services/Pricing.swift`. Published rates change, and the
table can drift. Treat every cost in this app as an approximation for
awareness — never as a billing figure. Your provider's dashboard is the only
source of truth for what you owe.

## What leaves your machine

Six outbound requests or subprocess-backed provider checks, all of which you
can verify in the source:

1. The `codex` CLI subprocess contacts OpenAI's backend to read your rate
   limits. This is the same call the CLI makes for itself.
2. meterusage fetches `https://status.openai.com/api/v2/components.json`, a
   public status feed. No credentials, no identifiers, no usage data is sent.
3. meterusage fetches `https://status.claude.com/api/v2/components.json`, a
   public status feed.
4. meterusage fetches OpenRouter's documented `/api/v1/key` and
   `/api/v1/credits` endpoints with the existing key, retaining only aggregate
   dollar usage and balance fields.
5. meterusage fetches Grok's billing endpoint
   (`cli-chat-proxy.grok.com/v1/billing`) with the OIDC bearer token re-read
   from `~/.grok/auth.json`, retaining only the allowance percent, period
   type, and reset time. No prompts or model requests are sent.
6. At most once a day, meterusage fetches
   `https://api.github.com/repos/pekth/meterusage/releases/latest` to check
   for a newer release. The request is unauthenticated, carries no body, no
   identifier, and no usage data — the server sees only your IP and a
   User-Agent string, the same as any web visit. The response's version tag
   is compared to the running build; a failed or rate-limited check is
   silently ignored.

The local usage commands and file reads above add no outbound request. There is
no analytics endpoint to disable because there is none.

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

The supplemental sources apply the same boundary by construction: Antigravity
and Grok reduce their stores to counts and dates, while OpenCode Go asks its
database command for numeric usage columns only. Provider names and metric
colours are rendered alongside written labels, so colour is never the only
meaningful signal.

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
