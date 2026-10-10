# Diagnostic reporting

Report issue sends app-generated diagnostics to a private Linear project
without requiring the reporter to sign in. Copy diagnostics stays available.
The relay is deployed on Workers Free. Source builds configure its `/report`
endpoint; the released v0.2.41 app does not include this feature.
Settings states that diagnostics are sent only on request; it does not promise
that all data stays local.

## Data and user flow

The entry state is Settings with provider readings already loaded or failed.
Clicking Report issue captures one diagnostic snapshot and starts one HTTPS
request. The button is disabled during submission. A matching confirmed Linear
issue reference changes it to Sent. Errors keep the report available for retry;
an uncertain retry reuses the original report ID and snapshot. The app
coordinator retains the pending report, send state and receipt when Settings
closes and reopens. A confirmed receipt keeps Send disabled for the rest of the
app session. Quitting the app clears this in-memory state; no report is saved
to disk. See [ADR 0012](adr/0012-report-state-outlives-settings.md).

The report includes app/build, numeric OS/architecture, provider states,
aggregate readings and freshness, cache/history state, and recent refresh
outcomes. It does not poll providers or run commands when reporting. Unknown
observations stay unknown; it cannot reconstruct earlier raw errors or crashes.
See [PRIVACY.md](PRIVACY.md) for excluded data and network metadata handling.

The request is `POST /report`, `Content-Type: application/json`:

```json
{"schema":1,"id":"68ff7a74-cd68-4f0b-b702-e5fe09a84bd5","diagnostics":"MeterUsage 0.2.41\nmode: demo"}
```

The JSON body is limited to 65,536 bytes and diagnostics to 49,152 UTF-8 bytes.
The app rejects oversized reports without truncating them. The relay accepts
only the declared fields. Team, project and issue title are server-controlled.
A confirmed response is HTTP 201 with `id` and `identifier`. The app reads
replies incrementally and cancels reception above 1,024 bytes. Oversized or
invalid replies show delivery as unconfirmed. Upstream error bodies are never
displayed to reporters.

Diagnostics use a fenced Markdown block because Linear converts indented
blocks to fences. The delimiter is longer than every backtick sequence in the
report. Receipt checks still require the exact description, UUID and destination.

## Free hosting and configuration

