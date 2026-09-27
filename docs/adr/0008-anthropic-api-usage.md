# ADR 0008: Anthropic API usage is an opt-in organization monitor

- Status: Accepted
- Date: 2026-09-27

Use the existing `UsageSource` and API usage card for an `anthropic` provider,
separate from Claude Code activity and subscription quota. As in ADR 0007,
organization totals can overlap local activity. Exclude them from local coding
totals and burn attribution. Do not infer a budget, quota, or reset time.

Read only `ANTHROPIC_ADMIN_KEY` from the process environment. Use it for GET
requests to `api.anthropic.com/v1/organizations/usage_report/messages` and
`api.anthropic.com/v1/organizations/cost_report`, with the documented API
version header. Reuse the ephemeral session that rejects redirects. Do not
read Claude Code credentials, save the key, or decode account identity.

Fetch today and the previous 29 UTC days. Bound pagination and treat incomplete
responses as unavailable. Count uncached input, output, cache reads, and both
cache-creation durations. Convert decimal cents to USD and preserve cost
adjustments. The cost endpoint excludes Priority Tier charges; disclose that
limit in the card. Omit request counts because tool-use counts are not a total
number of model requests. Successful empty reports are measured zero.

The Admin APIs require a Console organization Admin key. Individual accounts,
regular workspace keys, and Claude subscription logins cannot supply this
reading. Both the provider toggle and the key are opt-in.

Source: [Anthropic Usage and Cost API guide](https://platform.claude.com/docs/en/manage-claude/usage-cost-api).
