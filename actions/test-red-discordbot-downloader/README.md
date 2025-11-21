# test-red-discordbot-downloader

## Overview
This composite action provisions a temporary git repository containing your cogs, adds it to Red-DiscordBot through the Downloader cog, installs the cogs using `repo add`/`cog install`, and validates them via Red's RPC interface. Unlike [`test-red-discordbot`](../test-red-discordbot) which simply copies directories into the cog path, this action runs the full downloader flow end-to-end so you can catch metadata, dependency, and git issues earlier.

## Inputs
| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | ✅ | – | Discord bot token passed to `redbot tinkerer --token`. |
| `cog_paths` | ✅ | – | Comma-separated list of paths to cog directories on the runner (e.g. `cogs/foo,cogs/bar`). Each directory must contain a valid `info.json`. |
| `repo_name` | ❌ | `test-repo` | Friendly label used when the downloader registers the temporary repository. Must be unique per run; characters outside Python identifiers are converted automatically. |
| `repo_url` | ❌ | `""` | Override repository URL if you want to install from an existing remote instead of the generated local repository. Leave empty for the auto-created local repo. |
| `rpc_port` | ❌ | `6133` | Port the Red RPC server will listen on. Keep default unless you have networking conflicts. |

## Usage example
```yaml
name: Check Cogs (downloader path)
on:
  pull_request:
  push:
    branches: [main]

jobs:
  downloader-tests:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Install Red via reusable flow
        uses: ./d-flows/actions/install-red-discordbot
        with:
          python-version: '3.11'

      - name: Configure Red instance
        uses: ./d-flows/actions/setup-red-discordbot
        with:
          instance: tinkerer

      - name: Run downloader-based cog tests
        uses: ./d-flows/actions/test-red-discordbot-downloader
        with:
          token: ${{ secrets.DISCORD_BOT_TOKEN }}
          cog_paths: cogs/example,cogs/second
          repo_name: pr-${{ github.event.number || github.run_id }}
```

## How it works
1. The action installs the `aiohttp` dependency used by the RPC test client.
2. A temporary working tree is created, all requested cogs are copied into it, and a git repository plus root-level `info.json` metadata file are committed.
3. Red-DiscordBot (`redbot tinkerer ... --rpc`) starts in the background and writes logs to `${{ runner.temp }}`.
4. The helper script `test_downloader_cogs.py` loads Red's configuration, initializes the downloader `RepoManager`, and adds the temporary git repo via `repo add` semantics.
5. Downloader installs each cog into Red's configured install path, ensuring requirements are installed into Downloader's library directory.
6. Using the RPC websocket endpoint, every installed cog is loaded and then unloaded to verify that the installation truly works inside a live bot.
7. On success or failure the action cleans up: Red is stopped, installed cogs are removed, the downloader clone is deleted, and the temporary repository is discarded.

## Requirements
- Runner must already have Red-DiscordBot configured (e.g., via `install-red-discordbot` + `setup-red-discordbot` flows).
- Git 2.x and Python 3.11+ must be available on the runner image.
- Downloader relies on cog `info.json` metadata being present and valid JSON.
- Each cog must live in its own directory; provide each directory path through `cog_paths`.

## Troubleshooting
- **Missing config**: Ensure `redbot-setup` has been run for the `tinkerer` instance; otherwise the action will fail when it can't find `~/.config/Red-DiscordBot/config.json`.
- **Invalid repo name**: Downloader repo names must be valid identifiers. The action converts hyphens to underscores, but other invalid characters will raise errors.
- **Requirement installation failures**: Review the action log to see which dependency pip command failed; you may need to add wheels or pin compatible versions.
- **RPC timeout**: The helper waits 30 seconds for the websocket endpoint. Check the Red log tail dumped by the action when failures occur.
- **Git errors**: Verify each cog directory includes necessary files and can be committed. Ensure your cogs don't include very large binaries or files requiring Git LFS.
- **Known limitations**: The helper always targets the `master` branch when adding the repo and assumes Downloader installs requirements with pip; override `repo_url` if you must test other branches.

## Comparison with `test-red-discordbot`
| Capability | `test-red-discordbot` | `test-red-discordbot-downloader` |
| --- | --- | --- |
| Installs via downloader git repo | ❌ copies directories directly | ✅ clones and installs through downloader |
| Validates `repo info.json` metadata | ❌ | ✅ |
| Installs requirements using downloader logic | ❌ (manual `uv pip install`) | ✅ (repo-managed pip install) |
| Exercises load/unload through RPC | ✅ | ✅ |
| Detects downloader-specific regressions (repo config, git hooks, metadata) | ❌ | ✅ |

Use the downloader variant when you need high confidence that your cogs can be installed by end users through `[p]repo add` and `[p]cog install`. Keep using the RPC-only version for faster smoke tests when git/dependency flows are not critical.
