# Privacy and security design

MeterUsage reads quota and usage from existing local provider stores, provider
CLIs and aggregate endpoints. It has no telemetry service, analytics or
automatic crash-upload endpoint. Electron Diagnostics has an explicit optional
**Send report** action described below. The Electron candidate adds opt-in account connections;
Codex sign-in occurs in the provider browser page, not a MeterUsage password form. The optional API billing page accepts a one-time organization Admin key as
described below. MeterUsage does not send prompts, code or tool payloads to a provider.

The published Swift app retains the existing local/CLI boundaries. The
TypeScript/Electron candidate adds the opt-in boundaries described below. The candidate has source/fixture checks, but native behavior and
cutover acceptance remain pending. See [ADR 0010](adr/0010-macos-typescript-electron.md).

The Windows candidate stores preferences, provider history and sanitized API
billing snapshots under `%APPDATA%\MeterUsage`, normally the user's
`AppData\Roaming\MeterUsage`. It follows the redirected `%APPDATA%` location
when set. Windows uses the user's AppData access controls; it does not read
macOS UserDefaults or Keychain items. OpenAI and Anthropic billing accept a
one-time key in Settings, held in memory for that request. Windows has no saved
Keychain-key import. The compact tray is fixed on Windows, PNG sharing uses the
Save dialog, and automatic update installation is unavailable.

## Provider inputs and requests

| Provider | Read or request | Retained data |
| --- | --- | --- |
| Codex | `codex app-server --listen stdio://` initializes the CLI and calls `account/rateLimits/read`. The CLI uses its own existing authentication. Local rollout headers, model context and cumulative token-ledger events are selected from `sessions/**/*.jsonl`. | Quota windows/groups, plan, balances, reset credits, timestamps, numeric tokens and model. Session paths become opaque IDs; workspace directories become basenames. |
| Claude | Local transcript usage fields under `projects/`, three tier keys from `.claude.json`, and optional companion quota JSON. | Numeric tokens/cost estimates, model, dates, project basename, plan tier and quota windows. Transcript message content and identifying tier metadata are skipped. |
| OpenRouter | Existing `OPENROUTER_API_KEY` or supported local key file for `/api/v1/key` and `/api/v1/credits`. An existing management key, with configured API-key fallback, is used for `/api/v1/activity`. | Aggregate usage, balances, limits, dates, request counts and token totals. |
| OpenCode Go | Existing `opencode-go` key in the local auth store for `https://opencode.ai/zen/go/v1/usage`. Read-only session SQL, with `opencode db --format json` fallback, selects tokens, cost, message counts, dates and directory. | Quota windows, numeric usage and project basename. No message bodies, prompts or tool arguments are selected. |
| Grok | Existing OIDC key from `.grok/auth.json`, re-read for each billing refresh, sent to `cli-chat-proxy.grok.com/v1/billing?format=credits`. Session `summary.json` files supply dates and message counts. | Allowance, period/reset, plan and session/count metadata. No chat-history content is decoded. |
| Antigravity | Existing agy container CLI `/usage`; numeric fields from conversation SQLite/protobuf stores, native first and container-volume fallback. Older stores use only history conversation ID/timestamp fields. | Model-group quota, numeric token totals, turn times and aggregate counts. Older history has unknown tokens. No prompt/tool payload or workspace text is decoded. |
| Cursor, Copilot, Gemini | Existing local quota/usage JSON candidates and local presence checks. | Snapshot quota windows when present. These readers do not fetch cloud quota or provide a token ledger. Presence alone never becomes a zero-usage reading. |

Codex and Claude additional accounts use separate user-selected configuration
directories. Enabled existing directories get distinct sources; an absent or
disabled directory is not polled. An additional Claude source never falls back
to the primary account's plan or companion file. Codex subprocesses receive the
selected `CODEX_HOME`; MeterUsage does not open Codex `auth.json`.

