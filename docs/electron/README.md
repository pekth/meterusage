# MeterUsage Electron beta

Electron is the sole active target for new MeterUsage features. The legacy
Swift app is frozen as the current stable download and rollback option until
[staged retirement](../adr/0024-electron-primary-swift-retirement.md) passes.

The public beta is **0.3.0-beta.1, build 54**, for Apple silicon and macOS 13+.
Use the [beta download and installation guide](../BETA.md). The ZIP is Developer
ID signed and notarized. This is an opt-in manual download; Swift stays stable.
Source manifests and build 54's cosmetic Settings footer still say `0.2.41`.
Packaging explicitly sets the beta version. Full native acceptance remains open.

See the [current beta screenshots](../SCREENSHOTS.md) for Usage, notch and Settings.

## Source choices

Settings contains optional onboarding and the supported source choices. Changing
a selector alone does not access an account or switch collection. Apply the
selected method with its action. **Done** saves setup completion before opening
Usage. See [ADR 0023](../adr/0023-onboarding-source-choice.md).

| Provider and method | Available source behavior | Coverage limit |
| --- | --- | --- |
| Codex browser sign-in | Existing official app helper, with command-install compatibility, signs in through the provider page using a separate keyring-only profile. Reads allowance and provider-reported daily account tokens. | Account history is separate from CLI tokens. No local sessions, category split, cost or burn attribution comes from this method. Universal device/product coverage is unverified. |
| Codex CLI | Existing authenticated CLI supplies quota/reset metadata; local rollouts supply tokens, sessions and estimated cost. | Activity on this Mac only. |
| Claude Desktop | Explicit consent permits a fixed Keychain helper and read-only Desktop cache/cookie access for current account allowance. | Allowance only. No Desktop chat/token history, local cost, tier or extra-usage credit projection. Compatibility can fail when the active account has no allowance token; paid-account live acceptance remains open. |
| Claude Code CLI | Local transcript counters, tier metadata and optional companion quota files. | Local activity; allowance requires the [companion](../COMPANION.md). |
| Antigravity Desktop | Explicit consent reads allowance from one running, signed-in desktop server. | Account allowance only. Local CLI activity stays separate. Live comparison was confirmed by the owner; broad compatibility is unverified. |
| Grok Bot Desktop (Beta), unreleased source | Explicit consent reads the active account-bound encrypted Bot credential and requests allowance. | Native Keychain/store and endpoint compatibility remain unverified. Existing saved Cursor connections retain their source. |
| OpenCode Go local | **Use local OpenCode** enables local Go sessions without a sign-in or key. Existing Go authentication also supplies allowance. | Go sessions only. Other providers used through OpenCode are excluded. |
| Grok CLI (Beta) | Existing CLI authentication and local session summaries. | Consumer website/mobile sign-in is unsupported. Session/message counts do not establish token totals. |

**Use CLI** ends only MeterUsage-owned account state and waits for successful
cleanup before enabling local collection. Failed cleanup blocks the switch.
Ordinary **Disconnect** leaves collection off rather than silently falling back.
Other apps remain signed in. Demo and isolated live test profiles cannot switch
to local collection. See [desktop connections](../DESKTOP-CONNECTIONS.md) and
[privacy](../PRIVACY.md) for the exact access and failure contracts.

### Existing provider inputs

All nine adapters remain wired in [composition](../../src/main/composition.ts).
The current source adds an OpenCode Go local setup action and Antigravity
Desktop connection. These changes are separate from the published build 54.

- Antigravity CLI quota uses existing authenticated `agy` container state, Docker or
  Podman, image `antigravity-cli:local` and volumes `antigravity-config` and
  `antigravity-bin`. Native database/history usage is independent of that quota
  runtime. No separate MeterUsage browser login or API-key form exists.
- OpenCode Go quota reads the existing `opencode-go` key saved by OpenCode
  `/connect` in `~/.local/share/opencode/auth.json`. Independently, token history
  reads `~/.local/share/opencode/opencode.db`, with read-only CLI SQL fallback.
  Only `opencode-go` sessions count, not every provider used through OpenCode.
  A quota key alone cannot supply local history. The OpenCode-only CLI fallback
  checks executable `~/.bun/bin/opencode` installs as well as the existing paths.
- OpenRouter uses existing keys for account quota/credit and aggregate activity.
- Separate OpenAI API and Anthropic API cards read owner-only billing snapshots
  from **Settings → API connections → Fetch billing** or the bundled one-run
  helper. Settings can reuse the previous app's saved Keychain Admin key or
  accept a masked, one-time key. Neither path saves new credentials. See [API billing](../API_USAGE_BETA.md).
  That activity is provider account scope, not a local chat count.
