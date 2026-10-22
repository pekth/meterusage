# Desktop login and shared allowance research

Checked against official documentation on 2026-10-15. This is research, not a
claim that these connections are implemented or live-tested in MeterUsage.

| Provider | Documented account route | MeterUsage consequence |
| --- | --- | --- |
| Grok / The X Subscription | Eligible Cursor, Grok and X accounts can be unified. Each paid seat has a weekly pool across eligible first-party Grok and Cursor surfaces. | Label the current Grok integration **Beta**. A shared-pool reader needs verified account, workspace and seat scope. |
| Antigravity | Desktop, CLI and IDE extensions use unified local authentication. The CLI can reuse a valid OS-keyring token profile without browser sign-in. | Prefer a provider-owned local helper over implementing Google OAuth or extracting tokens. Current MeterUsage quota collection still uses its existing container path. |
| OpenCode Go | Console subscription supplies an API key; OpenCode connects it as the `opencode-go` provider. | Reuse an already configured Go key from the existing OpenCode auth store. No separate Go desktop OAuth flow was documented in the reviewed sources. |

## Grok and Cursor

The official name is **The X Subscription**. The overview was updated on
October 12, 2026. Grok and Cursor share eligible first-party weekly usage for
one paid seat. Team seats do not share weekly pools; the team shares prepaid
Additional Usage credit. Third-party model usage is billed separately. Account
unification is a permanent provider action, so MeterUsage must not perform it.

Cursor's usage guide says its editor settings display the same remaining usage
as the Grok dashboard. That establishes a desktop display, not a public
third-party quota interface. The reviewed Cursor API overview lists usage and
analytics APIs for Enterprise teams using API keys. It does not establish an
individual subscription quota API authenticated by the desktop session.

Recommendation: investigate an explicit read-only Cursor account connection,
with verified weekly reset, workspace/seat scope and account-change handling.
Represent a confirmed shared pool once, with Grok and Cursor attribution, so
it is not added twice to totals. Keep legacy Cursor and Grok CLI readings
separate. Do not advertise this connection until its data contract is verified.

Sources:

- [Subscription overview](https://docs.x.ai/x-subscription/overview)
- [Usage limits and per-seat pools](https://docs.x.ai/x-subscription/usage-limits)
- [Account unification](https://docs.x.ai/x-subscription/unify-accounts)
- [Cursor usage and editor display](https://cursor.com/help/models-and-usage/usage-limits)
- [Cursor API availability and authentication](https://cursor.com/docs/api)

## Antigravity

The official Authenticate guide says signing in on one local surface shares
credentials across the local environment. The CLI attempts silent sign-in
through the native secure keyring. The documented `/usage` command refreshes
model configuration and quotas from the backend and opens a TUI panel. Plans
also document baseline quota visibility in desktop Settings. These establish
shared sign-in and a quota surface, not a stable desktop quota API or a
machine-readable output contract.

MeterUsage currently launches the existing authenticated container for quota.
A desktop sign-in does not prove that container shares the host keyring. A
native provider-owned helper or documented read-only interface needs separate
discovery, compatibility checks and synthetic/live acceptance before replacing
that path. Do not log out, refresh credentials, inspect secret values or issue
model prompts merely to discover quota.

Sources:

- [Quickstart and desktop installation](https://antigravity.google/docs/getting-started/)
- [Authentication and local keyring reuse](https://antigravity.google/docs/install/)
- [IDE unified authentication](https://antigravity.google/docs/ide/extensions/)
- [Model quota command](https://antigravity.google/docs/cli/commands/usage/)
- [Plans and desktop quota display](https://antigravity.google/docs/plans/)

## OpenCode Go

The Go guide and provider setup describe Console sign-in, subscription, and
an API key. OpenCode's provider documentation locates saved credentials at
`~/.local/share/opencode/auth.json`. MeterUsage already selects only the
`opencode-go` key there for quota requests. Its local token history is a
separate read-only database source, not a substitute for cloud allowance.

Recommendation: offer setup guidance to connect Go in OpenCode, then detect
the existing configured Go source. A desktop app installation alone is not
a connected Go subscription. The reviewed Go guide restricts Go workspaces
to one member. It does not document consumer OAuth access for MeterUsage.
The current Go documentation also differs from older endpoint and plan
descriptions; validate those separately before changing provider requests.

Sources:

- [OpenCode Go](https://opencode.ai/v2/docs/console/go/)
- [Provider credentials and Go setup](https://opencode.ai/docs/providers/#opencode-go)
- [OpenCode desktop availability](https://opencode.ai/)
