# ADR 0010: User-triggered diagnostics through GitHub issues

- Status: Superseded before implementation by [ADR 0011](0011-login-free-linear-reports.md)
- Date: 2026-10-07

The initial GitHub proposal was withdrawn because it required the reporter to
sign in. Its draft is retained as decision history; no GitHub report button
shipped from this proposal.

## Original decision

Settings Send logs prepares a new public issue in `pekth/meterusage` using the
existing diagnostic report. URLComponents encodes the title and body. The user
reviews and submits the issue using their GitHub account. Opening the form does
not prove submission.

The report carries app version/build, numeric macOS version, provider state
categories and numeric quota readings. Exclude account labels, personal paths,
raw errors, arbitrary provider window names, credentials, prompts and transcripts.
Keep Copy diagnostics as the fallback when the form cannot open or the report
exceeds the URL limit. Do not truncate a diagnostic report silently.

## Context

A reporter can have local token history without a quota reading. A sanitized
state summary helps distinguish those cases without collecting account data.
The product owner selected GitHub issues as the report destination.

## Consequences

- Reports are public and require user review and submission on GitHub.
- The app needs no GitHub token, report server or background upload.
- Changes to the public report must preserve its data exclusions.
