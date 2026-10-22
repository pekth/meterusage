# ADR 0015: Read public Codex status in the isolated test profile

- Status: Accepted implementation direction; native acceptance pending
- Date: 2026-10-10
- Amends: ADR 0012, public status collection only

## Decision

The isolated Codex test profile reads the existing public OpenAI component
status feed without account credentials. Attach that reader to its existing
Codex source. Keep normal collection limited to the existing Codex and Claude
status readers.

The Service status panel distinguishes an initial check, an unavailable feed
and a failed refresh with dated last-known status. A failed request does not
become an operational result. Public service status does not prove account
allowance, sign-in health or provider-dashboard accuracy.

Preserve ADR 0012 as the original decision. This amendment does not enable
other provider sources, Claude status in the Codex test profile, local scans,
reset redemption, model requests, updates, login-item changes or notifications.
The installed app and saved provider credentials remain outside this change.

## Acceptance

Synthetic tests cover source selection, unauthenticated requests, refresh and
failure display. Public HTTP responses establish feed availability only.
Packaged macOS display and refresh behavior require separate native proof.
