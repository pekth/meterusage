# Privacy & security design

meterusage reads AI coding-assistant usage from your own machine. That means it runs in close proximity to live credentials, so its boundaries are deliberate and narrow. This document states exactly what it does and does not do, and how each claim is enforced rather than merely promised.

---

### ⚡ TL;DR

* 🛡️ **Zero Credential Exposure**: Never touches Claude or Codex authentication tokens, passwords, or their macOS Keychain items. OpenRouter uses an existing environment variable/local key for aggregate balances in memory. OpenAI and Anthropic API monitoring save explicitly entered keys in MeterUsage-owned macOS Keychain items. Explicit launcher environment keys stay in memory.
* 🚫 **No Prompts, Code, or Message Inspection**: Only reads numeric token tallies and event timestamps from local CLI stores. Message bodies, prompts, tool inputs/outputs, and workspace paths are never decoded or transmitted.
* 🧼 **Sanitized at the Boundary**: User paths (`/Users/<username>/`), terminal IDs, hostnames, and emails are structurally dropped before reaching memory or the UI.
* 🔒 **Strict Network Isolation**: Zero analytics, telemetry, crash reporting, or remote tracking servers. Only connects directly to documented usage endpoints or public status feeds.
* 🧪 **Enforced by Automated Tests**: Privacy guarantees are asserted by unit tests and locked with a pre-commit git hook that fails closed on credentials or paths.

---

## What meterusage never does

- **Never reads Codex or Claude credentials.** It does not open `~/.codex/auth.json`, `~/.claude/.credentials.json`, or another app's macOS Keychain items. OpenRouter, OpenAI API, and Anthropic API monitoring use separately configured keys. OpenAI and Anthropic accept masked key entry in Settings or load explicitly supplied `OPENAI_ADMIN_KEY` and `ANTHROPIC_ADMIN_KEY` values at launch. Keys entered in Settings are saved in MeterUsage-owned Keychain items. The app never displays keys as plain text or includes them in logs, diagnostics, preferences, or plaintext files. Network reads require an enabled provider or an explicit connection test. When configured, OpenRouter reads an existing `OPENROUTER_API_KEY` or supported local key file in memory only to call OpenRouter's aggregate usage and balance endpoints; it never displays, logs, or stores that key.
- **API key entry is explicit and persistent.** OpenAI and Anthropic connections use a masked field in Settings. The app clears unfinished entry when Settings closes and never fills the field with a saved key. Native Security framework calls store one generic-password item per provider under the stable service `com.meterusage.api-keys`, with accounts `openAI` and `anthropic`. These items use macOS's default application access control and do not sync through iCloud. No other app's items are queried. Disconnect deletes the saved item before clearing the active key and displayed reading. A denied save or delete reports an error and preserves the current connection. A denied read reports an error with a retry control, without falling back to a different environment credential. Existing requests may finish after disconnect or replacement, but their results are discarded. Never include keys in screenshots, support messages, or diagnostics.
- **Updates retain Keychain items.** Ad-hoc signed builds can require macOS access approval after rebuilding because their signing identity changes. MeterUsage does not weaken Keychain access controls to suppress that prompt. Saved keys take precedence over launcher variables. Environment keys are not persisted automatically, and Disconnect suppresses them until the next launch. Demo mode and normal unit tests never open the production key store.
- **Never uses undocumented provider APIs.** It does not reuse another application's OAuth client id, and it does not call private endpoints.
- **Never sends prompts or code anywhere.** Provider requests are limited to the documented Codex/OpenRouter/OpenAI/Anthropic usage calls and public status feeds. There is no telemetry, analytics, crash reporting, or update ping; it has no server.
- **Never reads your prompts or code.** It parses only usage and metadata fields from local transcripts. Message content is skipped, not stored.

## Where the numbers actually come from

