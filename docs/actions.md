# 🎯 GitHub Actions

d-flows ships seven composite GitHub Actions designed to plug into any workflow. They power notifications, summary reporting, and the complete Red-DiscordBot build/test lifecycle while remaining compatible with both reusable workflows and direct `uses: nntin/d-flows/actions/<action>@v1` references.

## 📋 Quick Reference
| Action | Description |
| --- | --- |
| `discord-notify` | Send Discord webhook embeds or plain messages with rich metadata |
| `step-summary` | Append or overwrite content inside the GitHub Step Summary panel |
| `build-red-discordbot` | Clone, build, and package Red-DiscordBot artifacts |
| `install-red-discordbot` | Fetch build artifacts (or PyPI) and install using uv |
| `setup-red-discordbot` | Scaffold configuration folders and run a dry-run to validate tokens |
| `test-red-discordbot` | Load/unload cogs inside Red using RPC to ensure they work in situ |
| `test-red-discordbot-downloader` | Exercise cogs via the downloader repository pipeline |

## 🗂️ Action Categories
### 🔔 Notification & Reporting
- `discord-notify`
- `step-summary`

### 🏗️ Red-DiscordBot Build Pipeline
- `build-red-discordbot`
- `install-red-discordbot`
- `setup-red-discordbot`

### 🧪 Red-DiscordBot Testing
- `test-red-discordbot`
- `test-red-discordbot-downloader`

---

## 📢 discord-notify
Send Discord notifications through the Webhook API with embeddable fields, colors, and optional content fallback.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `webhook_url` | ✅ | — | Discord webhook URL (validated to prevent secret leakage) |
| `message_type` | ❌ | `embed` | `embed` or `message` |
| `title` | ❌ | — | Embed title |
| `description` | ❌ | — | Embed description body |
| `content` | ❌ | — | Plain message body when `message_type=message` |
| `color` | ❌ | — | Decimal color code (`5814783` = blue) |
| `fields` | ❌ | — | JSON array of embed fields |
| `username` | ❌ | GitHub actor | Override webhook username |
| `avatar_url` | ❌ | Actor avatar | Override avatar image |
| `footer_text` | ❌ | Repo + workflow | Footer text |
| `footer_icon_url` | ❌ | — | Footer icon URL |
| `image_url` | ❌ | — | Large embed image |
| `thumbnail_url` | ❌ | — | Thumbnail image |
| `author_url` | ❌ | — | Link for author section |
| `url` | ❌ | — | Link applied to embed title |

### Usage
**Embed notification with dynamic fields** (`.github/workflows/check-pr.yml`):
```yaml
notify-completion:
  needs: [build-discord-fields-completion, run-integration-tests]
  if: always()
  uses: ./.github/workflows/discord-notify.yml
  secrets:
    webhook_url: ${{ secrets.DISCORD_WEBHOOK_URL }}
  with:
    message_type: embed
    title: ${{ needs['run-integration-tests'].result == 'success' && '✅ PR CI Workflow Completed Successfully' || '⚠️ PR CI Workflow Completed with Issues' }}
    description: >-
      ${{ needs['run-integration-tests'].result == 'success' &&
          'All validation checks and tests passed successfully. The pull request is ready for review.' ||
          'The workflow completed but some checks failed. Please review the results and address any issues.' }}
    color: ${{ needs['run-integration-tests'].result == 'success' && '3066993' || '16776960' }}
    fields: ${{ needs.build-discord-fields-completion.outputs.discord_fields }}
```

**Building fields with `jq`** (`check-pr.yml` lines 97‑140):
```bash
FIELDS=$(jq -n '
  [
    {"name": "Step Summary Test", "value": (($summary_status == "success" and "✅ Passed" or "❌ Failed")), "inline": true},
    {"name": "Total Tests", "value": $total_tests, "inline": true},
    {"name": "Run Details", "value": ("[View Full Run](" + $run_url + ")"), "inline": false}
  ]')
```
Export the multiline JSON via `$GITHUB_OUTPUT` and feed it into `fields` for polished embeds.