Primary Claude quota checks `Library/Application Support/MeterUsage/claude-usage.json`
before its two `.claude` companion files. The selected file's modification time
supplies capture age when the payload omits `updated_at`; polling does not make
an old reading fresh.

The published Swift app does not open Claude `.credentials.json` or macOS
Keychain items. The Electron candidate still skips `.credentials.json`, but
explicit Claude Desktop connection permits one fixed Keychain read and
read-only cache/cookie access. See the opt-in connection section below.
Grok, OpenCode Go and OpenRouter are explicit existing-key readers. Keys stay
in main-process memory and request headers; they are not displayed, logged,
written to cache or sent to the renderer. Antigravity and Codex CLIs manage
their own authentication.

Antigravity runtime recovery may start only an already-existing
`podman-machine-default` after inspection. It does not create a machine or pull
an image. A healthy runtime is not restarted to repair internet or auth errors.
SQLite usage reads are read-only. Antigravity copies the database and WAL to an
owned temporary directory for a coherent read, then removes that copy.

## Opt-in candidate account connections

The candidate offers connection buttons in setup and Settings. No terminal,
folder picker or credential copying is part of the primary connection flow.
Existing local account directories remain an advanced option.

Setup also offers the existing CLI sources through an explicit **Use CLI**
action. Selecting an option alone performs no account access. Applying CLI
selection disconnects only MeterUsage-owned account state and waits for its
logout cleanup before enabling local collection. Cleanup failure prevents the
switch. Ordinary Disconnect never silently falls back to local data. The
CLI transition adds no credential store, provider endpoint or authentication flow;
CLI sources retain the input and coverage limits above. The separately consented
Grok Bot Desktop Beta account option is described below.

Codex browser sign-in uses the official app-server helper discovered in an
existing Codex app, with existing command installations as a compatibility path.
MeterUsage creates a separate generated profile under its own support directory
and checks effective `cli_auth_credentials_store=keyring` before login or
polling. Any other mode is refused. It never opens the user's Codex `auth.json`.
Login opens only an approved HTTPS OpenAI host and uses the helper's local
callback. Requests are initialization, effective config read, account login,
rate-limit read, account daily-token read, explicitly confirmed reset redemption and own-profile logout. No model session or prompt is started.
The provider helper handles tokens in OS storage; no plaintext fallback is
permitted. Cancelling login attempts own-profile logout and reports cleanup
failure. Disconnect does not sign out the user's Codex desktop session.
Unfinished sign-in profiles are retained only for cleanup and cannot enable
collection. Cancellation and disconnect disable collection before logout.
GUI startup and explicit sign-in retry recover owned-profile cleanup before
starting another login. Normal quit gives authentication helpers up to five
seconds, then cancels them. Pending CLI-selection preference saves and rollback
must settle before the app exits. Headless reports
do not sign in or perform cleanup logout.

Connected Codex daily history uses `account/usage/read` without `threadId`
through that same managed ChatGPT profile and keyring guard. The main process
projects only valid unique date labels, safe nonnegative integer token counts
and a capture timestamp before publication. Summary fields, unknown fields and
provider error text are discarded. No raw response, account identifier or
credential reaches the renderer or a new durable cache. Account token history
stays in memory, clears after failed reads, replacement or disconnect, and never
enters local rollups or durable daily history. Captured-profile and cancellation
checks reject late results. Missing history and unreported dates remain
unavailable. The provider contract does not establish complete product, device
or cloud coverage. See [ADR 0022](adr/0022-codex-account-token-history.md).

Claude requires an explicit explanation and consent before access. A connection
call without a consent callback denies access. The bundled
native helper reads only the `Claude Safe Storage` / `Claude Key` item. Background
reads disable interaction. Its stdout goes only to the main-process bounded
transport; do not run the helper interactively or record its output. The main
process decrypts `oauth:tokenCacheV2` from Claude Desktop's `config.json` and
reads only the active organization cookie from a read-only cookie database.
It selects account-scoped current access-token/expiry fields, skips refresh
tokens, and rejects ambiguous, legacy or expired entries. It never writes to
Claude stores or rotates their tokens.

