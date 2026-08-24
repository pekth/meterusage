# Project knowledge

Last verified: 2026-08-24

Source revision: `9e8d9580057b75e41f37c1c96dd784e668cd446a`

## Evidence boundary

This index records the meterusage source and documentation at the source revision above. Source, assembled bundle, installed app, GitHub release, and runtime behavior are separate evidence layers. One layer does not prove the others.

## Current source and document state

meterusage is a macOS menu-bar app that reads local and documented aggregate provider usage signals. The README documents source build and demo mode. Privacy boundaries are explicit: no direct Codex/Claude credential read; OpenRouter uses an existing key; Grok re-reads its CLI OIDC token; no prompts or code are sent; cost figures are estimates. External vault notes contain dated release and installation records. This index does not verify them and they must not be used as current release, installation, or runtime evidence.

## Best references

- [Repository README](../README.md)
- [Privacy and security design](PRIVACY.md)
- [Demo mode](DEMO.md)
- [Companion file guide](COMPANION.md)
- [Contributor guide](../CONTRIBUTING.md)
- [Changelog](../CHANGELOG.md)

Vault status: tilorah-vault/01-Products/meterusage/status.md

## Open verification gaps

- Current source-to-bundle identity is not established by this index.
- Installed app identity, GitHub release assets, and runtime provider behavior require separate current proof.
- Provider availability, account state, network responses, and estimated costs are not release or billing truth.
