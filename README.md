<img src="docs/images/icon.png" alt="" width="96" align="left">

# meterusage

A macOS menu-bar app that shows how much of your AI coding quota you have left.

<br clear="left">


Codex, OpenRouter, Antigravity, Grok, OpenCode Go, and Claude Code all leave usage signals
in different places. meterusage puts the useful numbers in your menu bar, with
Codex first and each provider independently hideable.

<img src="docs/images/menubar.png" alt="The meterusage menu-bar indicator showing 82%" height="24">

<img src="docs/images/popover.png" alt="The meterusage popover: service status first, then Codex quotas and local provider usage" width="330">

<sub>Screenshots are the real app in demo mode (`METERUSAGE_DEMO=1`) — every
number is synthetic, which is why the popover is badged **Demo**.</sub>

```sh
git clone https://github.com/pekth/meterusage.git
cd meterusage
./Scripts/make-app.sh && open dist/
```

Drag `MeterUsage.app` to Applications. That's the whole setup — no account to
connect and no key-entry screen. OpenRouter uses an existing
`OPENROUTER_API_KEY` or local OpenRouter key file when present.

## What you get

- **Live Codex quota** — general weekly limits, model-specific limits such as
  GPT-5.3-Codex-Spark, reset-credit expiry details, credit balance, and plan,
  read through the `codex` CLI you're already signed in to. Codex credits also
  show their approximate dollar equivalent at 2,500 credits = $100. The compact
  system-tray figure shows consumed usage; the Codex popover shows remaining
  headroom.
- **Live OpenRouter usage** — authenticated dollar spend, remaining account
  balance, and the optional daily/weekly/monthly key spending limit.
- **Live Grok quota** — the current allowance window (weekly on the X Premium
  tier, monthly on others) and the share already used, read from the same
  billing service the Grok CLI uses. The OIDC token is re-read from
  `~/.grok/auth.json` on every refresh, so a `grok` re-login never leaves the
  app reading a stale credential until relaunch.
- **Local provider usage** — Antigravity and Grok session/message counts, plus
  OpenCode Go token totals, message counts, and estimated local cost.
- **Claude activity *(optional)*** — tokens and estimated cost broken down per model, so
  every model you actually run is visibly accounted for. Computed from your
  own local transcripts.
- **Claude quota bars *(optional)*** — shown only when a local companion has
  already written a usage snapshot. When that file includes a `limits[]`
  array (session / weekly_all / weekly_scoped), meterusage surfaces those
  windows — including a Fable `weekly_scoped` bar. If the writer still emits
  only legacy `five_hour` / `seven_day` fields, you get those instead. No
  Fable bar appears until the writer actually emits `limits[]`; most
  statusline writers discard it, so [docs/COMPANION.md](docs/COMPANION.md)
  shows how to pass it through.
- **A 26-week heatmap** of daily usage.
- **Colour-coded usage and status** — quota headroom uses calm/warning/alert
  bands, while provider identity and written service-severity badges remain
  understandable without relying on colour alone.
- **Per-provider display settings** — hide any provider you do not use; Claude,
  Antigravity, and Grok start hidden, while Codex is the primary entry.
  Choices are saved locally and survive relaunches and app reinstalls.
- **Service health at the top** for Codex and Claude from their public status
  pages. Providers without a usable public status feed are omitted.

## How it works

meterusage reuses the CLI logins already on your machine. Codex and Claude
credentials stay in their own clients; OpenRouter uses an existing key only
for its aggregate usage and balance requests. It does **not** call Anthropic for quota and
does **not** read any Claude credentials.

| What | How | Needs network |
|---|---|---|
| Codex quota | Spawns `codex app-server --stdio` and calls `account/rateLimits/read` over JSON-RPC with the experimental rate-limit detail capability enabled. This includes general/model-specific windows and earned reset-credit expiry details. The subprocess authenticates itself. | Yes, by the CLI |
| OpenRouter quota | Calls the documented `/api/v1/key` and `/api/v1/credits` endpoints with an existing `OPENROUTER_API_KEY` or supported local key file. Only aggregate usage, account balance, limit, and reset cadence are retained. | Yes |
| Grok quota | Calls the billing endpoint the Grok CLI itself uses (`cli-chat-proxy.grok.com/v1/billing`), sending only the OIDC bearer token re-read from `~/.grok/auth.json` on each refresh. Only the allowance percent, period type, and reset time are retained; no prompts or model requests are sent. | Yes |
| Claude activity | Streams `~/.claude/projects/**/*.jsonl` and sums usage fields. | No |
| Claude quota *(optional)* | Reads an on-disk usage JSON if a companion already wrote one (e.g. `~/.claude/claudewatch-usage.json` or `~/.claude/meterusage-usage.json`). Parses legacy windows and, when present, `limits[]` (including Fable `weekly_scoped`). Does not fetch Anthropic quota. | No |
| Antigravity usage | Reads session/message counts from agy's `history.jsonl`, preferring the native `~/.gemini/antigravity-cli/` location and falling back to the `antigravity-config` container volume when agy is containerised, then the legacy `~/.claude/claudewatch-agy-cache.json` snapshot. Token totals are left unknown. | No |
| Grok usage | Reads session summaries under `~/.grok/sessions/**/summary.json`; only session dates and message counts are used. | No |
| OpenCode Go usage | Runs the local `opencode db --format json` command with a read-only query over numeric session usage fields and timestamps. Message bodies are never queried. | No |
| Codex service health | Public OpenAI Statuspage JSON, filtered to Codex, CLI, and login components. | Yes |
| Claude service health | Public Claude Statuspage JSON, filtered to Claude/API components. | Yes |