The access token authenticates a GET to
`https://api.anthropic.com/api/oauth/usage` with the OAuth beta header and
MeterUsage's own User-Agent. The candidate requests no reset grants, uses no
CLI impersonation and starts no inference. This compatibility endpoint is not
an established third-party consumer API contract and may become unavailable.
Only numeric quota percentages, reset times and known window labels reach the
renderer or quota archive. The account/organization fingerprint is stored only
as an opaque hash in preferences, excluded from settings publication. It is
checked before and after HTTP. Identity changes invalidate the observation.
HTTP failures also require a fresh identity check before dated allowance can
remain. Local credential and permission failures clear that allowance.
Collection timeout also clears account-bound allowance when the identity check
may not have completed. Disconnect removes consent metadata and prevents the
post-request credential reread without changing Claude Desktop.

An explicit **Connect Antigravity Desktop** action permits discovery of one
same-user desktop language server and reading only its candidate process
arguments for the current CSRF credential. Multiple matching servers are
rejected. MeterUsage verifies PID-owned IPv4 loopback listeners before each
fixed `GetUserStatus` or `RetrieveUserQuotaSummary` request. HTTPS is preferred;
a certificate exemption applies only to that request to `127.0.0.1`. HTTP is
allowed only on the declared, PID-owned extension-server port. Redirects are
rejected, responses are limited to 1 MiB, each request to three seconds and
collection to fifteen seconds. No cloud credential file is opened or copied.

The Antigravity account email is checked before and after quota collection.
Only a provider-scoped SHA-256 fingerprint is saved in MeterUsage preferences,
excluded from settings publication and diagnostics. CSRF credentials and raw
responses stay in main-process memory and are not logged, cached or persisted.
No provider store is changed and no credential is refreshed. Connection
changes, cancellation and disconnect invalidate old reads. Missing or expired
quota stays unavailable. Empty modern summaries cannot select stale legacy
quota; legacy model fractions are allowed only for an explicitly unsupported
modern RPC. See [ADR 0026](adr/0026-antigravity-desktop-local-quota.md).

Connected Codex/Claude/Antigravity sources do not attach local CLI activity to
the connected account. Quota archives are cleared on connection changes and candidate launch;
authentication or absent-data failures clear the connected archive. Tokens,
passwords, raw caches, plaintext account identifiers and responses are not logged or
persisted by MeterUsage. In-memory strings remain subject to garbage collection.
Demo mode blocks live connection code before helper or key discovery.
[ADR 0011](adr/0011-desktop-account-connections.md) amends the Codex/Claude
candidate boundary; it does not change the published Swift release.

Grok Bot Desktop offers the primary opt-in **Connect Grok Bot Desktop (Beta)**
flow under [ADR 0028](adr/0028-grok-bot-desktop-reader.md). After consent, the main
process opens only the fixed `Grok Bot/sand-secrets.json` store under Application
Support and the helper's fixed `Grok Bot Safe Storage` / `Grok Bot Key` Keychain item.
Only explicit Connect permits Keychain UI; polling forbids it. The bounded JSON
reader rejects symlinks, duplicate keys, unsupported versions and changed stores.
It selects only the active account's encrypted access token and optional team;
refresh tokens and other accounts' credential values remain skipped. Plaintext and unsupported encryption are rejected. Canonical encrypted v10
legacy values use the same full JWT-subject hash binding as scoped values. Decrypted byte buffers are cleared
when projected; in-memory strings remain subject to garbage collection.

