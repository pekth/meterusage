# Privacy and security design

MeterUsage reads quota and usage from existing local provider stores, provider
CLIs and aggregate endpoints. It has no sign-in form, telemetry service,
analytics or crash-upload endpoint. It does not ask for credentials or send
prompts, code or tool payloads to a provider.

The published Swift app and TypeScript/Electron candidate share these data
boundaries. The candidate has source/fixture checks, but native behavior and
cutover acceptance remain pending. See [ADR 0010](adr/0010-macos-typescript-electron.md).

## Provider inputs and requests

| Provider | Read or request | Retained data |
| --- | --- | --- |
| Codex | `codex app-server --stdio` initializes the CLI and calls `account/rateLimits/read`. The CLI uses its own existing authentication. Local rollout headers, model context and cumulative token-ledger events are selected from `sessions/**/*.jsonl`. | Quota windows/groups, plan, balances, reset credits, timestamps, numeric tokens and model. Session paths become opaque IDs; workspace directories become basenames. |
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

MeterUsage does not open Claude `.credentials.json` or macOS Keychain items.
Grok, OpenCode Go and OpenRouter are explicit existing-key readers. Keys stay
in main-process memory and request headers; they are not displayed, logged,
written to cache or sent to the renderer. Antigravity and Codex CLIs manage
their own authentication.

Antigravity runtime recovery may start only an already-existing
`podman-machine-default` after inspection. It does not create a machine or pull
an image. A healthy runtime is not restarted to repair internet or auth errors.
SQLite usage reads are read-only. Antigravity copies the database and WAL to an
owned temporary directory for a coherent read, then removes that copy.

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
directory. History retains numeric daily summaries; the archive retains quota,
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
history, caches and Electron state. An explicit candidate profile requires
`--demo` and an empty test directory on first use. Demo blocks live provider/key
discovery, update installation and login-item changes. It does write its own
isolated files. Candidate QA must leave the installed app and provider data
untouched.

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