Use [Cloudflare Workers Free](https://developers.cloudflare.com/workers/platform/pricing/)
and its included workers.dev hostname. The published free allowance is 100,000
requests per day per account. Exceeding the allowance returns an error. It does
not buy an upgrade. The relay needs no database, object storage or queue.
Use the existing Linear workspace; this setup does not purchase Linear seats
or lift that workspace's own issue or API limits.

Before deployment, verify that the intended Cloudflare account is on Workers
Free. Do not silently deploy into a paid account or change its billing plan.
Deployment and secret configuration require the project owner's authorization.

Configure these server-side bindings:

- `LINEAR_API_KEY`: a secret restricted to the intended Linear team.
- `LINEAR_TEAM_ID`: the intended team UUID.
- `LINEAR_PROJECT_ID`: the existing MeterUsage project UUID in that team.
- `PER_IP` and `GLOBAL`: the rate-limit bindings in `Reporting/wrangler.jsonc`.

Keep credentials out of source, app bundles, command arguments, logs and files.
Use the hosting provider's secure secret-input mechanism. The app contains only
the public HTTPS endpoint under `MeterUsageReportURL` in `Resources/Info.plist`.
The source bundle sets it to
`https://meterusage-reports.fancy-queen-3301.workers.dev/report`.
Missing configuration returns an explicit unavailable state.

Limits allow three requests per minute per network address and 30 per minute
per Cloudflare location. Missing rate-limit bindings fail closed. These limits
reduce spam; they do not authenticate an anonymous sender or guarantee a
global ceiling. The Linear UUID prevents duplicate issue creation on a retry.

## Activation evidence

On 2026-10-08, the authenticated Cloudflare dashboard showed Workers Free
Active. A synthetic report sent by the unmodified Swift client reached the
MeterUsage Linear project. Repeating the identical request returned the same
issue reference; an independent Linear read confirmed one issue, its exact
diagnostic text and destination. No paid resource was added.

This proves native client delivery and retry against the deployed service.
It does not prove native Settings interaction or availability in a released app.

## Required verification

Run `node --test Reporting/worker.test.mjs` for the relay contract. Run
`swift build`, `swift test` and `Scripts/make-app.sh --build-from-source` on
macOS for the app candidate. Use synthetic inputs only.

Verify success, lost acknowledgement/retry, double-click, Settings navigation
during a send and after its result, offline failure,
throttling, oversized input, response cancellation before stream completion,
invalid receipts and redirects. Confirm excluded
data stays absent from diagnostics and that arbitrary provider labels cannot
enter the report. A mock server test does not prove deployed Linear delivery.

Before distribution, use the configured candidate to submit one synthetic
report. Read back the exact Linear issue and project, compare its diagnostic
content and report ID, then retry the same ID and verify only one issue exists.
Record the candidate digest, endpoint, issue reference and executed checks.
Check the actual Settings interaction on the native target. Source inspection
or a static rendered capture does not establish interactive UI behavior.

## Agent-facing bug feedback

Use the executable inside a configured MeterUsage app bundle. A bare SwiftPM
binary can draft, but cannot submit without the bundle's existing reporting
endpoint. This feature adds no endpoint override or client credential.

`meterusage report draft` reads JSON from stdin with exactly four string fields:

```json
{"description":"Synthetic external link does not open","steps":"Select the example external link","expected":"The browser opens","actual":"Nothing happens"}
```

It prints those fields plus a new `id`. Retain that JSON in the agent's current
context. Pass it unchanged on stdin to `meterusage report submit`. Neither
command reads a report file or saves a draft. Description is limited to 512
UTF-8 bytes; each other field to 2,048 bytes; total stdin to 8,192 bytes. Empty
fields, extra fields, non-v4 IDs, controls, paths, links, email addresses and
common credential patterns fail before preview or network access. A supplied
`confirmed` field is rejected.
The encoded draft including its ID and output newline must also fit the stdin
limit, so every successful draft can be passed unchanged to submit.

Submission opens a native scrollable preview with the exact report, report ID,
HTTPS relay and MeterUsage support's private Linear destination. Cancel is the
default button. Send this report grants consent for one request. CLI stdout
returns JSON containing `id`, `status`, and a verified `identifier` only on
success. Decline returns `declined` with no request. Delivery failures are
sanitized, and the user can cancel or explicitly retry the unchanged report.
Cancel after a failed acknowledgement returns `unconfirmed`, not unsent.
Unavailable configuration returns `unavailable`. Errors exit nonzero; a fresh
decline or confirmed receipt exits zero. No raw response body or URL error is
printed.

The appended diagnostics contain app and numeric system metadata only. No
provider is polled and no transcript, arbitrary file or account data is read.
The CLI marks provider/history observations unknown; it does not borrow state
from a running app. The short prose fields describe observed evidence, not raw
logs or conversations. Pattern validation cannot identify every private fact:
the agent must omit them and the real user must review the full preview.

Keep the same draft ID and text for an uncertain retry, including after process
exit. The relay reconciles exact UUID, content and destination. Changed app or
system metadata with the same ID can produce an unconfirmed result. Do not
mint a new ID automatically after a failure. A deliberate new draft is a new
report and requires new native consent. See [ADR 0013](adr/0013-agent-feedback-native-consent.md).

The external-link fixture is a synthetic UX example inspired by
[Ben Davis's post](https://x.com/davis7/status/2108756950641254490).
It does not establish that the reported Grok bug was reproduced or fixed.

Focused proof covers draft validation, exact native preview, cancel without a
request, explicit send through the existing client to an injected synthetic
transport, matching/mismatched receipts, sanitized failures and byte-identical
uncertain retries. Native tests operate on their own modal window and never
contact the deployed relay. Live delivery, installed-app behavior and release
availability require separate proof and authorization.
