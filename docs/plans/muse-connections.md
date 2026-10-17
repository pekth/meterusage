# Muse connections

Add separate opt-in Electron providers for Muse.ai account allowance and Muse
Code subscription allowance. Preserve existing providers, account sources and
the retained Swift app. Success requires synthetic connection regression tests,
TypeScript checking and production bundling. Native sign-in and macOS execution
need separate proof.

Muse Code uses its existing signed-in `muse serve` process over stdio. Initialize
MSP, then call `usage/read` without starting a model turn or reading credentials.
Keep the provider's observation timestamp. An absent observation remains
unavailable. See the [official protocol](https://meta-models.github.io/muse-code-sdk/next/generated/msp/methods/usage-read/).

Muse.ai has a separate allowance and authentication boundary. Verify its
desktop session source and subscription response before implementing its reader.
Do not infer a native cookie location from an application identifier.

1. Add the Muse Code reader under `src/main/providers/`, register its provider
   and source, and add an explicit Settings action. Test the protocol exchange,
   missing data, invalid numeric fields, timeout and cancellation.
2. Add Muse.ai only against an evidenced session and allowance contract. Reuse
   connection consent, cancellation, disconnect and source invalidation. Test
   account changes, expired sessions, failed saves and late responses.
3. Add synthetic demo readings and update `docs/PRIVACY.md`, `docs/KB.md`,
   connection instructions and `CHANGELOG.md`. Review the complete diff and run
   `pnpm typecheck`, `pnpm test` and `pnpm build` with the declared Node version.

Both providers start disabled. They never share quota windows or imply a token
ledger from a percentage. No CLI installation, provider logout, paid action,
inference, app installation or release is part of this change. Disabling the
providers is the rollback path.