**Reusable action usage** (`bz-cogs/.github/workflows/check-cogs.yml`):
```yaml
- name: Send Discord Notification
  uses: nntin/d-flows/actions/discord-notify@v1
  with:
    webhook_url: ${{ secrets.DISCORD_WEBHOOK_URL }}
    message_type: embed
    color: ${{ needs.build-validation-fields.outputs.validation_result == 'success' && '3066993' || '16776960' }}
    fields: ${{ needs.build-validation-fields.outputs.discord_fields }}
```

!!! note "Field payloads"
    Provide `fields` as a JSON array of `{ "name": "...", "value": "...", "inline": bool }` objects. Remember to escape quotes or use heredocs when building multi-line JSON.

---

## 📝 step-summary
Write Markdown to GitHub Step Summaries, enabling dashboards visible in workflow run pages.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `title` | ❌ | — | Optional H2 heading before the content |
| `markdown` | ✅ | — | Markdown body appended to the summary |
| `overwrite` | ❌ | `false` | `true` clears the summary before writing |

### Usage
**Integration results summary** (`check-pr.yml` lines 74‑95):
```yaml
- name: Test Step Summary
  uses: ./.github/workflows/step-summary.yml
  with:
    title: Integration Test Results
    markdown: |
      ${{ needs.run-integration-tests.outputs.failed_tests == '0' && '✅ All tests passed!' || '❌ Some tests failed' }}

      | Metric | Value |
      |--------|-------|
      | **Total Tests** | ${{ needs.run-integration-tests.outputs.total_tests }} |
      | **Failed Tests** | ${{ needs.run-integration-tests.outputs.failed_tests }} |
```

**Reports from a consumer repo** (`bz-cogs`):
```yaml
- name: Write Step Summary
  uses: nntin/d-flows/actions/step-summary@v1
  with:
    title: Cog Validation Results
    markdown: |
      | Stage | Status |
      |-------|--------|
      | Cog Tests | ${{ needs['test-cogs'].result == 'success' && '✅ Passed' || '❌ Failed' }} |
```

!!! tip "Append vs overwrite"
    Summaries persist for the entire job. Set `overwrite: true` when you want only the latest report. Otherwise the action appends content, enabling multiple steps to contribute to a single summary page.

---

## 🧪 test-red-discordbot-downloader
Installs and validates cogs via Red’s downloader cog. Ideal for validating entire repositories with minimal configuration.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | ✅ | — | Discord bot token used to launch Red |
| `cog_paths` | ❌ | *(auto-discover)* | Comma-separated paths; empty triggers discovery |
| `repo_name` | ❌ | `test-repo` | Name used for the temporary downloader repo |
| `repo_url` | ❌ | — | Remote repository to test (skips temp repo creation) |
| `repo_branch` | ❌ | — | Branch when cloning remote repos |
| `rpc_port` | ❌ | `6133` | RPC port for Red |

### Usage
**Auto-discovery (no cog list)** (`bz-cogs`):
```yaml
- name: Test cogs via Downloader
  uses: nntin/d-flows/actions/test-red-discordbot-downloader@v1.1.2
  with:
    token: ${{ secrets.DISCORD_BOT_TOKEN }}
```
The action scans the workspace for directories containing `info.json`, copies them into a temporary git repo, and drives Red’s downloader to install/test each cog.

**Explicit cog selection**:
```yaml
- uses: nntin/d-flows/actions/test-red-discordbot-downloader@v1
  with:
    token: ${{ secrets.DISCORD_BOT_TOKEN }}
    cog_paths: cogs/example,cogs/feature
```

**Remote repository validation**:
```yaml
- uses: nntin/d-flows/actions/test-red-discordbot-downloader@v1
  with:
    token: ${{ secrets.DISCORD_BOT_TOKEN }}
    repo_url: https://github.com/example/cogs.git
    repo_branch: main
```

!!! note "Temporary repo hygiene"
    The action copies cogs into a temporary directory, initializes a git repository, and cleans up on exit—even after failures. Logs land in `${{ runner.temp }}/redbot-downloader.log` for troubleshooting.

---

## 🏗️ build-red-discordbot
Clone, build, and package Red-DiscordBot before running downstream install/test jobs.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `red_commit` | ❌ | latest `main` | Specific commit hash to checkout |
| `artifact_name` | ❌ | `red-discordbot-build` | Name of the uploaded artifact |