| Source | Mechanism | Network? |
|---|---|---|
| Codex quota | Spawns `codex app-server --stdio` and makes a JSON-RPC `account/rateLimits/read` call with the CLI's experimental rate-limit detail capability enabled. That returns general/model-specific windows and earned reset-credit expiry details when the account provides them. This is a supported CLI surface; the subprocess authenticates itself using your existing `codex login`. meterusage never sees the token. | Yes, by the CLI subprocess |
| Second Codex account | The same subprocess mechanism with `CODEX_HOME` pointed at the alternate account's config directory (`METERUSAGE_CODEX_ALT_HOME` or a stored default). The child authenticates itself from that home; meterusage still never opens any auth file, and only spawns the subprocess when that directory exists. | Yes, by the CLI subprocess |
| OpenRouter quota | Calls the documented `/api/v1/key` and `/api/v1/credits` endpoints with an existing API key and retains only aggregate dollar usage, account balance, optional limit, and reset cadence. It does not send prompts or model requests. | Yes |
| OpenAI API usage and costs | GET requests to `/v1/organization/usage/completions` and `/v1/organization/costs` on `api.openai.com` with an explicitly configured organization Admin key. Only numeric usage, USD amounts, and bucket timestamps are decoded. Account, project, key, and user identifiers are ignored. An ephemeral session rejects redirects and retains no disk cache or cookies. | Yes |
| Anthropic API usage and costs | GET requests to `/v1/organizations/usage_report/messages` and `/v1/organizations/cost_report` on `api.anthropic.com` with an explicitly configured organization Admin key. Only token counts, USD amounts, and bucket timestamps are decoded. Workspace, key, model, and description fields are ignored. The same ephemeral session rejects redirects and retains no disk cache or cookies. | Yes |
| OpenRouter activity | Calls `https://openrouter.ai/api/v1/activity` with an OpenRouter Management Key (`OPENROUTER_MANAGEMENT_KEY` or `~/.cli-proxy-api/openrouter-management-key`) to fetch aggregate daily token volume (input, output, reasoning) over the last 30 days. | Yes |
| Grok quota | Calls the billing endpoint the Grok CLI itself uses (`cli-chat-proxy.grok.com/v1/billing`). The OIDC bearer token is re-read from `~/.grok/auth.json` on every refresh — never cached from launch — and is sent only in the request Authorization header. Only the allowance percent, period type, and reset time are retained; no prompts or model requests are sent. | Yes |
| Claude activity | Streams your own transcript files under `~/.claude/projects/`, summing token-usage fields. | No |
| Second Claude account | The same local-only mechanisms pointed at the alternate account's config directory (`METERUSAGE_CLAUDE_ALT_CONFIG` or a stored default): transcripts under `<dir>/projects/`, the plan tier via the same narrow decode of `<dir>/.claude.json`, and a companion quota snapshot inside that directory. Nothing is read outside that directory for the second account — in particular, the primary account's `.claude.json` is never consulted for it, because a wrong-but-plausible plan badge is worse than none. | No |
| Codex activity | Counts sessions per day from `~/.codex/sessions/**/*.jsonl`, reading only the start timestamp on each rollout's first event (falling back to the file's modification date). Session payloads are never opened. | No |
| Claude quota *(optional)* | Read-only parse of a local usage snapshot if a companion already wrote one (`~/.claude/claudewatch-usage.json` or `~/.claude/meterusage-usage.json`). Supports legacy `five_hour` / `seven_day` / `weekly` shapes and, when present, a `limits[]` array (session / weekly_all / weekly_scoped, including Fable). meterusage does **not** fetch Anthropic quota and does **not** read Claude credentials. Absent by default and never requested. | No |
| Antigravity quota | Selects a healthy available Docker or Podman runtime, then runs `agy -p "/usage"` inside the same container image and volumes the user's agy wrapper uses. If no runtime is healthy, it may start only an existing `podman-machine-default` after inspecting that machine. It never creates a machine. It reads only each row's model group, window label, percent remaining, and reset timestamp. No prompt or model request is sent; the CLI's own backend quota refresh runs inside the container. No credential leaves the volume. | Yes, by the CLI |
| Antigravity usage | Uses the same bounded runtime selection and existing-default-machine recovery as quota. It decodes only numeric token-usage fields and turn timestamps from agy's per-conversation SQLite stores under `~/.gemini/antigravity-cli/conversations/`, preferring the native location and falling back to the `antigravity-config` container volume when agy is containerised. Prompt text, tool payloads, workspace paths, and identifiers inside the stores are never decoded. Older installs without conversation stores fall back to `history.jsonl`, where only the `conversationId` and `timestamp` fields of each line are read and token totals remain unknown. | No |
| Grok usage | Reads only date and message-count fields from `~/.grok/sessions/**/summary.json`. It does not open chat-history content or context-window signal files. | No |
| OpenCode Go usage | Invokes the local `opencode db --format json` command with a read-only SQL query selecting numeric token/cost fields, message counts, and timestamps from `session`. It never selects message bodies, prompts, tool arguments, or paths. | No |
| Codex service health | Public, unauthenticated Statuspage JSON at `status.openai.com`, filtered to Codex, CLI, and login components. | Yes |
| Claude service health | Public, unauthenticated Statuspage JSON at `status.claude.com`, filtered to Claude/API components. | Yes |

