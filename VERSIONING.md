# Versioning Strategy

This document describes the versioning and release management strategy for the d-flows repository. The project follows semantic versioning (SemVer) principles to ensure consistent and predictable releases.

---

## Semantic Versioning

The project uses semantic versioning with the format: `MAJOR.MINOR.PATCH` (e.g., `v1.2.3`)

Each component is defined as follows:

- **MAJOR**: Incremented for incompatible API changes or breaking changes
- **MINOR**: Incremented for backward-compatible functionality additions
- **PATCH**: Incremented for backward-compatible bug fixes

All version tags are prefixed with `v` (e.g., `v1.0.0`, `v2.1.3`).

---

## Branching Model

The repository uses a two-tier branching strategy:

- **`main` branch**: Contains the latest major version under active development
- **`release/vX` branches**: Maintain older major versions for bug fixes and security patches

### Branch Usage Examples

| Scenario | Branch | Purpose |
|----------|--------|---------|
| Working on v2.x.x | `main` | v2 development |
| v1.x.x needs patches | `release/v1` | v1 maintenance |
| v3.0.0 is released | `main` moves to v3 | `release/v2` created for v2 patches |

**Important Notes:**
- Release branches are created only when a new major version is released and the previous major version needs to be maintained
- The first release always starts from `main` branch

---

## Major Version Tags

The repository implements lightweight major tag management:

- Each major version has a corresponding tag (e.g., `v1`, `v2`, `v3`)
- These tags are automatically updated to point to the latest patch within that major version
- **Example**: If releases are `v1.0.0`, `v1.1.0`, `v1.2.0`, then `v1` points to `v1.2.0`

### Benefits

- Users can reference `v1` in their workflows to always get the latest stable v1.x.x release
- Simplifies version pinning for consumers who want automatic patch updates
- Provides a stable API contract within a major version

**Note**: Major tags are force-updated automatically by the release workflow.

---

## Release Workflows

The repository uses a two-workflow system for releases:

### Bump Version Workflow

This workflow (`bump-version.yml`) automates version calculation and triggers releases.

**Workflow Inputs:**
- **Bump Type**: Choose from `major`, `minor`, or `patch`
- **Target Branch**: Select the branch to bump (e.g., `main`, `release/v1`, `release/v2`)

**Workflow Behavior:**
- Fetches the latest tag from the selected branch
- Calculates the new version based on bump type
- Validates the version and branch selection
- Automatically creates release branches for previous major versions when performing major bumps on main
- Triggers the release workflow automatically

**Validation Rules:**
- First releases must be created from `main` branch
- Release branches can only create versions matching their major version (e.g., `release/v1` creates `v1.x.x`)
- Main branch is used for the latest major version

### Release Workflow

This workflow (`release.yml`) creates the actual GitHub release.

**What it does:**
- Creates a GitHub release with auto-generated release notes
- Creates the version tag (e.g., `v1.2.3`)
- Updates the major version tag (e.g., `v1`) to point to the new release
- Publishes the release to GitHub

**Note**: This workflow is typically triggered automatically by the bump version workflow.

---

## Common Scenarios

### Creating the First Release

**Step-by-step instructions:**

1. Navigate to Actions → Bump Version workflow
2. Click "Run workflow"
3. Select bump type: `minor` (will create `v0.1.0`)
4. Select target branch: `main`
5. Click "Run workflow" button

**Result:**
- Creates tag `v0.1.0` on `main` branch
- Creates major tag `v0` pointing to `v0.1.0`
- Publishes GitHub release

### Promoting to v1.0.0

**Example scenario:**
- Current version: `v0.1.0` (or any v0.x.x version)
- Goal: Promote to stable v1.0.0 release

**Steps:**
1. Run Bump Version workflow
2. Select bump type: `major`
3. Select target branch: `main`
4. **Result**: Creates `v1.0.0`, creates `v1` tag

This promotes your project from the initial development phase (v0.x.x) to the first stable major release (v1.0.0).

### Releasing Minor and Patch Versions

**Example scenario - Minor bump:**
- Current version: `v1.0.0`
- Goal: Add new feature (minor bump)

**Steps:**
1. Run Bump Version workflow
2. Select bump type: `minor`
3. Select target branch: `main`
4. **Result**: Creates `v1.1.0`, updates `v1` tag

**Example scenario - Patch bump:**
- Current version: `v1.1.0`
- Goal: Fix bug (patch bump)
- Select bump type: `patch`
- **Result**: Creates `v1.1.1`, updates `v1` tag

### Releasing a New Major Version

**Example scenario:**
- Current version: `v1.2.0` on `main`
- Goal: Release breaking changes as `v2.0.0`

**Steps:**
1. Run Bump Version workflow
2. Select bump type: `major`
3. Select target branch: `main`
4. **Result**: Creates `v2.0.0`, creates `v2` tag, **automatically creates `release/v1` branch from the last v1 commit**

