# Repository Guidelines

## Project Structure & Module Organization
d-flows centers on GitHub workflow automation. `.github/workflows/` holds canonical workflow definitions such as `bump-version.yml` and `step-summary.yml`; treat them as source code. Integration tooling lives under `scripts/`, with `scripts/integration/*.ps1` orchestrating fixture application, state backup, and `act` execution. Specs and how-to guides belong in `docs/` (for example `ACT_USAGE.md`). Test fixtures sit in `tests/<workflow>/` and `tests/integration/*.json`, and are designed to be consumed by the orchestration scripts.

## Build, Test, and Development Commands
Run the setup sanity check before heavy work: `pwsh -File scripts/verify-act-setup.ps1`. Use `pwsh -File scripts/integration/Run-ActTests.ps1 -RunAll` for the full suite, or add `-TestName "<label>"` to scope to one scenario. When editing workflows, lint with `bash <(curl -s https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) && ./actionlint`. For fast feedback on a single workflow, `act workflow_dispatch --job <job-id>` respects `.actrc` and the mounted test state path.

## Coding Style & Naming Conventions
PowerShell modules follow four-space indentation, PascalCase function/cmdlet names, and comment-based help blocks as seen in `Run-ActTests.ps1`. Prefer explicit parameter attributes (`[Parameter(Mandatory=$false)]`) and guard clauses over deeply nested `if`s. Workflow YAML should stay consistent with GitHub casing, use descriptive job ids (`validate-syntax`, `notify-completion`), and keep reusable snippets in `.github/workflows/`. JSON fixtures should keep lowercase keys and snake-case filenames (`v0-to-v1-release-cycle.json`) to match loader expectations.

## Testing Guidelines
Use `tests/integration/*.json` to describe multi-step release flows; every test must back up git state via the scripts before mutating tags or branches. Store temporary artifacts in the automatic `d-flows-test-state-<guid>` directories and clean them unless actively debugging (`-SkipCleanup`). Unit-style tests (e.g., `tests/bump-version/`) should assert `OUTPUT:` markers so `Run-ActTests.ps1` can parse them. Aim to cover new workflow branches or failure paths and document bespoke fixtures in the JSON comments section.

## Commit & Pull Request Guidelines
Recent history favors short, sentence-case messages that explain the change (“release.yml requires token”). Keep subjects under ~72 characters and add more context in the body if needed. Pull requests should link any tracked issue, describe the workflow(s) touched, call out required secrets, and paste relevant `act` logs or step-summary screenshots. Include a checkbox list of tests executed and note any follow-up tasks for release coordination.

## Security & Configuration Tips
Never commit real secrets; copy `.secrets.template` to `.secrets` for local `act` runs. Keep Docker and `act` updated, and verify `.actrc` when changing container mounts or `TEST_STATE_PATH`. When sharing logs, redact webhook URLs and PATs, and rely on `webhook_url` and `GITHUB_TOKEN` placeholders highlighted in the template.
