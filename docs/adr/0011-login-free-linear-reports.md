# ADR 0011: Reports reach Linear without user login

- Status: Accepted; deployment and end-to-end delivery proof pending
- Date: 2026-10-07
- Supersedes: [ADR 0010](0010-user-triggered-github-diagnostics.md)

## Decision

Settings Report issue sends an allowlisted diagnostic summary to an HTTPS
relay, which creates a private Linear issue. The reporter needs no account.
Keep the Linear credential on the server. The app shows success only when the
relay returns the matching report ID and an issue reference.

Use Cloudflare Workers Free and a workers.dev address. Do not add paid plans,
databases, queues, domains or storage. Free-plan limits reject work instead of
creating overage charges. Verify the account plan before deployment.

The relay fixes the Linear team and project on the server, limits request size
and frequency, and uses the report UUID as the Linear issue UUID to prevent
duplicate creation on retry. Rate limits are approximate per Cloudflare
location; they are not a global accounting guarantee.

## Consequences

- A failed or unconfirmed send leaves Copy diagnostics available.
- Retrying an uncertain send reuses its ID and snapshot while the view is open.
- The diagnostic report contains typed state and aggregate values, never raw
  transcripts, credentials, account labels or paths.
- The report cannot recover errors from before the app started. Unknown data
  and bounded-history omissions remain explicit.
- A source build without a configured endpoint cannot send reports. Deployment
  and a verified synthetic Linear receipt are required before distribution.
- No release, deployment or paid-resource authority follows from this ADR.