The full JWT subject hash must match the active account and any present envelope scope,
and expiry must exceed sixty seconds. The optional team must be a safe
nonnegative integer. Both account and team bind the stored opaque fingerprint.
Connect JSON POST `{}` goes only to
`https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` with a
bearer token, optional `x-cursor-team-id` and MeterUsage's own User-Agent. No Bot
machine identity, client impersonation, app-code invocation, token refresh or
inference is used. Redirects are refused; response and request bounds are 1 MiB
and thirty seconds. Account, team and store stability are checked after every
attempt while consent remains valid. Cancellation prevents further private reads.
Only projected quota and a reported reset reach the renderer/archive. Pooled
enterprise allowance and contradictory limit flags stay unavailable; trial expiry
is never treated as a reset. Native metadata confirms the encrypted legacy store format and fixed Keychain
label. Successful access and server acceptance remain unverified. MeterUsage does not
initiate an xAI OAuth flow or modify Bot's account state.

Previously saved Grok Bot connections via Cursor retain the legacy reader under
[ADR 0027](adr/0027-grok-cursor-closed-reader.md). New connections always select
Bot Desktop; no failed Bot request falls back to Cursor. Sign in to Cursor, check
allowance, then quit Cursor before polling a saved legacy connection.
Pre/post process and filesystem guards reject
active Cursor, unavailable or ambiguous evidence, nonempty WAL/journal files
and observed changes. These snapshots detect races; they do not exclude other
processes or prove Cursor never ran. The original SQLite database is opened
with `immutable=1&mode=ro`, which disables reader writes, locking and sidecar
bookkeeping regardless of other processes. No credential stores are copied to
temporary files. Read access times are controlled by the filesystem.

The main process selects only `ItemTable`'s `cursorAuth/accessToken`, requires
JWT expiry beyond 60 seconds, constructs the established
`WorkosCursorSessionToken` cookie, verifies the exact subject through fixed
`https://cursor.com/api/auth/me`, then sends POST `{}` to fixed
`https://cursor.com/api/dashboard/get-sand-usage-status` with
`Origin: https://cursor.com`. Redirects are refused; each request has a
30-second timeout and 1 MiB response cap. Token strings stay in memory and
request headers. They are never rendered, logged or persisted. No refresh or
model requests occur. Only an opaque account fingerprint/source preference and
projected aggregate quota persist; store fingerprints stay in memory.

The account and store are checked before allowance and after each attempt.
Cancellation or disconnect prevents further credential reads and rejects late
results. Revoked access, missing quota and expiry clear account-bound archives;
ordinary transport failures can retain dated quota only after account/store
verification. After expiry, reopen Cursor and quit it to resume the saved source.
Disconnect and connect again to switch to Bot Desktop. No local CLI
history is attached. Trial expiry is not a replenishment timestamp. Universal
Grok Desktop, X and shared-pool coverage is unverified, as are native/live
compatibility and packaged acceptance. See [setup](DESKTOP-CONNECTIONS.md).

## Optional API billing snapshots

OpenAI API and Anthropic API billing use separate normalized snapshots under
`Library/Application Support/MeterUsage/api-usage` on macOS and
`%APPDATA%\MeterUsage\api-usage` on Windows. The optional bundled helper
reads the selected organization Admin key from its environment for one fetch,
removes that key from its own environment and calls only the documented
OpenAI `/v1/organization/costs` or Anthropic `/v1/organizations/cost_report`
HTTPS endpoint. The Settings → API connections page also accepts a one-time
Admin key in a masked field. An explicit Fetch billing action passes it through
the registered Settings bridge to the main process, using the same collector.
The field clears on submit; leaving the page clears unsubmitted input. Keys are
not saved in preferences, Keychain, snapshots, diagnostics or renderer state
publications. An explicit **Use saved key** action instead reads the selected
provider's existing `com.meterusage.api-keys` generic-password item, account
`openAI` or `anthropic`, through the fixed native helper. Only that action may
request Keychain UI. The original item is not changed or deleted; the key stays
in main-process/helper memory and never reaches the renderer. Missing, denied
and ambiguous requests do not fall back to another credential. Startup and
polling never read these Keychain items. Fixed errors exclude key values and provider response bodies.
Only one request per provider may run; quit cancels pending fetches. Requests
reject redirects, cap response size and pagination, and never start inference.

