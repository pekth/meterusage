# MeterUsage Electron candidate

Electron is the sole active target for new MeterUsage features. The legacy
Swift app is frozen as the current stable download and rollback option until
[staged retirement](../adr/0024-electron-primary-swift-retirement.md) passes.

This is the unpublished macOS TypeScript/Electron/React candidate. Its source
version is `0.2.41` in [package.json](../../package.json), matching the retained
Swift version number. Private build and installation receipts exist. Complete
native acceptance and public cutover remain open; this is not a released v2.1.
Use the [published Swift app](../swift/README.md) for the default installation.

## Source choices

Settings contains optional onboarding and the supported source choices. Changing
a selector alone does not access an account or switch collection. Apply the
selected method with its action. **Done** saves setup completion before opening
Usage. See [ADR 0023](../adr/0023-onboarding-source-choice.md).

| Provider and method | Available source behavior | Coverage limit |
| --- | --- | --- |
| Codex browser sign-in | Existing official app helper, with command-install compatibility, signs in through the provider page using a separate keyring-only profile. Reads allowance and provider-reported daily account tokens. | Account history is separate from CLI tokens. No local sessions, category split, cost or burn attribution comes from this method. Universal device/product coverage is unverified. |
| Codex CLI | Existing authenticated CLI supplies quota/reset metadata; local rollouts supply tokens, sessions and estimated cost. | Activity on this Mac only. |
| Claude Desktop | Explicit consent permits a fixed Keychain helper and read-only Desktop cache/cookie access for current account allowance. | Allowance only. No Desktop chat/token history, local cost, tier or extra-usage credit projection. Endpoint compatibility and live acceptance remain open. |
| Claude Code CLI | Local transcript counters, tier metadata and optional companion quota files. | Local activity; allowance requires the [companion](../COMPANION.md). |
| Grok CLI | Existing CLI authentication and local session summaries. | Consumer website/mobile sign-in is unsupported. Session/message counts do not establish token totals. |

**Use CLI** ends only MeterUsage-owned account state and waits for successful
cleanup before enabling local collection. Failed cleanup blocks the switch.
Ordinary **Disconnect** leaves collection off rather than silently falling back.
Other apps remain signed in. Demo and isolated live test profiles cannot switch
to local collection. See [desktop connections](../DESKTOP-CONNECTIONS.md) and
[privacy](../PRIVACY.md) for the exact access and failure contracts.

### Existing provider inputs

All nine adapters remain wired in [composition](../../src/main/composition.ts).
Antigravity and OpenCode onboarding guidance/actions remain requested work;
their collection exists without a connection row.

- Antigravity quota uses existing authenticated `agy` container state, Docker or
  Podman, image `antigravity-cli:local` and volumes `antigravity-config` and
  `antigravity-bin`. Native database/history usage is independent of that quota
  runtime. No separate MeterUsage browser login or API-key form exists.
- OpenCode Go quota reads the existing `opencode-go` key saved by OpenCode
  `/connect` in `~/.local/share/opencode/auth.json`. Independently, token history
  reads `~/.local/share/opencode/opencode.db`, with read-only CLI SQL fallback.
  Only `opencode-go` sessions count, not every provider used through OpenCode.
  A quota key alone cannot supply local history. The candidate fallback omits
  the legacy explicit `~/.bun/bin/opencode` probe; when direct DB reads fail and
  Bun is absent from the GUI PATH, CLI fallback discovery can fail.
- OpenRouter uses existing keys for account quota/credit and aggregate activity.
  That activity is provider account scope, not a local chat count.
- Cursor, Copilot CLI and Gemini CLI use optional existing local quota snapshots.
  Presence alone does not provide cloud quota or a token ledger.

Do not paste credentials into MeterUsage or documentation. The full input and
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
The category controls wrap above the content in narrow windows. Settings fits
the active page and expanded setup content, retains its width and top position
while on screen, and scrolls when content exceeds the available work area. Service health
appears after the primary usage cards in the Usage panel.

Provider groups can be reordered with drag handles, arrow keys or move buttons.
Saved order applies to Usage, service status, menu bar and side notch. Additional
accounts stay with their provider. Failed saves retain saved order. See
[ADR 0021](../adr/0021-provider-group-order.md).

The notch has one 36-pixel charcoal rail with provider marks inside 22-pixel
usage rings, percentages below and a Settings gear at the bottom. Details open on hover and
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
Live availability and coverage remain unverified. See
[ADR 0022](../adr/0022-codex-account-token-history.md).

Hover and keyboard focus expose dated exact grouped counts. Each live heatmap
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
on fresh quota-only notch cards. OpenCode Bun fallback discovery is a separate
provider regression. These findings do not establish how many users are affected.
AGY/OpenCode onboarding is pending requested scope, and pin/dots removals are
intentional. This documentation implements none of the proposed fixes.

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
source retirement and release. Electron's required Swift helpers remain.