### Why there's no "Sign in with Claude" button

Anthropic publishes no supported API for Claude subscription quota — the only
sanctioned channel is Claude Code's own statusline. A third-party app *could*
lift Claude Code's OAuth token out of the Keychain and call an undocumented
endpoint using Anthropic's first-party client id. meterusage deliberately
doesn't, because that impersonates the official client and can break without
notice.

So the honest split: **Codex, OpenRouter, and Grok quotas are live from the
cloud; Antigravity, Grok, OpenCode Go, and Claude activity are computed from
local data; Claude quota bars are optional and file-driven.** meterusage never
talks
to Anthropic for quota. OpenRouter's existing key is used only for its
aggregate account endpoints and is never displayed or logged. If a local
companion writes a usage snapshot, its counts light up from that file alone.
When the Claude snapshot includes `limits[]`, those windows — including Fable —
take precedence over legacy keys; display depends on what the writer actually
emits.

See [docs/PRIVACY.md](docs/PRIVACY.md) for the full boundary and how each claim
is enforced by tests and hooks rather than promised in prose.

## Requirements

- macOS 13 Ventura or later
- Xcode command-line tools (`xcode-select --install`)
- Optional: [`codex`](https://github.com/openai/codex) CLI, signed in, for live
  Codex quota
- Optional: `OPENROUTER_API_KEY` or a local OpenRouter key file, for live
  OpenRouter usage
- Optional: [`opencode`](https://opencode.ai/), for OpenCode Go local usage
- Optional: Grok CLI (signed in), for Grok session history and the live
  allowance window
- Optional: the Antigravity (agy) CLI for Antigravity counts; containerised agy installs also need Docker or Podman
- Optional: Claude Code, for local activity data

Missing any provider is fine. Its row shows a calm empty state, and Settings
can hide providers that are not installed or not relevant to you.

## Build from source

```sh
swift build            # debug binary
swift test             # unit tests
./Scripts/make-app.sh  # assembles dist/MeterUsage.app, ad-hoc signed
./Scripts/make-icon.sh # regenerates the app icon (only when the design changes)
```

The icon is generated rather than hand-drawn: `Scripts/make-icon.swift` renders
it from the same geometry the menu-bar glyph uses, so the two stay the same
mark. Both the 1024×1024 master and the `.icns` are committed, so a fresh clone
builds a complete bundle without running the generator.

No third-party dependencies. No Apple Developer account needed — the app is
ad-hoc signed, so macOS will ask you to confirm the first launch via
**System Settings → Privacy & Security**.

### Demo mode

Run the real UI against synthetic data — useful for screenshots, or for
poking at the app without either CLI installed:

```sh
METERUSAGE_DEMO=1 swift run meterusage
```

A **Demo** badge appears in the popover header so fake numbers are never
mistaken for real ones. See [docs/DEMO.md](docs/DEMO.md).

## Cost figures are estimates

Costs are derived locally from token counts against a rate table in
[`Pricing.swift`](Sources/MeterUsage/Services/Pricing.swift). Published rates
change and the table drifts. Treat every number here as awareness, not billing
truth — your provider's dashboard is the only source of record.

## Contributing

Issues and PRs welcome. Two things to know before you open one:

- A pre-commit hook scans staged diffs for tokens, JWTs, private keys, and
  absolute `/Users/<name>/` paths, and fails closed. Enable it with
  `git config core.hooksPath .githooks`.
- Test fixtures must be synthetic. Use `testuser` or `example` for paths and
  invented values everywhere else — never paste a real captured payload.

If you're reporting something that involves a live credential, describe its
shape and location. Don't paste it.

## Not affiliated

meterusage is an independent open-source project. It is not affiliated with,
endorsed by, or supported by Anthropic or OpenAI. "Claude" and "Codex" are
their respective owners' marks, used here only to say what the tool reads.

## License

[MIT](LICENSE)
