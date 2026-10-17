# API billing snapshots

Current Electron source adds separate OpenAI API and Anthropic API billing cards.
The published beta1 does not contain them. OpenRouter keeps its existing account
balance, key limits and aggregate activity integration.

## What the cards report

OpenAI API and Anthropic API show provider-reported USD cost buckets for the
current UTC month through the helper request time. They are separate from Codex
and Claude subscriptions and from locally estimated token costs. Empty reports
remain unavailable; a provider-reported zero is displayed as zero. These cards
do not invent token counts, budgets or quota percentages.

The card shows the report period and exact snapshot time. A snapshot becomes
stale after 24 hours or a UTC-month change. A prior month's snapshot retains
its own period. Refresh rereads the file; it does not fetch billing or make an
old snapshot fresh. Anthropic's cost report excludes Priority Tier costs. Neither
provider's report replaces its dashboard or invoice.

## Set up the helper

The optional helper needs an existing organization Admin API key. A normal
project API key and a ChatGPT or Claude subscription sign-in do not grant this
access. In OpenAI Platform, create an Admin key under Organization settings →
Admin keys. In Anthropic Console, create an Admin key under Settings → Admin
keys. Keep these high-authority keys out of MeterUsage and chat.

In MeterUsage Settings, expand **Set up API billing snapshots**. Open Terminal
on your Mac, paste the matching command below, then paste the Admin key at the
hidden prompt and press Return. The commands use macOS zsh. The entered key is
not a command, so it does not enter shell history. The subshell supplies only the
selected environment variable to the helper and exits afterward. MeterUsage and
the parent shell do not store the entered key. Never put a key in command text,
a profile, a repository or chat.

OpenAI API:

```zsh
(
  IFS= read -rs 'OPENAI_ADMIN_KEY?Paste OpenAI Admin key (hidden): ' || exit 1
  print
  export OPENAI_ADMIN_KEY
  ELECTRON_RUN_AS_NODE=1 /Applications/MeterUsage.app/Contents/MacOS/meterusage \
    /Applications/MeterUsage.app/Contents/Resources/api-usage-helper.cjs openai
)
```

Anthropic API:

```zsh
(
  IFS= read -rs 'ANTHROPIC_ADMIN_KEY?Paste Anthropic Admin key (hidden): ' || exit 1
  print
  export ANTHROPIC_ADMIN_KEY
  ELECTRON_RUN_AS_NODE=1 /Applications/MeterUsage.app/Contents/MacOS/meterusage \
    /Applications/MeterUsage.app/Contents/Resources/api-usage-helper.cjs anthropic
)
```

After `API billing snapshot updated`, click **Refresh** in MeterUsage. An
`API billing authentication failed` result means the supplied key lacks access
or is invalid. `API billing data unavailable` means the helper could not obtain
a supported report; check the organization billing dashboard. A failed fetch
preserves the last snapshot. A missing helper environment produces the fixed
`API billing admin key missing from helper environment` result.

These commands contain no key. An existing trusted secret manager can instead
supply the selected environment variable directly to the one-run helper. The
helper removes that variable from its own environment before fetching. Source
contributors can use `node dist/api-helper/api-usage-helper.cjs openai` or
`anthropic` after building, with the same environment requirement.

The helper makes bounded HTTPS GET requests to the provider's documented cost
report, follows pagination, drops identifiers and writes one owner-readable
snapshot under `~/Library/Application Support/MeterUsage/api-usage/`:

- `openai.json` for OpenAI API
- `anthropic.json` for Anthropic API

Snapshots and their final directory use owner-only permissions. The reader
rejects unsafe paths, permissions, duplicate/malformed fields and unsupported
currency. Successful writes replace the file atomically. A failed collection
preserves the previous snapshot. The helper prints only a fixed success or
error category, including authentication failure. It has no scheduler or
background key storage. Rerun the matching helper command when you need a new
report, then refresh MeterUsage to reread the snapshot. Refresh does not contact
the billing API. Remove the provider's snapshot to stop displaying that billing
card. OpenRouter account activity and key limits continue to use its existing
integration.

## Data and credential boundary

Only the helper receives the environment key. MeterUsage reads only normalized
numeric snapshots. A snapshot contains schema/provider, capture and period
timestamps, USD currency, and daily start/end/amount values. It excludes raw
responses and organization, project, workspace, user and key identifiers.
Keys, authorization headers and provider error bodies are never written to
snapshots, diagnostics or the renderer.

Requests refuse redirects, share a 30-second deadline, bound each response to
1 MiB and stop after bounded or repeated pagination. OpenAI dollar amounts are
used as reported. Anthropic decimal cents are converted to USD. Non-USD amounts
stay unavailable; there is no currency conversion.

## Official contracts and proof limits

- [OpenAI organization costs](https://platform.openai.com/docs/api-reference/usage/costs)
  uses an organization Admin API key. The implementation follows the official
  OpenAI OpenAPI definition for `/organization/costs`.
- [Anthropic usage and cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)
  requires Admin API access and documents the Priority Tier exclusion.

Synthetic fixtures verify projection, units, pagination, privacy, freshness and
failure behavior. Real organization billing access and invoice reconciliation
remain unverified. No real Admin key is required for source tests.
