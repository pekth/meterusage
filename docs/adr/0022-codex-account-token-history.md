# ADR 0022: Read provider account token history separately

- Status: Accepted implementation direction; independent review, native and live acceptance pending
- Date: 2026-10-12

The Electron candidate reads daily token history through the existing managed
ChatGPT helper with `account/usage/read`. It omits `threadId`, which selects
account-wide activity instead of a thread estimate. Initialization, effective
keyring storage checks and the generated connection profile remain required.
This extends ADR 0011's read boundary without changing login, quota, reset or
own-profile logout behavior.

Use a separate in-memory account activity type containing only provider date
labels, safe nonnegative integer token counts and a capture timestamp. Discard
summary and unknown fields before publication. Reject invalid calendar dates,
duplicate dates, unsafe counts and malformed buckets. Preserve reported zero;
null, absent history and unreported dates remain unavailable.

The card says "Account token activity" and "Provider-reported account scope".
It shows a compact daily grid for 26 weeks ending at the latest reported date.
Hover and keyboard focus expose exact counts. Existing global and Codex heatmap
preferences control main, notch and shared cards. Keep provider dates unchanged
as calendar labels without assigning a timezone. Do not infer token categories,
sessions, cost or daily counts from summary statistics or allowance.

Account history never enters local Activity, Usage, burn attribution, durable
daily history or the schema-1 quota report. Replacement, disconnect and failed
reads clear the account reading; captured profile checks reject late results.
Reuse the existing collector deadline and bounded backoff. Add no durable
account cache, credential source, raw-response log or additional browser login.
Advanced local profile collection remains unchanged.

The public app-server contract describes ChatGPT account token activity. It
does not establish universal client, cloud, device or product coverage, token
category definitions, timezone, retention or polling limits. Live availability
and coverage need separate provider proof. Native notch anchor and shared-image
acceptance also remain open. This decision does not authorize a release.
