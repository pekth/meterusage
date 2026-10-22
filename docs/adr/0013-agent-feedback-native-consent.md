# ADR 0013: Agent bug drafts require native user consent

- Status: Accepted
- Date: 2026-10-10
- Extends: [ADR 0011](0011-login-free-linear-reports.md)

Agents use the existing MeterUsage executable to draft a short bug report from
observed evidence. `report draft` reads structured JSON from stdin and assigns
a version-4 UUID. `report submit` requires that draft ID and opens a native,
read-only preview of the exact report and destination. Cancel is the default.
Only a user action on Send this report permits one request. There is no
confirmation flag, environment override, MCP server or editor dependency.

The client reuses schema 1 and the existing private Linear relay. It appends
only the existing allowlisted diagnostics builder's app and system metadata.
The CLI does not poll providers, read transcripts, scan arbitrary files or
inspect saved account state. Provider and history observations are unknown.

Input has fixed fields and byte limits. Common private-data patterns and
control characters are rejected. This validation cannot identify every secret
or personal fact in prose. The agent must omit them and the user must review
all text before consent. The native preview never interprets Markdown or links.

Each explicit retry requires another native consent and reuses the same UUID
and report bytes. A matching receipt ends the operation. Cancel after an
uncertain send returns unconfirmed, because cancellation cannot undo delivery.
Keep the original draft for a later retry. Changed content or environment with
the same UUID can fail the relay's exact-content reconciliation; do not replace
an uncertain ID automatically.

The process retains no draft on disk. There is no automatic submission or
background retry. The existing Settings diagnostics flow stays separate.
Deployment, release and live reporting remain separate authorization gates.