- Cursor, Copilot CLI and Gemini CLI use optional existing local quota snapshots.
  Presence alone does not provide cloud quota or a token ledger.

Enter an API Admin key only in its dedicated Settings field or the advanced
helper prompt. Never paste credentials into diagnostic reports or documentation. The full input and
request list is in [privacy](../PRIVACY.md#provider-inputs-and-requests).

### Advanced local accounts

Additional Codex and Claude accounts are user-selected local configuration
directories, not arbitrary cloud subaccount logins. Settings supports adding,
renaming, enabling, changing directory and removing rows. Stable generated slot
IDs keep history separate through rename. Removing a row does not delete provider
files. Source reconstruction takes effect without the legacy relaunch step;
native picker and persistence acceptance remain open. See
[ADR 0006](../adr/0006-managed-account-list.md).

## Current interface

The candidate has a Usage panel and a separate Settings window. Small, Medium
and Large sizing applies to panel/Settings text and controls; main-panel width
scales and height fits within the display. Ctrl/Cmd plus or minus changes size;
Ctrl/Cmd 0 restores Medium. Refresh interval, theme/accent, collection/display,
heatmap, pacing, telemetry, chart, alerts, login and update preferences remain.

Settings has a compact category sidebar: Connections, Appearance, General,
Providers, Side notch, Usage details and Diagnostics. Provider summaries show the
current source, collection state and reading availability. Choose Configure for
setup actions; selecting a method still requires its explicit connection action.
Diagnostics offers **Send report** for an explicit private support submission,
with progress, a confirmed reference and safe retry feedback. **Copy diagnostics**
remains available. See [reporting](../REPORTING.md) for content and privacy limits.
The category controls wrap above the content in narrow windows. Settings fits
the active page and expanded setup content, retains its width and top position
while on screen, and scrolls when content exceeds the available work area.

Service status appears first in the Usage panel and stays visible. Provider and
account tabs show one card at a time in saved order; arrow keys and Home/End
switch tabs. Quota, eligible reset actions and heatmaps stay visible. More
activity opens secondary recorded metrics, Usage by period opens period shares,
and Active window breakdown opens notch burn contributors. The All-provider
activity breakdown contains local totals and measured burn. Shared cards retain
complete statistics and period/burn data.

Provider groups can be reordered with drag handles, arrow keys or move buttons.
Saved order applies to Usage, service status, menu bar and side notch. Additional
accounts stay with their provider. Failed saves retain saved order. See
[ADR 0021](../adr/0021-provider-group-order.md).

The notch has one 36-pixel charcoal rail with provider marks inside 22-pixel
usage rings and percentages below. Settings stays in each usage card footer;
the strip has no Settings button. Details open on hover and
close through the existing delay and temporary action guards. Pin, dots and
multiple-design controls are removed. Current source uses a 220-pixel card and
36-pixel strip; retained Swift uses 250/44 points. Shared-image capture remains
250 pixels wide. ADR 0019 records the current dimensions. Native fixed-edge captures for two different-height
cards are still required. See [side notch](../SIDE-NOTCH.md) and
[ADR 0019](../adr/0019-single-design-notch.md).

### Heatmap scope

Local Codex/Claude activity supports 26-week daily, weekly and cumulative views.
Usage telemetry without extended daily activity uses a 30-day grid and preserves
its token or session units. The optional 30-day line chart is separate. Connected
Codex has a daily 26-week account-token grid ending on the latest provider date.
Unreported dates stay unavailable; reported zero is zero. Account history stays
in memory and is excluded from local rollups, durable history and schema-1 JSON.
Live Codex account history has been observed; complete device/product coverage remains unverified. See
[ADR 0022](../adr/0022-codex-account-token-history.md).

Compact hover/focus readouts are an unreleased source change; published build 54
retains exact readouts. Hover and keyboard focus show dated compact totals such as `42.4B tokens` and
`1.6K sessions`. Tooltips and accessible labels retain exact grouped counts. Each live heatmap
has one Tab entry. Use arrow keys to move between days, Home/End for the first
or last cell, and Tab to leave the grid. Shared images omit focusable cells.
Feedback about 30-day versus 26-week grid geometry
remains pending. These source contracts do not establish native keyboard access,
layout or anchor acceptance.

## Known parity gaps

The source comparison identifies five primary UI omissions/reductions:

- Settings lacks the legacy read-only slot/plan/source overview. Plan badges
  remain on Usage cards.
- The independent per-provider seven-day sparkline is absent; the optional
  30-day chart and aggregate seven-day total remain.
- Reset countdown/date is not independent of projected exhaustion. ETA can
  replace the reset date field; notch header countdown is absent.
- Update feedback lacks release notes and visible download/relaunch progress.
  Install/Retry exists; native update completion remains unverified.
- The tray context menu lacks **Refresh Now**. Usage and notch refresh remain.

Smaller display gaps include today's session count in token-unavailable
telemetry, average tokens/turn and aggregate long-chat count on the main burn
card, provider-specific recovery hints, diagnostics copy feedback and a timestamp
on fresh quota-only notch cards. These findings do not establish how many users
are affected. Current source adds Antigravity Desktop and OpenCode local setup,
restores Bun discovery and matches heatmap geometry. Pin/dots removals are
intentional. Native and provider acceptance remain separate.

## Build and test

Run commands from the repository root. Node `>=24.13.1` and `pnpm@12.9.1` are
declared in [package.json](../../package.json).

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
```

These checks can run on Linux. They prove their source/fixture layer only.
On macOS, `pnpm package:mac` exports marks, compiles the fixed Claude Desktop
helper, builds and packages an Apple silicon ZIP with `--publish never`.
It does not install or publish the candidate. It requires the existing Swift
and signing tools. Do not invoke the Keychain helper during synthetic QA.
See [contributor commands](../../CONTRIBUTING.md#typescript-electron-candidate).

## Isolated QA

The default app name, bundle ID and data/preferences overlap Swift. Do not run
both editions against normal profiles. Use an empty isolated directory on first
use, or reuse its matching candidate marker for relaunch checks. Candidate paths
must be canonical and cannot follow symlinks.

After `pnpm build`, synthetic headless QA uses:

```sh
meterusage_demo_root="$(node -p 'require("node:fs").realpathSync(require("node:os").tmpdir())')"
node dist/main/cli.cjs json --force --demo --candidate-profile "$meterusage_demo_root/meterusage-cli-demo"
```

After packaging on macOS, synthetic GUI QA uses:

```sh
./release/mac-arm64/MeterUsage.app/Contents/MacOS/meterusage --demo --candidate-profile /private/tmp/meterusage-native-demo
```

Demo isolates preferences, history, caches and Electron state and blocks live
provider discovery, updates and login-item changes. It does write isolated files.
The separate opt-in `--codex-test-profile` and `--claude-test-profile` flows are
for isolated live QA, with different provider access limits. They do not grant
normal-profile coexistence or complete native acceptance. Follow
[demo and candidate isolation](../DEMO.md#electron-candidate),
[Codex test boundaries](../adr/0012-codex-live-test-profile.md),
[reset confirmation amendment](../adr/0017-connected-codex-menu-reset.md) and
[Claude test boundaries](../adr/0016-claude-live-test-profile.md).

## Acceptance and release boundary

Private installation receipts do not close native acceptance. Remaining proof
includes native setup/account/offline journeys, tray/focus/accessibility,
notifications, login items, sharing, updater replacement/relaunch, drag/display
persistence and two different-height notch captures. Reuse matching source,
packaging and installation receipts only for their recorded layer. Windows
implementation, packaging, CI, testing and release remain paused.

[ADR 0010](../adr/0010-macos-typescript-electron.md) keeps Swift as the behavior
reference and rollback path. No automatic cutover, data migration, release or
installed-app replacement follows from these docs. The [repository strategy](../VERSIONS.md#proposed-same-repository-strategy)
records the accepted development direction and the checks still required for
source retirement and stable cutover. This opt-in beta does not close those checks. Electron's required Swift helpers remain.

Desktop account research for Grok/Cursor, Antigravity and OpenCode Go is recorded
in [DESKTOP-LOGIN-RESEARCH.md](../DESKTOP-LOGIN-RESEARCH.md). It separates
documented sign-in from implemented quota collection.

### Unreleased Antigravity Desktop setup

Current source adds **Connect Antigravity Desktop** to the existing source
selector. One running, signed-in desktop language server supplies account
allowance without `agy`; local CLI history is excluded. Multiple matching
servers and missing or expired data remain unavailable. **Use CLI** selects
the existing local integration explicitly. This adapter has synthetic-fixture
coverage only and is absent from published build 54. Native process discovery,
local transport and live quota comparison remain acceptance gaps. See
[desktop connections](../DESKTOP-CONNECTIONS.md#antigravity-desktop-source-boundary).

All activity heatmaps use the same 26-column, seven-row grid. Feeds with only
30 days keep older dates unavailable. The common layout does not extend the
source history or change local versus provider-account coverage.
