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
- Grok: choose **Grok Bot via Cursor (Beta)**. Sign in to Cursor on this Mac,
  check Bot allowance, then quit Cursor before choosing **Beta Connect via
  Cursor** and approving access. No CLI is required. Cursor must have closed
  with its SQLite store checkpointed; an active process, nonempty WAL/journal,
  ambiguous evidence or observed store changes prevent access. MeterUsage never
  stops Cursor. When access expires, reopen Cursor, then quit and reconnect.
  Existing **Grok CLI** collection remains an explicit alternative. Neither
  method establishes universal Grok Desktop, X or shared-pool coverage.

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

## Grok Bot via Cursor Beta

This source-only compatibility connection uses Cursor's current desktop token
in main-process memory. It selects only `cursorAuth/accessToken` from `ItemTable`
in `Library/Application Support/Cursor/User/globalStorage/state.vscdb`. It opens
the original database with SQLite `immutable=1&mode=ro`. No credential store or
file is copied to temporary disk, no refresh occurs, and SQLite performs no
writes or sidecar bookkeeping. Filesystem access-time metadata remains subject
to the operating system's read policy.

Pre/post process and filesystem guards require closed/checkpointed evidence.
They detect observable races; they provide no mutual exclusion and do not prove
Cursor never ran between observations. Immutable SQLite guarantees this reader
does not write even if another process races it. Nonempty WAL or rollback
journal files are rejected because immutable reads ignore uncheckpointed data.
A changed database, sidecar, directory identity or ambiguous evidence fails
closed. The guards run again before Bot allowance and after the request.

Each request first verifies the JWT subject against fixed HTTPS
`cursor.com/api/auth/me`, then POSTs `{}` to
`cursor.com/api/dashboard/get-sand-usage-status` with Cursor's required Origin.
Redirects are refused, requests have a 30-second timeout and a 1 MiB response
limit, and credentials must remain valid for more than 60 seconds. Identity is
case-sensitive. Only its opaque fingerprint and the source choice persist.
The current identity and store fingerprint must match before results are used.

Included quota honors `includedLimitZero` before the legacy included-limit
flag. A trial requires a future `sandTrialExpiresAt`; trial expiry is never a
reset timestamp. Missing data stays unavailable. Reset cadence is not inferred.
Connected allowance has no local CLI activity attached. Disconnect and source
changes clear account-bound quota and reject late results; ordinary failures
use the existing coordinator backoff. There is no automatic token renewal.

Synthetic tests cover the reader, guards, account binding, consent, cancellation,
disconnect, expiry and request bounds. Native Cursor formats, Electron SQLite,
visible setup and live provider support remain **UNVERIFIED**. This change is
not in published build 54. See [ADR 0027](adr/0027-grok-cursor-closed-reader.md).
