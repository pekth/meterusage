# Agent and contributor guidance

Use this file with [`CONTRIBUTING.md`](CONTRIBUTING.md) when working on the
public repository.

## Project rules

- Keep changes focused and explain user-visible behavior in the pull request.
- Run `swift build` and `swift test` before submitting code changes.
- During release work, verify each requested state separately: tested source,
  built and signed bundle, installed and running app, Git tag, published GitHub
  Release, uploaded asset, and manual runtime checks. Do not infer one state
  from another. `Scripts/make-app.sh` does not install the app, and a Git tag
  does not create a GitHub Release.
- Use synthetic fixtures and demo data only. Never commit credentials, private
  keys, real account data, raw transcripts, or personal absolute paths.
- Read [`docs/PRIVACY.md`](docs/PRIVACY.md) before changing data sources,
  logging, or provider integrations.
- Update `README.md` or the relevant file under `docs/` when behavior or setup
  changes.

## Repository-owned knowledge

- Read [`docs/KB.md`](docs/KB.md) for public repository facts and known gaps.
- Read [`docs/adr/README.md`](docs/adr/README.md) when a task changes or relies on a repository decision.
- Keep project facts in `docs/KB.md` and decisions in `docs/adr/`.
- Update those files in the same agent change when the change alters a documented fact or decision.
- Keep public documentation safe. Do not add credentials, personal data, private agent or orchestration instructions, private repository references, or local absolute paths.
- Do not add scheduled knowledge-sync workflows. Repository knowledge is maintained beside the project through ordinary agent changes.