The helper writes only schema/provider, capture/period timestamps, currency and
daily USD totals. Identifiers, headers and raw responses/errors are discarded.
On macOS, files and their final directory are owner-only. On Windows, files
inherit the user's AppData access controls. Replacement is atomic and a failed
request preserves the previous file. The app validates the fixed files
and publishes only projected fields. Demo and isolated provider tests never
read live API billing files. Demo, candidate and isolated profiles cannot use
the Settings fetch action. Polling rereads snapshots and never fetches billing.
Reports older than 24 hours or from a prior UTC month are marked stale.
Anthropic Priority Tier costs are excluded. See [setup](API_USAGE_BETA.md) and
[ADR 0029](adr/0029-api-billing-snapshots.md) and
[ADR 0032](adr/0032-one-time-api-setup.md).

## Selective parsing and display boundary

The Swift readers use narrow decoding structs. The TypeScript candidate uses
`src/main/select-json.ts` to traverse JSON syntax and materialize only selected
fields. It does not `JSON.parse` a whole Claude transcript or tier object and
then project fields. Tests cover unknown nested values, escaped strings and
keys, malformed input and scalar-materialization tracing. The scanner still
reads file bytes to skip unwanted values; it does not turn skipped prompt or
identifying values into application objects.

Absolute project paths are transient input to basename reduction. A claim that
workspace paths are never decoded would be inaccurate. The app retains project
names for attribution, opaque local session IDs for list/cache identity, and
provider-reported model names. These values may appear in screenshots. Keep
public screenshots in demo mode.

Managed accounts have app-generated IDs, user labels, paths and enable state.
Generated IDs key history/archive state; renaming a label does not change the
key. The JSON report includes a label only for additional accounts, with no
provider account identity or config path. Settings may show a reduced label for
the directory the user selected. Diagnostics use fixed provider/error codes
and additional-account markers, without raw paths, labels, payloads or keys.

Provider files, credentials, transports and raw responses stay in the Electron
main process. Renderer windows have no Node integration and use context
isolation and sandboxing. A narrow preload exposes named requests and sanitized
state; main checks the registered window, main frame, exact loaded document and
request fields. Navigation/new-window restrictions keep that bridge attached to
app documents. Source controls and tests do not replace native runtime proof.

## What leaves the machine

- Provider aggregate requests above, authenticated with existing provider keys
  or by the provider CLI. They contain no prompts or model-generation requests.
- Public unauthenticated status feeds at
  `https://status.openai.com/api/v2/components.json` and
  `https://status.claude.com/api/v2/components.json`.
- An explicit service-status button opens the provider's existing public status
  page in the default browser. Main selects a fixed Codex, Claude, Cursor or
  Copilot URL; the renderer cannot supply a destination. No usage or account
  data is added to that URL.
- An unauthenticated GitHub latest-release check, at most hourly while enabled.
  It has no usage data or account identifier. GitHub sees the network address
  and User-Agent. Disable it in Settings. An explicit Install action downloads
  the selected release ZIP and requires its SHA-256, bundle identity/version
  and code signature to verify. Automatic checks do not install an update.
- Explicit Codex reset redemption calls
  `account/rateLimitResetCredit/consume` after native user confirmation for that
  account and credit. Cancel makes no consume call. Tests use synthetic credits
  and never consume live credits.
- An explicit Share card action sends the captured card through the chosen
  native sharing service. Those services have their own privacy behavior.

Local usage file reads and SQL do not add an outbound request. Errors from
provider subprocess stderr are drained and not retained or forwarded.

## Local persistence

Daily history and quota archive remain JSON under the app's existing support
directory. History reads and writes project only known record fields and the
five numeric token counters before coordinator merge or renderer publication;
unknown JSON fields are discarded. History retains numeric daily summaries; the archive retains quota,
plan/credit/reset metadata and observation timestamps for reset-aware pacing.
Restored quota is shown as dated last-known data. Unreadable durable history is
preserved and further history writes are suspended until repair and relaunch.
Disposable scan caches store selected numeric results under opaque keys.

