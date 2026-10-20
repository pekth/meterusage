# CLIProxyAPI Hub connection

Status: Research complete; implementation needs an existing saved-history source.

## Goal and source contract

Connect MeterUsage to an existing CLIProxyAPI history source and show retained
token activity grouped by provider and upstream account. Keep proxy activity
separate from local transcripts and subscription allowance to avoid double
counting or assigning activity to an unrelated account.

CLIProxyAPI 8.0.35 exposes a usage queue that removes records when read. It does
not expose the legacy historical snapshot endpoints. This integration must not
consume that queue, change proxy configuration, or install a new collector.
A saved export or a documented history service must be identified first.

Sources: [v8 usage contract](https://help.router-for.me/management/apiv8#usage),
[v8.0.35 routes](https://github.com/router-for-me/CLIProxyAPI/blob/ae3ee3be303fb07fb8173279923413005bf32177/internal/api/server_management_v8.go),
[legacy snapshot format](https://github.com/router-for-me/CLIProxyAPI/blob/db63f9b5d60e643ca060901cfe67ffc5ce63ac63/internal/api/handlers/management/usage.go).

## Proposed minimum

1. Verify the saved source's format, retention and non-destructive read contract.
   Do not advertise complete history where coverage is unknown.
2. Add one explicit Hub connection in Settings. For an authenticated HTTP source,
   keep its management key in main-process memory and OS-backed encrypted
   storage; fail closed without secure storage. Reject redirects and credentials
   embedded in URLs. Source details must precede transport implementation.
3. Read one bounded snapshot per refresh. Join reported `auth_index` values to
   projected provider metadata where the source supplies that mapping. Keep
   unknown or ambiguous identities in an unattributed group; model aliases are
   not evidence of a subscription account.
4. Publish only numeric usage, dates and reduced display labels. Never publish
   client API keys, credential files, email addresses, raw errors or headers.
   Request counts must remain requests rather than sessions or messages.
5. Reuse the account heatmap's unavailable-day handling. Use reported total
   tokens when component counters can overlap. Replace snapshots rather than
   adding repeated cumulative totals. Do not merge Hub and local token totals.

## Verification and limits

Synthetic checks must cover authentication failures, cancellation, source
replacement, payload limits, identity ambiguity, missing dates, snapshot reset,
overlapping token categories and repeated polling. Renderer checks must verify
provider/account labels, unavailable history and separate local/Hub scope.
Native secure storage and the actual history source need independent execution
proof before runtime support is claimed.

No Hub adapter or credential store is implemented by this plan. The existing
local Claude heatmap and Desktop allowance remain separate data sources. No
server deployment, queue consumer, provider login or app installation follows
from this plan.
