# d-flows Documentation

GitHub workflow automation and release management for PowerShell-centric projects. d-flows ships semantic versioning, reusable workflows, composite actions, and local GitHub Actions testing through `act` so contributors can iterate quickly and safely.

## 🚀 Key Features
- Automated semantic versioning and release orchestration with guardrails
- Reusable GitHub Actions workflows such as Discord notifications and step summaries
- Composite actions for building, installing, and testing Red-DiscordBot components
- Comprehensive local workflow testing powered by `nektos/act`
- PowerShell-based integration test harness with snapshotting and fixture isolation
- Versioned documentation deployed via MkDocs + Mike

## 📚 Documentation Sections
- **Getting Started** — Dive into the [Developer Guide](developer.md) to set up tooling and run local tests
- **Versioning Strategy** — Review [VERSIONING.md](VERSIONING.md) for semantic release rules and bump automation
- **ACT Testing** — Follow the [ACT Setup Guide](ACT_SETUP_GUIDE.md) and [ACT Usage Guide](ACT_USAGE.md) for local workflow execution
- **GitHub Actions** — Future home for workflow reference material (coming soon)

!!! note "Need a TL;DR?"
    Run `act --list` to see every locally runnable workflow before jumping into deeper guides.

## 🔄 Available Workflows
- [`.github/workflows/bump-version.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/bump-version.yml) — Calculates next semantic version and opens releases
- [`.github/workflows/release.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/release.yml) — Publishes tagged releases with changelog assets
- [`.github/workflows/discord-notify.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/discord-notify.yml) — Reusable notification helper for shared pipelines
- [`.github/workflows/step-summary.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/step-summary.yml) — Posts formatted content into GitHub Step Summary
- [`.github/workflows/check-pr.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/check-pr.yml) — Pull request validation suite
- [`.github/workflows/check-push.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/check-push.yml) — Push-time safety checks
- [`.github/workflows/docs.yml`](https://github.com/nntin/d-flows/blob/main/.github/workflows/docs.yml) — MkDocs + Mike documentation deployment

## 🎬 Composite Actions
- [`actions/discord-notify`](https://github.com/nntin/d-flows/tree/main/actions/discord-notify) — Send rich Discord webhook messages from workflows
- [`actions/step-summary`](https://github.com/nntin/d-flows/tree/main/actions/step-summary) — Append formatted Markdown to the job summary
- [`actions/test-red-discordbot-downloader`](https://github.com/nntin/d-flows/tree/main/actions/test-red-discordbot-downloader) — Validate Red-DiscordBot downloader logic
- [`actions/build-red-discordbot`](https://github.com/nntin/d-flows/tree/main/actions/build-red-discordbot) — Build artifacts for downstream tests
- [`actions/install-red-discordbot`](https://github.com/nntin/d-flows/tree/main/actions/install-red-discordbot) — Install dependencies and runtime prerequisites
- [`actions/setup-red-discordbot`](https://github.com/nntin/d-flows/tree/main/actions/setup-red-discordbot) — Prepare the Red-DiscordBot environment
- [`actions/test-red-discordbot`](https://github.com/nntin/d-flows/tree/main/actions/test-red-discordbot) — Execute validation across supported cogs

## 💡 Getting Help
- [Open an issue](https://github.com/nntin/d-flows/issues) for bugs, feature requests, or workflow regressions
- [Start a discussion](https://github.com/nntin/d-flows/discussions) to propose ideas or share best practices
- Browse the [repository](https://github.com/nntin/d-flows) for source code, scripts, and documentation

!!! tip "Documentation versions"
    The `latest` docs track `main`, while `stable` reflects the most recent tagged release. Switch versions via the selector in the site header.
