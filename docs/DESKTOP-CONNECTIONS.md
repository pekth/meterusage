# Desktop account connections

The macOS Electron candidate keeps account connection controls in Settings,
including first-run setup. This is candidate source behavior, not support in the
published Swift app. Native sign-in, Keychain permission, packaging and live
provider acceptance remain unverified.

## Setup

Before setup is complete, launch or app activation opens Settings. Choose a
connection method for each provider, or choose **Done** below the choices to
continue without signing in. Done saves the
existing setup-completion preference before opening usage. If saving fails,
Settings keeps the setup guidance and reports the error. Account connections
remain in Settings after setup; the main usage panel has no welcome card.
See [ADR 0014](adr/0014-settings-onboarding.md).

The **Connect using** selector offers the methods supported by each provider.
Selecting a method does not start sign-in or change collection. Use the button
below it to apply the choice. Existing profiles keep their current source.

- Antigravity: choose **Antigravity Desktop**, then **Connect Antigravity Desktop**.
  Keep one desktop account open and signed in. The candidate reads account
  allowance from its running local service without requiring `agy`. Separate
  language servers are ambiguous, even if they belong to the same account;
  close extra instances before connecting. **Antigravity CLI** remains an
  explicit alternative for the existing local integration. Desktop allowance
  includes no CLI-local history. Native and live-provider checks are pending.
- Codex: choose **Sign in to Codex** and complete browser sign-in. The candidate
  finds the helper in an existing Codex app in Applications, with existing
  command installations as a compatibility path. Users do not open a terminal
  or choose a configuration folder. A missing helper produces an unavailable
  message. The Codex app's authentication is not changed.
  Alternatively, choose **Codex CLI** and **Use CLI** to use an existing CLI
  sign-in for allowance and read local token activity.
- Claude: sign in to Claude Desktop on the Mac, choose **Connect Claude
  Desktop**, and approve MeterUsage's access explanation and any macOS
  Keychain prompt. The candidate requests account allowance using Desktop's
  current access token. This interface can change and is not a documented
  third-party consumer API contract.
  Alternatively, choose **Claude Code CLI** and **Use CLI** to read local Claude
  Code activity. CLI allowance requires a companion usage file; this option
  does not provide Claude website token history.
- Grok: choose **Grok Bot Desktop (Beta)**. Sign in through Grok Bot Desktop
  on this Mac first, then choose **Connect Grok Bot Desktop (Beta)** and approve
  access and any macOS Keychain prompt. MeterUsage reads the active encrypted
  access token and selected team, then requests allowance. It does not initiate
  a separate xAI sign-in or renew access. After expiry, sign in through Bot and
  reconnect. Existing **Grok CLI** collection remains an explicit alternative.
  The usage card can show measured quota burn after at least one minute of
  fresh readings. Units are percentage points per hour, not tokens or dollars.
  A reset, reconnect or stale reading starts collection again. Estimated
  run-out appears only from a positive measured rate before the reported reset.
  X and universal shared-pool coverage remain unverified.


**Use CLI** first disconnects only the MeterUsage-owned account connection and
waits for any Codex logout cleanup to succeed. A failed cleanup keeps local
collection off and reports an error. The source choice survives relaunch. The
ordinary **Disconnect** action still keeps account collection off without
switching to local data. Demo and isolated live test profiles cannot select
local collection. [ADR 0023](adr/0023-onboarding-source-choice.md) records this
explicit transition.

The normal refresh interval applies after connection. An expired login,
unsupported cache format, missing permission or provider failure keeps usage
unavailable. Open the relevant desktop app, disconnect the MeterUsage
connection, then connect again. Disconnect removes MeterUsage's own connection;
it does not sign out or erase data in another app.

Claude Desktop **Connect** failures use fixed messages in the existing error
banner. They distinguish foreground Keychain access, account configuration,
the active organization cookie, cache decryption, missing or ambiguous current
tokens, allowance request or response validation, post-request identity verification,
or saving MeterUsage's connection preferences. An identity recheck failure
can include a failed background Keychain or cache read. Messages contain no
raw exceptions, responses, tokens, account identifiers or paths. Cancellation
keeps its existing message. Background collection keeps its existing
unavailable and not-signed-in results.
The renderer error filter permits only these fixed diagnostics. Unknown
exceptions still produce the generic action error. Missing or ambiguous current
tokens keep collection disabled.

These diagnostics have source and synthetic-fixture proof only. They do not
identify the cause of a live connection failure or prove that Claude Desktop
connection works. Packaged banner display, Keychain access, Desktop compatibility
and live allowance still require native acceptance.

## Muse Code CLI

