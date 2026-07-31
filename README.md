# meterusage

A macOS menu-bar app that shows how much of your AI coding quota you have left.

<!-- SCREENSHOT:hero -->

Claude Code and Codex both burn through rate limits you can't see until you hit
them. meterusage puts the number in your menu bar.

```sh
git clone https://github.com/pekth/meterusage.git
cd meterusage
./Scripts/make-app.sh && open dist/
```

Drag `MeterUsage.app` to Applications. That's the whole setup — no account to
connect, no API key to paste, no statusline to install.

## What you get

<!-- SCREENSHOT:popover -->

- **Live Codex quota** — 5-hour and weekly windows, credit balance, and plan,
  read through the `codex` CLI you're already signed in to.
- **Claude activity** — tokens, estimated cost, and per-session breakdown,
  computed from your own local transcripts.
- **A 26-week heatmap** of daily usage.
- **Service health** from Anthropic's public status page.

<!-- SCREENSHOT:heatmap -->

## How it works

meterusage reuses the CLI logins already on your machine. It never handles a
credential itself.

| What | How | Needs network |
|---|---|---|
| Codex quota | Spawns `codex app-server --stdio` and calls `account/rateLimits/read` over JSON-RPC. The subprocess authenticates itself. | Yes, by the CLI |
| Claude activity | Streams `~/.claude/projects/**/*.jsonl` and sums usage fields. | No |
| Claude quota *(optional)* | Displayed only if a usage JSON already exists on disk. | No |
| Service health | Public Statuspage JSON. | Yes |

### Why there's no "Sign in with Claude" button

Anthropic publishes no supported API for Claude subscription quota — the only
sanctioned channel is Claude Code's own statusline. A third-party app *could*
lift Claude Code's OAuth token out of the Keychain and call an undocumented
endpoint using Anthropic's first-party client id. meterusage deliberately
doesn't, because that impersonates the official client and can break without
notice.

So the honest split: **Codex quota is live from the cloud. Claude numbers are
computed locally.** If you happen to have a usage JSON on disk, Claude quota
bars light up too — but nothing requires it, and nothing asks you for it.

See [docs/PRIVACY.md](docs/PRIVACY.md) for the full boundary and how each claim
is enforced by tests and hooks rather than promised in prose.

## Requirements

- macOS 13 Ventura or later
- Xcode command-line tools (`xcode-select --install`)
- Optional: [`codex`](https://github.com/openai/codex) CLI, signed in, for live
  Codex quota
- Optional: Claude Code, for local activity data

Missing either CLI is fine. Those sections show a calm empty state instead of
an error — meterusage is useful with just one of them installed.

## Build from source

```sh
swift build            # debug binary
swift test             # unit tests
./Scripts/make-app.sh  # assembles dist/MeterUsage.app, ad-hoc signed
```

No third-party dependencies. No Apple Developer account needed — the app is
ad-hoc signed, so macOS will ask you to confirm the first launch via
**System Settings → Privacy & Security**.

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
