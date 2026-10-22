# Diagnostic reports

This page describes Electron. The retained Swift source has a separate
[reporting and native-consent CLI contract](swift/REPORTING.md), which is not
included in the published Swift 0.2.41 app.

In **Settings → Diagnostics**, choose **Send report** to submit a sanitized
status summary to private MeterUsage support in Linear. No account is required.
The button shows progress, then a confirmed reference. Copy diagnostics remains
available if delivery fails. This sends status diagnostics, not a raw log bundle.

The report includes the running app version, demo/live mode, refresh interval
and age, enabled provider names and status codes for quota, activity, usage,
service status, plan, history and archive failures. It excludes credentials,
account labels and identifiers, file paths, raw errors, prompts and transcripts.
See [privacy](PRIVACY.md#optional-diagnostic-reports).

## Delivery

Main generates a random UUID and the report snapshot after the user's click.
Renderer IPC accepts only the send action. The existing HTTPS relay receives
exactly `schema`, `id` and `diagnostics`; support credentials and issue routing
stay on the server. The summary is limited to 49,152 UTF-8 bytes and the JSON
body to 65,536 bytes. Requests omit cookies/credentials, reject redirects and
time out after 20 seconds. Replies are limited to 1,024 bytes. Success requires
HTTP201, the matching UUID and a valid support reference.

Repeated clicks while sending do nothing. An uncertain retry reuses the UUID
and snapshot for server-side reconciliation. A confirmed reference stays visible
through Settings navigation; further sends are disabled until app relaunch.
Each attempt also reserves a 10-minute cooldown before contacting the relay.
The next allowed time is saved as a private local preference, so app relaunch,
Settings navigation and failed requests do not reset it. The button stays
disabled until that time and shows when retry is available. Main enforces the
same gate even if a renderer sends another request. If saving the cooldown
fails, nothing is sent. Copy diagnostics remains available.

Only the cooldown time is persisted. Pending report content and receipts are
not saved to disk. Uncertain retries within the same app session keep the
report UUID and snapshot. No automatic retry runs after the cooldown expires.
Rate limits and unknown failures show fixed messages without server responses
or raw errors.

The legacy relay configuration sets 3 requests per IP per minute and 30 total
per minute before contacting Linear. These Cloudflare counters are local and
eventually consistent, not a strict worldwide cap. Client cooldown protects
against accidental repeated sends; it does not replace server enforcement.
The reviewed source configuration does not establish current deployed limits.

Mock transport tests cover requests, receipts, limits, retries and redaction.
They do not establish current relay deployment or delivery to Linear. A live
submission creates an external support issue and needs a deliberate user action.
