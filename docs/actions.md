# 🎯 GitHub Actions

d-flows ships seven composite GitHub Actions designed to plug into any workflow. They power notifications, summary reporting, and the complete Red-DiscordBot build/test lifecycle while remaining compatible with both reusable workflows and direct `uses: nntin/d-flows/actions/<action>@v1` references.

## 📋 Quick Reference
| Action | Description |
| --- | --- |
| [`discord-notify`](./actions/discord-notify.md) | Send Discord webhook embeds or plain messages with rich metadata |
| [`step-summary`](./actions/step-summary.md) | Append or overwrite content inside the GitHub Step Summary panel |
| [`build-red-discordbot`](./actions/build-red-discordbot.md) | Clone, build, and package Red-DiscordBot artifacts |
| [`install-red-discordbot`](./actions/install-red-discordbot.md) | Fetch build artifacts (or PyPI) and install using uv |
| [`setup-red-discordbot`](./actions/setup-red-discordbot.md) | Scaffold configuration folders and run a dry-run to validate tokens |
| [`test-red-discordbot`](./actions/test-red-discordbot.md) | Load/unload cogs inside Red using RPC |
| [`test-red-discordbot-downloader`](./actions/test-red-discordbot-downloader.md) | Exercise cogs via the downloader repository pipeline |

Each row corresponds to a composite action you can call via ``uses: nntin/d-flows/actions/<action>@<version>``. Versions follow SemVer; pinning `@v1` tracks the latest patch release within the v1 series, while `@v1.2.3` freezes to a specific build. Major tags are force-updated on every release, see [VERSIONING](./VERSIONING.md) if you need the in depth strategy. Adventurers can also select branches e.g. `@main`.
