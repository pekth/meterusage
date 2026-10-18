# Architecture decision records

This directory records decisions that affect repository work. Read an ADR before changing a documented decision. Add a new numbered ADR for a new decision; do not rewrite an accepted decision to fit a later change.

The [version comparison](../VERSIONS.md) separates active Electron development
from frozen legacy Swift support. [ADR 0024](0024-electron-primary-swift-retirement.md)
amends the long-term development direction. ADR 0010's shared identity,
compatibility and acceptance requirements remain in force. The
[Swift](../swift/README.md) and [Electron](../electron/README.md) guides route setup.

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [0024](0024-electron-primary-swift-retirement.md) | Develop new features in Electron; freeze Swift as legacy rollback and retire its app source after verified acceptance and cutover. Keep required Swift helpers. | Accepted development direction; retirement and public cutover pending |
| [0001](0001-repository-owned-knowledge.md) | Keep public-safe project knowledge and decisions beside the project and exclude private operational content. | Accepted |
| [0002](0002-provider-marks-stay.md) | Keep existing provider logos/marks (`ProviderMark` + `Resources/*-logo.png`); do not redesign them in feature or cross-platform work. | Accepted |
| [0003](0003-burn-attribution-scope.md) | Scope burn attribution to the last 7 days across all token-bearing providers, with per-provider aggregates that never count as long chats. | Accepted |
| [0004](0004-side-notch-anchor-invariant.md) | Keep the side notch anchored by the strip's top-right corner, use whole-point frames, anchor content to the window top, and require captured frame evidence for layout or motion changes. | Accepted |
| [0005](0005-multi-account-slots.md) | Model a second Claude/Codex account as its own provider slot keyed by an alternate config directory; never merge two accounts' windows and never read or display account identity. | Accepted; slot mechanism amended by [0006](0006-managed-account-list.md) |
| [0006](0006-managed-account-list.md) | Additional accounts are a managed, unbounded Settings list; `ProviderSlot` (provider + generated id, label display-only) keys every metered surface, with primary-slot persistence formats unchanged. | Accepted |
| [0008](0008-reset-aware-quota-pacing.md) | ADR 0008: Collect fresh quota observations after a manual reset | Accepted |
| [0009](0009-prebuilt-bundle-default.md) | Download and verify the prebuilt app by default; compile only with `--build-from-source`. | Accepted |
| [0010](0010-macos-typescript-electron.md) | Port macOS and the schema-1 JSON CLI to TypeScript/Electron/React; preserve data contracts and pause Windows until a test machine is available. | Accepted architecture; Windows implementation hold amended by [0033](0033-windows-desktop-candidate.md); native acceptance pending |
| [0011](0011-desktop-account-connections.md) | Add opt-in Codex browser sign-in and Claude Desktop account allowance; separate account allowance from local activity. | Accepted implementation direction; native and provider acceptance pending |
| [0012](0012-codex-live-test-profile.md) | Run isolated live Codex validation in the existing UI while blocking other providers and candidate system effects. | Accepted implementation direction; reset prohibition superseded by [0017](0017-connected-codex-menu-reset.md); native UI acceptance pending |
| [0013](0013-candidate-single-instance-startup.md) | Validate candidate Electron singleton metadata before locking; preserve other symlink rejection and safe activation during startup and Quit. | Accepted implementation direction; native acceptance pending |
| [0014](0014-settings-onboarding.md) | Keep first-run setup and account connections in Settings, with optional sign-in and saved completion before opening usage. | Accepted implementation direction; native acceptance pending |
| [0016](0016-claude-live-test-profile.md) | Run isolated Claude allowance validation in the existing UI with explicit consent and no Codex access or cleanup. | Candidate implementation; independent review and native acceptance pending |
| [0015](0015-codex-test-public-status.md) | Read public Codex service status in the isolated test profile and show unavailable or dated status explicitly. | Accepted implementation direction; native acceptance pending |
| [0017](0017-connected-codex-menu-reset.md) | Allow explicitly confirmed Codex menu reset redemption for the same connected keyring-only profile, including isolated Codex mode. | Accepted implementation direction; native and live redemption proof pending |
| [0018](0018-hover-only-notch-details.md) | Use hover-only Electron notch details, Usage or Compact dots at rest, and integer pixel notch sizing. | Superseded by ADR 0019 |
| [0019](0019-single-design-notch.md) | Keep one usage-ring and percentage strip, remove the dots option, and clear expanded state on disable/hide. | Accepted implementation direction; independent review and native acceptance pending |
| [0021](0021-provider-group-order.md) | Persist Electron provider group order across usage, menu bar and side notch, with keyboard moves and saved-order recovery. | Accepted implementation direction; rendered and native acceptance pending |
| [0022](0022-codex-account-token-history.md) | Read provider account daily tokens separately from local activity through the managed ChatGPT helper. | Accepted implementation direction; independent review, native and live acceptance pending |
| [0023](0023-onboarding-source-choice.md) | Offer supported CLI and account methods in onboarding, with explicit cleanup before switching to local collection. | Accepted implementation direction; native interaction acceptance pending |
| [0025](0025-card-settings-diagnostic-reports.md) | Keep Settings in usage cards and restore explicit sanitized support reports in Diagnostics. | Accepted implementation direction; native and live delivery acceptance separate |
| [0026](0026-antigravity-desktop-local-quota.md) | Opt-in Antigravity Desktop quota through its owned local service. | Source implementation; native/provider acceptance pending |
| [0027](0027-grok-cursor-closed-reader.md) | Opt-in Grok Bot via closed/checkpointed Cursor with immutable SQLite and account binding. | Source implemented; native/live unverified |
| [0028](0028-grok-bot-desktop-reader.md) | Use consented Grok Bot Desktop scoped credentials and a fixed read-only Connect allowance request for new Grok connections; retain saved Cursor sources. | Source and synthetic proof; native/live unverified |
| [0029](0029-api-billing-snapshots.md) | Separate OpenAI API and Anthropic API billing snapshots from subscriptions; keep Admin keys in a one-run helper. | Source implementation; real billing acceptance pending |
| [0030](0030-grok-bot-encrypted-compatibility.md) | Accept account-bound encrypted Bot legacy values and use the observed fixed Keychain account. | Bounded source correction; live allowance acceptance pending |

| [0031](0031-grok-quota-burn.md) | Measure Grok Bot quota burn from recent same-account percentages without inventing token counts or cycle duration. | Source implementation; native and live rate acceptance separate |

| [0032](0032-one-time-api-setup.md) | Separate API setup from account connections and accept a one-time Admin key for explicit billing fetches, without saving credentials. | Source implementation; real billing acceptance pending |
| [0033](0033-windows-desktop-candidate.md) | Record the Windows x64 Electron candidate scope, storage boundary and evidence still required before release. | CI verified; interactive acceptance, installer acceptance and signing unverified |