**Automatic post-release actions:** The workflow automatically creates `release/v1` branch from the last v1 commit (v1.2.0) to enable continued v1 maintenance. Main branch now tracks v2.x.x development.

**Note:** Release branch creation is skipped for v0 → v1 transitions, as v0 versions typically don't require long-term maintenance.

### Patching an Older Major Version

**Example scenario:**
- Current state: `main` has `v2.0.0`, but `v1.2.0` has a critical bug
- Goal: Release `v1.2.1` with the bug fix

**Prerequisites:**
- Ensure `release/v1` branch exists (create from last v1 commit if needed)
- Cherry-pick or apply the bug fix to `release/v1` branch

**Steps:**
1. Run Bump Version workflow
2. Select bump type: `patch`
3. Select target branch: `release/v1`
4. **Result**: Creates `v1.2.1`, updates `v1` tag to point to `v1.2.1`

**Note**: The `v1` tag now points to `v1.2.1` while `v2` still points to the latest v2.x.x

### Complete Example Timeline

Here's a chronological example showing the full lifecycle:

1. **Initial Release**: Create `v0.1.0` on `main` → `v0` points to `v0.1.0`
2. **Feature Addition**: Create `v0.2.0` on `main` → `v0` points to `v0.2.0`
3. **Bug Fix**: Create `v0.2.1` on `main` → `v0` points to `v0.2.1`
4. **Promote to Stable**: Create `v1.0.0` on `main` → `v1` points to `v1.0.0`
5. **Feature Addition**: Create `v1.1.0` on `main` → `v1` points to `v1.1.0`
6. **Major Release**: Create `v2.0.0` on `main` → `v2` points to `v2.0.0`
7. **Automatic Release Branch**: `release/v1` automatically created from last v1 commit during v2.0.0 release
8. **Patch Old Version**: Create `v1.1.1` on `release/v1` → `v1` points to `v1.1.1`
9. **Continue New Version**: Create `v2.1.0` on `main` → `v2` points to `v2.1.0`

**Final state:**
- `v1` → `v1.1.1` (on `release/v1` branch)
- `v2` → `v2.1.0` (on `main` branch)

---

## Best Practices

- **Always use the Bump Version workflow**: Avoid manually creating releases to ensure consistency
- **Verify release branches**: After major version releases, verify that release branches were created automatically for the previous major version
- **Test before releasing**: Ensure all tests pass before triggering a release
- **Use semantic versioning correctly**: Follow SemVer principles for bump type selection
- **Document breaking changes**: When releasing major versions, clearly document what changed
- **Monitor workflow runs**: Check the Actions page after triggering workflows to ensure success
- **Cherry-pick carefully**: When patching old versions, carefully cherry-pick only necessary fixes to avoid introducing new issues

---

## Workflow Reference

### Bump Version Workflow Inputs

| Input | Type | Options | Description |
|-------|------|---------|-------------|
| `bump_type` | Choice | `major` / `minor` / `patch` | Type of version increment |
| `target_branch` | String | `main` / `release/vX` | Branch to create release from |

### Branch Naming Convention

- **Main branch**: `main`
- **Release branches**: `release/v{MAJOR}` (e.g., `release/v1`, `release/v2`)

### Tag Naming Convention

- **Full version tags**: `v{MAJOR}.{MINOR}.{PATCH}` (e.g., `v1.2.3`)
- **Major version tags**: `v{MAJOR}` (e.g., `v1`, `v2`)

---

## Troubleshooting

### Issue 1: "Tag already exists" error
- **Problem**: Attempting to create a version that already exists
- **Solution**: Check existing tags, ensure you're bumping from the correct branch

### Issue 2: "Branch does not exist" error
- **Problem**: Selected a release branch that hasn't been created yet
- **Solution**: Create the release branch first, or select `main` if working on the latest major version

### Issue 3: "Major version mismatch" error
- **Problem**: Trying to create a v2.x.x release from `release/v1` branch
- **Solution**: Ensure you're using the correct branch for the major version you want to release

### Issue 4: "First releases must start from main" error
- **Problem**: Attempting to create the first release from a release branch
- **Solution**: Always create the first release from `main` branch

### Issue 5: Release branch creation failed during major bump
- **Problem**: The automatic release branch creation step failed during a major version bump
- **Solution**: Check the workflow logs for specific error messages. Common causes include: branch already exists (safe to ignore), no previous tags found (verify git history), or permission issues (check repository settings). You can manually create the release branch using `git branch release/v{MAJOR} {commit_sha}` and `git push origin release/v{MAJOR}` if needed.

---

## Additional Resources

- [Semantic Versioning Specification](https://semver.org/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Repository Actions Page](https://github.com/d-world/d-flows/actions)
- [Repository Releases Page](https://github.com/d-world/d-flows/releases)
- [Repository Tags Page](https://github.com/d-world/d-flows/tags)