# Desktop account connections

The macOS Electron candidate adds account connection controls to first-run
setup and Settings. This is candidate source behavior, not support in the
published Swift app. Native sign-in, Keychain permission, packaging and live
provider acceptance remain unverified.

## Setup

- Codex: choose **Sign in to Codex** and complete browser sign-in. The candidate
  finds the helper in an existing Codex app in Applications, with existing
  command installations as a compatibility path. Users do not open a terminal
  or choose a configuration folder. A missing helper produces an unavailable
  message. The Codex app's authentication is not changed.
- Claude: sign in to Claude Desktop on the Mac, choose **Connect Claude
  Desktop**, and approve MeterUsage's access explanation and any macOS
  Keychain prompt. The candidate requests account allowance using Desktop's
  current access token. This interface can change and is not a documented
  third-party consumer API contract.
- Grok: automatic consumer connection is unavailable. Existing command-based
  collection remains available for existing users. It does not establish
  browser/mobile consumer support. The setup does not ask for manual numbers.

The normal refresh interval applies after connection. An expired login,
unsupported cache format, missing permission or provider failure keeps usage
unavailable. Open the relevant desktop app, disconnect the MeterUsage
connection, then connect again. Disconnect removes MeterUsage's own connection;
it does not sign out or erase data in another app.

## Data coverage

Account allowance comes from the provider account service. It can reflect use
outside the Mac where the provider shares that allowance. Provider account,
plan and product rules determine coverage. A quota percentage is not a token
ledger, message total or subscription invoice.

Local activity charts are labelled as activity on this Mac. OpenRouter's
remote usage is labelled as account activity and excluded from local totals. Connected
Codex/Claude account cards omit the separate local CLI activity source because
MeterUsage cannot establish that it belongs to the connected account. No local
and account total is added together. Detailed account token history, ordinary
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
Connected account cards show reset-credit details without redemption controls;
redemption stays limited to existing sources that support it.

Claude access requires explicit consent. A bundled native helper performs one
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

This mode reads only Codex account allowance. It has no local activity, status
feed, reset redemption or other-provider collection. Update checks, update
installation, login-item changes and notifications are disabled. It does not
change the primary setup for users or replace an installed app.

Synthetic isolation tests do not prove native sign-in or visible cloud usage.
Live acceptance requires the packaged app, human browser sign-in, fresh
allowance in its actual UI and comparison with the same provider account.
See [ADR 0012](adr/0012-codex-live-test-profile.md).