The Electron candidate retains temporary card images in the app support
directory until normal quit, so a selected sharing service can read the file
after its menu closes. A crash can leave those images on disk.

Preferences retain the existing macOS domain and known keys. Managed accounts
remain UserDefaults Data containing JSON. Dates and booleans keep their native
types. The Electron adapter reads/writes only known keys, without a new storage
migration. Native Swift-to-Electron-to-Swift round-trip proof is still required.

Demo selects synthetic sources before composition and isolates preferences,
history, caches and Electron state. The `--candidate-profile` option requires
`--demo` and an empty test directory on first use. Demo blocks live provider/key
discovery, update installation and login-item changes. It does write its own
isolated files. Candidate QA must leave the installed app and provider data
untouched.

The separate `--codex-test-profile` mode uses the real UI and opt-in Codex
connection with isolated JSON preferences, app data and Electron state. It
retains the OS home for Keychain and helper discovery. It excludes all other
provider sources, local activity and Claude status. Its only status request is
an unauthenticated GET to the public OpenAI status feed above. It blocks updates,
login-item changes and notifications. Explicitly confirmed Codex reset redemption
uses the same captured keyring-only connection profile and a fresh eligibility
check. [ADR 0017](adr/0017-connected-codex-menu-reset.md) supersedes only ADR 0012's
reset prohibition. Its Codex credential boundary is the same keyring-only boundary
described above.

`--claude-test-profile` uses a separate profile marker and the existing Claude
consent and allowance flow. It starts without consent and collects only Claude
account allowance. It cannot use a Codex or demo profile. JSON preferences and
Electron state remain isolated; OS home is retained for the read-only Desktop
reader. Codex access and cleanup, other providers, local activity, status feeds
and reset redemption are blocked. Candidate update, login-item and notification
guards apply. It adds no credential source, refresh flow or provider request.

## Installation and enforcement

`Scripts/make-app.sh` downloads a pinned public ZIP by default, checks SHA-256
and code signature, and copies/verifies replacement output in staging. Failure
preserves the previous generated app. It does not install an app or developer
tools. Source compilation requires `--build-from-source`. Electron candidate
packaging uses `--publish never` and does not replace that installation path.

Synthetic tests assert parser/privacy, account, history, schema and IPC
contracts. The repository pre-commit hook scans staged diffs for credential
shapes and personal paths; `.gitignore` excludes credential-shaped files and
live captures. These controls reduce accidental disclosure. They do not prove
provider authentication, live payload correctness or native UI behavior.

Cost figures are local estimates from the pricing table. A recorded zero is a
value; missing tokens or cost stay unknown. Provider dashboards remain the
billing source of record.

## Optional diagnostic reports

Only clicking **Send report** in live Settings submits a generated diagnostic
summary to the existing HTTPS support relay, which creates a private Linear
issue. There is no automatic upload or login requirement. The summary includes
the app version, mode, refresh interval/age, enabled provider names and bounded
status codes for quota, activity, usage, service status, plan and history/cache
failures. It excludes raw logs and errors, personal paths, account labels and
identifiers, credentials, usage contents, prompts and transcripts.

Main generates the summary; renderer requests cannot supply report text, IDs or
URLs. Reports have a random UUID for duplicate-safe retries. Pending summaries
and confirmed references remain in memory for the app session. A next-allowed
submission time is saved locally to enforce a 10-minute cooldown across app
relaunches. No report content or receipt is persisted. Requests omit
cookies and stored credentials, reject redirects, and enforce byte limits and a
timeout. The relay sees the network source IP for rate limiting; Cloudflare and
Linear process the submission. MeterUsage does not attach provider credentials.
See [REPORTING.md](REPORTING.md) for the delivery contract and proof limits.