Unreleased Electron source adds a separate **Muse Code** row in Settings.
Sign in with the [official CLI](https://dev.meta.ai/products/muse-code), then
choose **Use Muse Code CLI**. Collection starts disabled and the choice survives
relaunch. Headless JSON collection also honors this choice. **Stop Muse Code**
cancels active reads and clears the in-memory allowance without signing out the CLI.
Demo mode provides invented allowance and blocks the setup action. Isolated
Codex and Claude test profiles exclude this provider.

MeterUsage starts `muse serve`, initializes the official experimental MSP
surface and calls [`usage/read`](https://meta-models.github.io/muse-code-sdk/next/generated/msp/methods/usage-read/).
It never starts a model turn or opens CLI credentials. The method returns the
host's last observation, which can be absent. Missing data is unavailable,
never zero. An unsupported CLI must be upgraded separately. Cards show the
original observation time, session and weekly percentages, and reported resets.
They provide no local token history or cost estimate.
The JSON quota report includes `observed_at` for Muse Code, separate from the
report's `generated_at`. Muse allowance stays in memory and is excluded from the
shared quota archive, so older versions can still load other providers on rollback.

Muse.ai's cloud agent and Desktop app use a separate subscription and session.
The Muse Code connection does not provide Muse.ai allowance. Native Muse.ai
session import remains pending verification of its store and encryption schema.
Source tests do not prove native or live-provider behavior.

## Data coverage

Account allowance comes from the provider account service. It can reflect use
outside the Mac where the provider shares that allowance. Provider account,
plan and product rules determine coverage. A quota percentage is not a token
ledger, message total or subscription invoice.

Local activity charts are labelled as activity on this Mac. OpenRouter's
remote usage is labelled as account activity and excluded from local totals. Connected
Codex/Claude account cards omit the separate local CLI activity source because
MeterUsage cannot establish that it belongs to the connected account. No local
and account total is added together. Claude account token history, ordinary
Claude chat tokens and Grok consumer history are outside this implementation.

## Authentication and isolation

Codex uses a generated MeterUsage-owned helper profile. Before login or polling,
the candidate checks the effective helper configuration for `keyring` storage.
It refuses another mode, including plaintext-file fallback. Login, allowance
reads and own-profile logout use the helper's `--listen stdio://` transport.
The helper environment keeps interpreter search paths without forwarding
inherited credential variables. The browser URL
must use HTTPS on an approved OpenAI host. Disconnect invokes logout only for
that generated profile. Cancellation attempts the same cleanup; a cleanup
failure is reported.

An unfinished sign-in profile enables cleanup only. Cancellation and disconnect
disable collection before logout, even if logout fails. The candidate retains
the owned profile ID for cleanup on the next GUI launch or explicit sign-in
retry. Retry completes cleanup before starting another login. Normal quit waits
up to five seconds for authentication cleanup. Headless reports only read existing
connections; they never start sign-in, show a permission prompt or perform
cleanup logout. Clear local scan cache keeps the established connection reader.
Connected Codex cards show **Use reset** beside available, unexpired credits in
the menu. The existing native confirmation names the account and credit and
defaults to Cancel. After confirmation, the candidate rereads allowance and
rejects a missing, spent or expired credit or a changed/disconnected profile.
The official helper consumes once under the same keyring-only profile, then
quota refreshes. Cancelling makes no consume call. A disconnect aborts pending
work; a request already sent to the provider cannot be undone. See
[ADR 0017](adr/0017-connected-codex-menu-reset.md).

Claude access requires explicit consent; a connection call without a consent
callback denies access. A bundled native helper performs one
fixed Keychain read. Background calls forbid interactive authentication. The
main process decrypts the Desktop cache, reads the active organization cookie
from a read-only database, and selects one valid account-scoped access token.
Ambiguous, legacy, expired or unsupported caches fail closed. Refresh tokens
are skipped, and MeterUsage never writes to Claude Desktop's stores. It uses
its own User-Agent and requests no reset grants or model inference.

Only an opaque account/organization fingerprint is retained for Claude. It is
not published to the renderer. The candidate checks it before and after the
allowance request so a Desktop account switch cannot update the old account
card. Switching the connection clears prior quota. Connected-account quota
archives are discarded at launch, and authentication/data errors remove them.
This avoids restoring a reading without proving its account identity.
If an allowance request fails, the current account is checked again before a
dated last-known reading can remain. Missing or revoked Desktop access clears
that reading. A collection timeout clears account-bound quota because the
identity check may not have completed. Disconnect prevents the post-request
credential reread. Changing a connection also clears that slot's alert suppression.

Demo mode blocks live account connections, Keychain access and helper login.
Synthetic tests cover protocol, consent, token selection, account switching,
disconnect, numeric validation, stale source results and IPC boundaries.
See [privacy](PRIVACY.md) and [ADR 0011](adr/0011-desktop-account-connections.md).

## Codex account daily tokens

A connected Codex account also reads `account/usage/read` through the same
managed ChatGPT helper. The request omits `threadId`. The helper must support
this method and pass the existing effective keyring-storage guard. A failed or
unsupported read shows "Account history unavailable" and leaves quota separate.

The main, notch and shared card label this grid "Account token activity" with
"Provider-reported account scope". It shows 26 weeks ending at the latest
reported date. Hover or focus a day for its exact token count. Dashed days are
unavailable, including gaps before or between reported dates. A reported zero
is a measured value. The existing Daily heatmaps and Codex heatmap settings
control this grid. Provider dates remain calendar labels; no timezone is assumed.

Null or absent daily buckets cannot be reconstructed from summary statistics.
Invalid, duplicate or unsafe buckets fail closed. No token-category breakdown,
session count or cost is invented. History stays in memory and is cleared on
failed reads, source replacement or disconnect. It never merges with local
profile history or local totals. Collection uses the existing deadline and
bounded backoff, with no new retry loop.

The public contract does not establish complete Codex-only, cross-device or
cloud coverage, day timezone, retention or service polling limits. Live account
availability and coverage require separate proof. Additional local profiles
retain their existing readers. See [ADR 0022](adr/0022-codex-account-token-history.md).

## Isolated live Codex validation

The candidate accepts `--codex-test-profile` with an absolute test directory.
This selects the existing UI and connection flow with live Codex allowance.
It cannot be combined with `--demo` or `--candidate-profile`. The directory
must be empty on first use and owned by this test mode on later launches.
Installed-app storage and symlink paths are refused, including nested paths
inside an existing profile. The macOS GUI permits only Electron's three direct
singleton links after checking their ownership, socket location and matching
metadata. JSON entrypoints retain strict symlink rejection. Startup checks
metadata before requesting Electron's lock or starting the helper, with a
limit of 32,768 entries and 24 directory levels. A second launch reveals the
existing panel; invalid metadata exits without an uncaught popup. See
[ADR 0013](adr/0013-candidate-single-instance-startup.md).

Preferences, history, connection profiles and Electron state stay in that
directory. The real OS home remains available for helper discovery and macOS
Keychain. Choose **Sign in to Codex** in the app and finish browser sign-in.
The app starts disconnected, so an unavailable reading before sign-in is
expected. Successful connections remain available across normal quit and
relaunch; **Disconnect** signs out only that MeterUsage connection.

This mode reads Codex account allowance, provider-reported daily tokens and the public OpenAI service-status
feed, and permits explicitly confirmed Codex reset redemption. Status requests
use no account credentials. It has no local activity or other-provider collection.
See [ADR 0015](adr/0015-codex-test-public-status.md) and
[ADR 0017](adr/0017-connected-codex-menu-reset.md). Update checks, update
installation, login-item changes and notifications are disabled. It does not
change the primary setup for users or replace an installed app.

After a failed refresh, the Service status panel, notch card and tray tooltip
keep the last successful reading marked as last known with its age and the
refresh failure. Public-feed errors do not use account or quota error text.
Copied diagnostics also marks retained status as stale, with the time since its
last successful check and a fixed service-status error. A successful retry clears
that stale marker.

Synthetic isolation tests do not prove native sign-in or visible cloud usage.
Live acceptance requires the packaged app, human browser sign-in, fresh
allowance in its actual UI and comparison with the same provider account.
See [ADR 0012](adr/0012-codex-live-test-profile.md).

## Isolated live Claude validation

Use `--claude-test-profile` with a separate absolute test directory. It reuses
the existing Settings consent dialog, fixed Keychain helper, read-only Desktop
reader and allowance request. The directory must be empty on first use. Its
marker differs from Codex and demo markers; those profiles cannot be reused.
The same protected-path, symlink and Electron singleton checks apply.
Do not combine the flag with another test profile, `--demo` or
`--candidate-profile`.

The app starts disconnected with Claude collection visible. Cancel the access
dialog to leave consent off. After approval, only Claude account allowance is
collected. JSON preferences, archives and Electron state stay in the test
directory; OS home remains available only to the existing Desktop reader.
Codex sign-in, polling and cleanup are blocked. Other providers, local activity,
status feeds and reset redemption are excluded. Updates, login-item changes
and notifications remain blocked by candidate mode.

Normal quit retains an approved account fingerprint for relaunch. Background
reads cannot prompt. Disconnect saves consent off, clears allowance and leaves
Claude Desktop signed in. An unavailable reading must not fall back to local
CLI or companion files.

Synthetic tests prove isolation and consent/connection/relaunch/disconnect
against invented Desktop data. Native acceptance still requires a separately
packaged candidate: cancel consent, approve access, compare fresh allowance
with the same Desktop account, relaunch without a prompt, then disconnect and
confirm allowance is removed. Test denied access and account/organization
switches only with the account owner's approval. Never run the Keychain helper
directly or capture its output. See
[ADR 0016](adr/0016-claude-live-test-profile.md).

## Antigravity Desktop source boundary

The source adapter discovers one same-user Antigravity desktop language server
and its PID-owned IPv4 loopback listeners. It reads only the candidate process
arguments for its current CSRF token. Fixed `GetUserStatus` and
`RetrieveUserQuotaSummary` requests use HTTPS first; HTTP is limited to the
declared, owned extension-server port. TLS certificate exemption is local to
that verified loopback request. Redirects are rejected. Each reply is limited
to 1 MiB, each request to three seconds, and collection to fifteen seconds.

Account identity must match before and after allowance collection. Only an
opaque fingerprint enters preferences. CSRF credentials, account email and raw
replies stay in main-process memory, outside settings, diagnostics and logs.
The integration neither writes provider stores nor refreshes credentials.
Changed identity, provider closure, expired buckets, missing fractions and
empty summaries leave allowance unavailable and clear prior account quota.
An empty modern summary never falls back to legacy data. Legacy model quota
is read only when the modern RPC explicitly reports unsupported; it cannot
establish weekly allowance. Disconnect and cancellation reject late results.

This is source and synthetic-fixture coverage. It is absent from the published
build 54 beta. Native discovery, local transport and live allowance comparison
remain unverified. See [ADR 0026](adr/0026-antigravity-desktop-local-quota.md).

## Grok Bot Desktop Beta

New connections use the existing Grok Bot Desktop sign-in after explicit
consent. No CLI, copied credential or separate MeterUsage OAuth flow is needed.
The fixed candidate store is `Library/Application Support/Grok Bot/sand-secrets.json`
under the user's home. MeterUsage selects only the active account's encrypted
access token and optional selected team. Scoped and canonical encrypted legacy
v10 values require the same full JWT-subject hash binding to the active account.
It rejects plaintext, unsupported encryption/versions, duplicate keys, expired
tokens and ambiguous scope.
Refresh tokens and other accounts' credential values are skipped.

The bundled helper reads only `Grok Bot Safe Storage` / `Grok Bot Key` in macOS
Keychain. Explicit connection can show a Keychain prompt; polling forbids UI.
The reader opens no symlinks, bounds the JSON read, and checks store metadata,
account and team before and after the request. These checks detect observed
changes; they do not lock Bot or exclude other writers. It never modifies Bot
stores, refreshes credentials or copies them to disk.

The fixed read is Connect JSON POST `{}` to
`https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`, using
MeterUsage's own User-Agent, a bearer access token and an optional selected-team
header. Redirects are refused, each request has a 30-second timeout and a 1 MiB
response cap. Only numeric quota percentage and a reported reset are displayed.
Pooled enterprise allowance, missing quota and contradictory limit flags stay
unavailable. Trials require a future expiry; trial expiry is not a reset.
No cadence, X coverage or separate Cursor allowance is inferred from this pool.

Only an opaque account/team fingerprint and internal source choice persist.
Cancellation and disconnect prevent private rereads and reject late results.
Connected quota has no local CLI history attached. Ordinary transport failures
can retain dated allowance only after the account and store are reverified.
Source changes clear account-bound quota. Disconnect changes only MeterUsage.

This private compatibility contract was traced statically from Grok Bot 0.71.2
and Electron 42.1.0. Native metadata confirms the encrypted legacy store format
and fixed Keychain label. Successful Keychain access and server acceptance of
JSON with MeterUsage's own headers remain **UNVERIFIED**. No app machine identity
or client impersonation is used. See [ADR 0028](adr/0028-grok-bot-desktop-reader.md)
and its [correction](adr/0030-grok-bot-encrypted-compatibility.md).

### Saved Cursor connections

Previously saved Cursor connections retain their original reader until
explicitly disconnected or replaced. A missing internal source marker means
legacy Cursor; all new connections select Bot Desktop. The legacy reader still
requires closed/checkpointed Cursor, immutable SQLite, identity checks and the
fixed Cursor dashboard endpoints. It is never selected as a failed Bot fallback.
See [ADR 0027](adr/0027-grok-cursor-closed-reader.md).

## OpenCode Go local setup

Choose **Use local OpenCode** in Connections to collect local Go sessions.
No sign-in or API key is needed for that history. Allowance separately uses an
existing Go key saved by OpenCode. Only `opencode-go` sessions count. The SQL
fallback also discovers executable Bun installs at `~/.bun/bin/opencode`.

All provider heatmaps share a 26-column, seven-row layout. A 30-day feed keeps
older days unavailable rather than showing invented zero-token readings.

## API billing

OpenRouter uses its existing key for balance and aggregate activity. Separate
OpenAI API and Anthropic API billing cards read sanitized snapshots from the
bundled one-run helper. Subscription connections do not authorize API billing.
See [API billing setup](API_USAGE_BETA.md) for Admin-key scope and limitations.
