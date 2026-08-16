# Agent and contributor guidance

Use this file with [`CONTRIBUTING.md`](CONTRIBUTING.md) when working on the
public repository.

## Project rules

- Keep changes focused and explain user-visible behavior in the pull request.
- Run `swift build` and `swift test` before submitting code changes.
- Use synthetic fixtures and demo data only. Never commit credentials, private
  keys, real account data, raw transcripts, or personal absolute paths.
- Read [`docs/PRIVACY.md`](docs/PRIVACY.md) before changing data sources,
  logging, or provider integrations.
- Update `README.md` or the relevant file under `docs/` when behavior or setup
  changes.

The repository does not publish private agent orchestration instructions.
