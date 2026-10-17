# ADR 0033: Read Muse Code allowance through the official CLI

- Status: Source implementation; native and live-provider acceptance pending
- Date: 2026-10-17

Add an opt-in Electron provider named Muse Code with the internal key `muse`.
Keep it distinct from Muse.ai's cloud agent and Desktop subscription. Both
products have usage limits, but their credentials and allowances do not establish
a shared account or combined budget.

Reuse the bounded subprocess transport. Start the installed official
`muse serve`, initialize MSP with experimental methods enabled, then call
`usage/read`. Do not start a session or model turn, change authentication, read
credential files or add an SDK dependency. The official method supplies the
host's last observation without a model call.

Retain session and weekly percentages, reset times, session duration, a bounded
tier identifier and `observedAtMs`. Preserve percentages above 100 as the wire
contract permits them. Clamp display geometry independently. Reject missing,
expired and invalid values. Show the observation time so polling cannot make
an old observation appear newly measured. No token history or cost is inferred.

Settings exposes explicit start/stop actions. Existing preference validation,
provider ordering, cards, quota reporting and demo composition serve the new
provider. It remains excluded from isolated Codex/Claude live profiles. Stopping
collection does not sign the user out of Muse Code.
The saved choice also gates headless collection. Source removal cancels active
reads, and a later start uses a new source to reject results from the old one.
Clear in-memory allowance on each change. The schema-1 JSON report adds Muse Code's
`observed_at` without changing other providers. Keep Muse allowance in memory and
exclude it from the shared quota archive. Legacy Swift and Electron decoders
reject an archive containing an unknown provider, so writing Muse there would
discard all cached quota on rollback. Other providers keep their existing format
and reset-pacing state. Muse allowance is collected again after relaunch.

Muse.ai Desktop import needs independent evidence for the native session store,
active-account selection and encryption. Do not infer those from a bundle ID or
use Muse Code authentication as a substitute.

Verify with synthetic MSP subprocesses, numeric/projection tests, composition
and renderer checks, TypeScript checking and production bundling. Native app and
live-provider validation remain distinct gates.

References: [official product](https://dev.meta.ai/products/muse-code),
[`usage/read`](https://meta-models.github.io/muse-code-sdk/next/generated/msp/methods/usage-read/),
[usage window schema](https://meta-models.github.io/muse-code-sdk/next/generated/msp/types/subscriptionusagewindow/).
