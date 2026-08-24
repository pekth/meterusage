# Project knowledge

Last verified: 2026-08-24

Source revision: `9003b78beecb051c7d31334602ecf59982c1e7da`

## Evidence boundary

This index records the meterusage source and documentation at the source revision above. Source, assembled bundle, installed app, GitHub release, and runtime behavior are separate evidence layers. One layer does not prove the others.

## Current source and document state

meterusage is a macOS menu-bar app that reads local and documented aggregate provider usage signals. The README documents source build and demo mode. Privacy boundaries are explicit: no direct Codex/Claude credential read; OpenRouter uses an existing key; Grok re-reads its CLI OIDC token; no prompts or code are sent; cost figures are estimates. This index does not establish release, installation, or runtime evidence.

## Best references

- [Repository README](../README.md)
- [Privacy and security design](PRIVACY.md)
- [Demo mode](DEMO.md)
- [Companion file guide](COMPANION.md)
- [Contributor guide](../CONTRIBUTING.md)
- [Changelog](../CHANGELOG.md)

## Open verification gaps

- Current source-to-bundle identity is not established by this index.
- Installed app identity, GitHub release assets, and runtime provider behavior require separate current proof.
- Provider availability, account state, network responses, and estimated costs are not release or billing truth.
