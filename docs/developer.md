# Developer Guide

This guide walks through environment setup, repository structure, and local testing using `nektos/act` so you can confidently extend d-flows workflows and actions.

## 📋 Prerequisites
Ensure the following tooling is installed and accessible from your terminal:

- **Docker Desktop** (or Docker Engine) — required for `act` containers. Verify with `docker --version`.
- **PowerShell 7+** — cross-platform scripting runtime. Verify with `pwsh --version`.
- **Git** — source control. Verify with `git --version`.
- **nektos/act** — local GitHub Actions runner. Verify with `act --version`.
- **Package Manager** — WinGet on Windows (`winget --version`) or a Linux/macOS equivalent to install dependencies.

!!! warning "Docker performance"
    Allocate at least 4 CPU cores and 6 GB RAM in Docker Desktop to match GitHub-hosted runner resources when executing integration tests.

## 🚀 Quick Start
1. Clone the repository
   ```bash
   git clone https://github.com/nntin/d-flows.git
   cd d-flows
   ```
2. Install `act` (see [ACT Setup Guide](ACT_SETUP_GUIDE.md) for OS-specific instructions)
3. Copy local secrets template
   ```bash
   cp .secrets.template .secrets
   ```
4. Verify development prerequisites
   ```bash
   pwsh -File scripts/dev/Verify-Setup.ps1
   ```
5. Run the full integration suite
   ```bash
   pwsh -File scripts/integration/Run-ActTests.ps1 -RunAll
   ```

## 📁 Project Structure
- `.github/workflows/` — workflow definitions (deployment, release, validation, docs)
- `actions/` — composite actions used by workflows
- `docs/` — MkDocs content (this guide + ACT documentation)
- `scripts/` — PowerShell automation
  - `scripts/integration/` — orchestrates `act` test matrices
  - `scripts/dev/` — helper utilities for contributors
- `tests/` — JSON fixtures & assets for each workflow
  - `tests/integration/` — complex multi-workflow scenarios
  - `tests/<workflow>/` — targeted fixtures for unit-level validation
- `.actrc` — shared configuration for act runner images and arguments
- `.secrets.template` — copy to `.secrets` for local secret injection

## 🧪 Local Testing with Act
`nektos/act` mirrors GitHub-hosted runners locally using Docker containers.

- Follow [ACT_SETUP_GUIDE.md](ACT_SETUP_GUIDE.md) for installation and Docker tuning.
- Use [ACT_USAGE.md](ACT_USAGE.md) for scenario-based walkthroughs and troubleshooting tips.
- Common commands:
  ```bash
  act --list
  act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/minimal.json
  pwsh -File scripts/integration/Run-ActTests.ps1 -RunAll
  ```

!!! tip "Speed up repeated runs"
    Pass `--reuse` to `act` or `-SkipCleanup` to `Run-ActTests.ps1` when iterating on failures to avoid re-provisioning containers.

## 🔧 Development Workflow
1. Implement workflow or action changes
2. Lint YAML with actionlint
   ```bash
   bash <(curl -s https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
   ./actionlint
   ```
3. Execute targeted jobs locally
   ```bash
   act workflow_dispatch --job <job-id> -W .github/workflows/<file>.yml
   ```
4. Run integration harness
   ```bash
   pwsh -File scripts/integration/Run-ActTests.ps1 -TestName "<test-name>"
   ```
5. Commit, push, and open a PR including relevant test evidence in the description

## 🧪 Testing Framework
- **Unit-level fixtures** — JSON payloads under `tests/<workflow>/` emulate GitHub webhook events
- **Integration scenarios** — `tests/integration/` pairs PowerShell orchestration with persistent artifacts
- **State isolation** — PowerShell scripts create GUID-based temp directories; pass `-SkipCleanup` for debugging
- **Harness scripts** — `Run-ActTests.ps1` bundles preparation, execution, log capture, and cleanup
- **Artifacts** — Logs, traces, and snapshots stored under `tests/_artifacts` for later inspection

Refer to the “Test State Management” section of `README.md` for lifecycle details.

## ⚙️ Configuration
- **`.actrc`** — defines default runner images, container options, and artifact paths for `act`
- **`.secrets`** — injects secrets into local runs; copy from `.secrets.template` and keep it untracked
- **`mkdocs.yml`** — docs navigation, theme, and versioning (Mike integration)

Example tweaks:
```bash
# Switch act to large runner image
echo '-P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest' >> .actrc

# Add a temporary PAT for integration tests
echo 'GH_TOKEN=<token>' >> .secrets
```

## 🔧 Troubleshooting
- **Docker not running** — ensure Desktop/Engine is up and restart containers
- **`act` missing** — confirm binary is in PATH (`act --version`)
- **Permission denied** — run your shell as Administrator (Windows) or ensure user is in the `docker` group
- **Failed tests** — rerun with `-SkipCleanup` to preserve reproducer artifacts
- **Workflow syntax errors** — execute `./actionlint` to surface lint feedback locally

For expanded `act` troubleshooting, see [ACT_SETUP_GUIDE.md](ACT_SETUP_GUIDE.md#%F0%9F%94%A7-troubleshooting).

## 🔗 Additional Resources
- [ACT Setup Guide](ACT_SETUP_GUIDE.md)
- [ACT Usage Guide](ACT_USAGE.md)
- [Versioning Strategy](VERSIONING.md)
- [nektos/act documentation](https://github.com/nektos/act)
- [GitHub Actions docs](https://docs.github.com/actions)
- [Repository Actions page](https://github.com/nntin/d-flows/actions)
