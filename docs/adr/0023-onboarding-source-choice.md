# ADR 0023: Choose usage sources explicitly in onboarding

- Status: Accepted implementation direction; native interaction acceptance pending
- Date: 2026-10-13

Users need to choose between an existing CLI setup and the account connections
supported by each provider. Keep this choice in Settings alongside onboarding,
as required by ADR 0014.

Offer Codex browser sign-in or CLI, Claude Desktop or Claude Code CLI, and Grok
CLI only. Explain their data coverage. Do not offer unsupported consumer sign-in
or imply that local activity covers the website or another device. Changing the
selector alone has no account or collection effect. An explicit action applies
the choice, and Done follows the source choices.

Add one validated `connectionLocal` IPC action. This supersedes only the
no-new-IPC restriction in ADR 0014. Reuse existing connection preferences and
readers. Account-to-CLI switching ends only MeterUsage-owned connection state
and waits for successful cleanup before selecting local collection. Failure
stays closed. Ordinary Disconnect retains the `off` state and never silently
switches to local data. Existing accounts keep their source on upgrade.

Publish only the source name and whether CLI selection is available, without
account identifiers or profile paths. Reject local selection in demo and isolated
live test profiles. Preserve consent, cancellation, safe error handling, stale
result rejection and the save-before-close onboarding contract. No new credential
source, authentication protocol, provider request or dependency is introduced.

Verify supported options, explicit application, cleanup and preference-save
failures, concurrent actions, relaunch persistence and Done. Source and synthetic
browser checks do not prove live provider authentication or native interaction.
