# ADR 0007: OpenAI API usage is an opt-in organization monitor

- Status: Accepted
- Date: 2026-09-27

OpenAI Platform API billing and Codex subscription limits describe separate
budgets. Add an `openAI` provider using `UsageSource`, with no `QuotaSource`.
Show its own popover card and Settings toggle. Do not infer a budget, credit
balance, percentage, or reset time from costs.

Read only `OPENAI_ADMIN_KEY` from the process environment, at each refresh.
Use it for GET requests to `api.openai.com/v1/organization/usage/completions`
and `api.openai.com/v1/organization/costs`. Use an ephemeral session, reject
redirects, and retain only numeric usage, USD amounts, and bucket timestamps.
Do not read Codex credentials, store the Admin key, or decode account identity.

Fetch today and the previous 29 UTC days. Follow pagination with a bounded
page count; incomplete pages or failed costs are unavailable, never zero spend.
Successful empty responses are measured zero. Costs cover the organization;
tokens and requests cover completions only. Preserve provider cost adjustments
and count cached input once.

Organization usage can overlap local CLI records and include other users.
Exclude it from the local coding strip and burn attribution. This narrows
ADR 0003's all-provider rule to exclude organization billing aggregates.
The existing quota JSON report and quota rings remain quota-only.

Source: [OpenAI Usage and Costs example](https://developers.openai.com/cookbook/examples/completions_usage_api).