### Optional Claude quota file (including Fable)

Claude quota bars are a pure bonus. A companion tool must already have written a small JSON snapshot to disk; meterusage never prompts for it and never creates it. Implementation lives in `Sources/MeterUsage/Services/OptionalQuotaFileSource.swift`.

Honest limits of that path:

- **No direct Anthropic quota fetch.** meterusage does not call an undocumented subscription-usage endpoint and does not open `~/.claude/.credentials.json` or Claude Keychain items for this purpose.
- **`limits[]` is parsed when present.** When the snapshot includes a non-empty `limits` array, those windows fully replace legacy 5-hour / 7-day / weekly keys so the same window is not drawn twice. A `weekly_scoped` entry with `scope.model.display_name == "Fable"` can render as a real Fable plan-allowance bar.
- **Fable display depends on the writer.** The parser can handle `limits[]`, but the bar only appears if the local companion emits that shape. Current claudewatch JSON may still contain only legacy fields (`five_hour`, `seven_day`, `extra_usage`); until a writer includes `limits[]` (or an equivalent weekly breakdown), no Fable quota bar is shown.
- **Credits stay orthogonal.** Extra-usage / credit balance is separate from plan windows and is not how Fable is labelled.

### Why there is no "sign in with Claude" button

Anthropic publishes no supported API for Claude subscription quota. The only sanctioned channel is Claude Code's own statusline. A third-party app could reach the same numbers by lifting Claude Code's OAuth token out of the Keychain and calling an undocumented endpoint with Anthropic's first-party client id — meterusage deliberately does not, because that impersonates the official client and can break without notice.

The consequence is honest rather than hidden: Codex shows real live quota, including Codex's 2,500-credits-to-$100 display conversion; OpenRouter shows provider-reported dollar usage and remaining account balance, local usage rows show only the fields each provider can prove, and Claude quota bars appear only if a usage file is already present — and only with the windows that file actually contains. Nothing is silently estimated and labelled as authoritative.

## Cost figures

OpenAI API spend is the USD amount reported by the organization Costs API, including adjustments. It is separate from local estimates and can lag the billing dashboard. Completion token totals do not represent every OpenAI product.

Anthropic API spend is the organization Cost API amount converted from decimal cents to USD, including adjustments. The endpoint excludes Priority Tier charges, which the card discloses. Tokens cover the Messages API, including cache reads and cache creation. Reporting can lag.

Local cost estimates use token counts and a rate table in `Sources/MeterUsage/Services/Pricing.swift`. That table covers Claude list rates and OpenAI/Codex Standard list rates (the GPT-6 and GPT-5.6 families and `gpt-5.3-codex`); Codex sessions are priced using the model recorded in the local rollout, and cache writes are free because Codex does not charge for them. Published rates change, and the table can drift. Treat locally estimated costs as approximations for awareness, never as billing figures. Your provider's dashboard is the only source of truth for what you owe.

## What leaves your machine

Outbound requests or subprocess-backed provider checks, all of which you can verify in the source:

