# ADR-0001: Repository-owned project knowledge

- Status: Accepted
- Date: 2026-08-25

## Decision

Project knowledge lives beside the project in `docs/KB.md`. Project decisions live in `docs/adr/`. Agents maintain those files in the same change that makes a relevant project change. The repository does not use scheduled automation to maintain this knowledge. Public documentation must exclude credentials, personal data, private agent or orchestration instructions, private repository references, and local absolute paths.

## Context

Repository-local documentation is available with the source and can be reviewed with the change it describes. A public repository needs a safe boundary around local provider and account details. Scheduled maintenance would add workflow scope and could expose stale or private material.

## Consequences

- A relevant change must update the affected knowledge or decision document in the same agent change.
- `docs/KB.md` must separate public repository evidence from local runtime and provider state that was not verified.
- Reviewers can inspect source, documentation, and the knowledge update together.
- No scheduled GitHub workflow is required for knowledge maintenance.