### Usage
```yaml
- name: Build Red-DiscordBot
  uses: nntin/d-flows/actions/build-red-discordbot@v1
  with:
    red_commit: 7c9d3b4   # optional
    artifact_name: nightly-red-build
```
The action sets up Python 3.11, installs `build` + `twine`, produces wheels under `Red-DiscordBot/dist`, and uploads them as artifacts (skipped automatically when running inside `act`).

!!! tip "Pinning commits"
    Provide `red_commit` to reproduce historical builds or bisect regressions without relying on the moving default branch.

---

## 📦 install-red-discordbot
Download previously built artifacts (or fall back to PyPI) and install using uv.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `artifact_name` | ❌ | `red-discordbot-build` | Artifact name to fetch |

### Usage
```yaml
- name: Install Red-DiscordBot
  uses: nntin/d-flows/actions/install-red-discordbot@v1
  with:
    artifact_name: nightly-red-build
```
When `env.ACT == 'true'`, the action copies wheels from `/tmp/dist` instead of downloading artifacts, enabling fast local tests. If no wheels exist it installs from PyPI, ensuring pipelines never fail due to missing builds.

!!! note "Verification"
    After installation the action runs a short Python snippet to confirm `import redbot` succeeds, catching version mismatch issues early.

---

## ⚙️ setup-red-discordbot
Prepare config directories and validate credentials with a dry-run.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | ✅ | — | Discord bot token |
| `prefix` | ❌ | `!` | Command prefix |
| `optional_args` | ❌ | — | Additional CLI flags passed to `redbot` |

### Usage
```yaml
- name: Configure Red-DiscordBot
  uses: nntin/d-flows/actions/setup-red-discordbot@v1
  with:
    token: ${{ secrets.DISCORD_BOT_TOKEN }}
    prefix: "?"
    optional_args: "--owner 123456789012345678"
```
The action writes `~/.config/Red-DiscordBot/config.json`, creates `~/redbot-app/cogs`, and executes `python3 -m redbot tinkerer --dry-run` to confirm the token and prefix work before heavier jobs run.

---

## 🧪 test-red-discordbot
Install specified cogs into Red’s data directory and validate them through the RPC API.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | ✅ | — | Discord bot token |
| `cog_paths` | ✅ | — | Comma-separated directories to test |
| `rpc_port` | ❌ | `6133` | RPC port |

### Usage
```yaml
- name: Test Red-DiscordBot cogs
  uses: nntin/d-flows/actions/test-red-discordbot@v1
  with:
    token: ${{ secrets.DISCORD_BOT_TOKEN }}
    cog_paths: cogs/example,cogs/feature
    rpc_port: 7000
```
The action copies cogs into Red’s install path, launches the bot with RPC enabled, and executes `test_rpc_cogs.py` to load/unload cogs. Failures automatically print the last 200 lines of `${{ runner.temp }}/redbot-rpc.log`.

!!! warning "Config prerequisite"
    Ensure `setup-red-discordbot` (or another process) has already created `~/.config/Red-DiscordBot/config.json`. The action exits early when the file is missing.

---

## 💡 Common Patterns
- **Version pinning** — Consumers call `nntin/d-flows/actions/<name>@v1` (or `@v1.1.2` like `check-cogs.yml`) for stability while allowing backwards-compatible updates.
- **Reusable workflows** — Internal jobs wrap the actions inside `.github/workflows/discord-notify.yml` and `.github/workflows/step-summary.yml` for DRY pipelines (see `check-pr.yml`).
- **Dynamic embed fields** — Use `jq -n '[{...}]'` plus `$GITHUB_OUTPUT` to produce field arrays consumed by `discord-notify`.
- **Conditional execution** — Combine `needs` + `if: always()` to publish summaries/notifications even when upstream jobs fail.
- **Secret management** — Pass tokens/webhook URLs via `secrets.*`; both notification and Red actions validate inputs before running to avoid partial failures.

## 🔗 Integration Examples
- **Cog Validation Pipeline** (`bz-cogs`): `test-red-discordbot-downloader` → `step-summary` → `discord-notify`, ensuring every push/pull request surfaces results in both GitHub UI and Discord.
- **PR Validation** (`check-pr.yml`): Run integration tests, publish structured summaries, build embed fields with `jq`, and notify Discord through the reusable workflow—demonstrating cross-job data sharing and conditional formatting.

These patterns can be mixed and matched to create opinionated yet flexible CI pipelines for Red-DiscordBot projects.
