# Diagnostic reports

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
Pending reports and receipts are not saved to disk. Rate limits and unknown
failures show fixed messages without server responses or raw errors.

Mock transport tests cover requests, receipts, limits, retries and redaction.
They do not establish current relay deployment or delivery to Linear. A live
submission creates an external support issue and needs a deliberate user action.