1. The `codex` CLI subprocess contacts OpenAI's backend to read your rate limits. This is the same call the CLI makes for itself.
2. meterusage fetches `https://status.openai.com/api/v2/components.json`, a public status feed. No credentials, no identifiers, no usage data is sent.
3. meterusage fetches `https://status.claude.com/api/v2/components.json`, a public status feed.
4. meterusage fetches OpenRouter's documented `/api/v1/key` and `/api/v1/credits` endpoints with the existing key, retaining only aggregate dollar usage and balance fields. When an OpenRouter Management Key is configured, it queries `/api/v1/activity` for 30-day token volumes.
5. meterusage fetches Grok's billing endpoint (`cli-chat-proxy.grok.com/v1/billing`) with the OIDC bearer token re-read from `~/.grok/auth.json`, retaining only the allowance percent, period type, and reset time. No prompts or model requests are sent.
6. At most once a day, meterusage fetches `https://api.github.com/repos/pekth/meterusage/releases/latest` to check for a newer release. The request is unauthenticated, carries no body, no identifier, and no usage data — the server sees only your IP and a User-Agent string, the same as any web visit. The response's version tag is compared to the running build; a failed or rate-limited check is silently ignored. This check can be switched off in Settings → General → "Check for updates". When you click Install, the release zip is downloaded from the same release's asset URL and its SHA-256 is verified against the digest GitHub publishes with the asset; a missing or mismatched digest aborts the install.
7. When OpenAI API monitoring is enabled, meterusage reads organization usage and costs directly from `https://api.openai.com/v1/organization/usage/completions` and `https://api.openai.com/v1/organization/costs`. Its Admin key stays in memory and is sent only in the Authorization header. Requests include date bounds, daily bucket width, page size, and an opaque pagination cursor. No model request is made.

8. When Anthropic API monitoring is enabled, meterusage reads organization usage and costs directly from `https://api.anthropic.com/v1/organizations/usage_report/messages` and `https://api.anthropic.com/v1/organizations/cost_report`. Its Admin key stays in memory and is sent only in the `x-api-key` header. Requests include UTC date bounds, daily bucket width, page size, and an opaque pagination cursor. No model request is made.

The local usage commands and file reads above add no outbound request. There is no analytics endpoint to disable because there is none.

## The one file we read that also contains personal data

To show which plan you're on (Pro, Max 5×, Max 20×), meterusage reads a single value from `~/.claude.json`: `oauthAccount.organizationRateLimitTier`, with `seatTier` and `userRateLimitTier` as fallbacks.

That file also contains your email address, display name, account UUID, organization UUID, and organization name. None of them are read — and that is structural, not a promise:

`ClaudePlanSource` decodes with a `Decodable` struct declaring **only** the three tier keys. Swift's `Decodable` silently drops every undeclared key, so the identifying fields are never materialised into a Swift value at all. There is no dictionary decode, no `[String: Any]`, and no code path that could read them. Tests feed a fixture containing an obviously-identifying email and org name, then assert neither can appear in the produced value.

If you extend that struct, you break this guarantee. The file says so in a header comment for exactly that reason.

## Identifying data is stripped at the boundary

Provider payloads and local transcripts both carry material that should not reach the screen, a cache, or a screenshot. `Privacy` in `Sources/MeterUsage/Services/DataSource.swift` is the single chokepoint:

- Absolute paths contain your OS username, so project directories are reduced to their final component before entering the model layer.
- Session UUIDs are replaced with opaque, non-reversible ids used only for list diffing.
- The Codex RPC handshake returns a machine `installationId`, a hostname, and a user-agent string identifying your terminal. All three are dropped on read.

Second-account slots follow the same boundary with one addition: a slot is identified by **position only** ("Codex second account", digit "2"). No email, account id, org name, or any provider-issued identity is read to name it — the tools keep multiple accounts in separate config directories, and meterusage keys the slot on the directory you configured, nothing inside it. The directory path is rendered only back to you in Settings, reduced to `~` form, and never enters caches, diagnostics, or the JSON report.

Because these conversions happen in the source layer rather than the view layer, there is no code path that renders the raw value.

The supplemental sources apply the same boundary by construction: Antigravity reduces its conversation stores to numeric token fields and turn timestamps, Grok reduces its stores to counts and dates, and OpenCode Go asks its database command for numeric usage columns only. Provider names and metric colours are rendered alongside written labels, so colour is never the only meaningful signal.

## How this is enforced

Stated policy is not a control. These are:

- **Tests** assert that no `SessionSummary` contains a path separator or the substring `Users`, and that parsed quota carries no hostname or installation id.
- **A pre-commit hook** (`.githooks/pre-commit`) scans staged diffs for token prefixes, JWTs, private-key blocks, `/Users/<name>/` paths, Apple team ids, and credential-shaped filenames. It fails closed.
- **`.gitignore`** refuses credential-shaped files by name as a second layer.
- **Test fixtures are synthetic.** Captured live payloads are excluded by `.gitignore`; fixtures are hand-written with invented values.

## Reporting a problem

If you find a case where meterusage exposes something it should not, please open an issue. If it involves a live credential, do not paste it into the issue — describe the shape and location instead.
