# MeterUsage versions

Electron 0.3.0-beta.4, build 73, is the opt-in public beta. Swift 0.2.41 stays
stable and remains the updater/installer download. New features target Electron;
Swift is retained for critical maintenance and rollback.

| Version | Source | Download |
| --- | --- | --- |
| Electron beta | [v0.3.0-beta.4](https://github.com/pekth/meterusage/tree/v0.3.0-beta.4) | [Manual signed/notarized Apple silicon ZIP](BETA.md) |
| Swift stable | Default branch and [v0.2.41](https://github.com/pekth/meterusage/tree/v0.2.41) | [Swift guide](swift/README.md) |

The beta source is published through its tag while the Electron PR stack stays
unmerged. The tag includes current documentation and build 61 synthetic screenshots;
its executable inputs match build source
`3c56bd0d4ebf6d51996b9ebdc0a9b09f5570f182`. The beta's package version was set
at packaging time; its source manifest retains 0.2.41. Settings shows the
running bundle version. See [known beta limits](BETA.md#known-limits).

The apps share an identity and normal data locations. Quit one before replacing
it and preserve a rollback copy. Do not run both against a normal profile.
Stable cutover and Swift retirement remain separate work, defined in the
[beta repository strategy](https://github.com/pekth/meterusage/blob/v0.3.0-beta.4/docs/VERSIONS.md).
