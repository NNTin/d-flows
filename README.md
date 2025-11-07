# d-flows

[![Version](https://img.shields.io/github/v/release/nntin/d-flows?sort=semver&label=Version)](https://github.com/nntin/d-flows/releases) [![CI](https://img.shields.io/github/actions/workflow/status/nntin/d-flows/pr-ci.yml?branch=main&label=CI)](https://github.com/nntin/d-flows/actions)

## Documentation

- [README.md](./README.md) - Overview and quick start
- [VERSIONING.md](./docs/VERSIONING.md) - Version management strategy and workflows
- [ACT_SETUP_GUIDE.md](./docs/ACT_SETUP_GUIDE.md) - Setup for local testing with act
- [ACT_USAGE.md](./docs/ACT_USAGE.md) - Unit testing guide and examples

## Test State Management

The d-flows project uses a temporary directory approach for managing test state, ensuring isolated test execution and automatic cleanup of test artifacts.

### Storage Location

Test state is stored in system temporary directories with unique GUID-based naming to ensure test isolation:

- **Pattern:** `d-flows-test-state-<guid>`
- **Windows:** `%TEMP%\d-flows-test-state-<guid>` (typically `C:\Users\<username>\AppData\Local\Temp\`)
- **Linux/macOS:** `/tmp/d-flows-test-state-<guid>`

Each test execution generates a unique GUID, preventing conflicts when multiple tests run simultaneously or when tests are run on shared systems.

### Directory Structure

Within each test state directory:

- **`backup/`** - Git state backups including tags, branches, and manifests for test isolation
- **`logs/`** - Test execution logs and JSON test case definitions
- **`test-tags.txt`** - Generated tag definitions used by the bump-version workflow

### Docker Integration

When running tests with `act` (local GitHub Actions runner):

- The temporary directory is mounted to `/tmp/test-state` inside containers via `--container-options`
- The `TEST_STATE_PATH` environment variable is set to `/tmp/test-state` for workflow access
- This allows workflows running in containers to access test fixtures from the host filesystem
- Path conversion automatically handles Windows/Linux differences for Docker Desktop

### Cleanup Behavior

Test state directories are automatically removed after test execution completes:

- By default, `Remove-TestStateDirectory` is called after all tests finish
- On Windows, the directory is removed from `%TEMP%`; on Linux from `/tmp`
- If cleanup fails, test execution continues with a warning

### Manual Cleanup and Debugging

To preserve test state for debugging:

- Use the `-SkipCleanup` parameter when running tests: `.\Run-ActTests.ps1 -SkipCleanup`
- The full path to the test state directory is displayed in the output
- You can then manually inspect fixture files, logs, and git state backups
- Directories can be safely deleted from `%TEMP%` (Windows) or `/tmp` (Linux) when no longer needed

To clean up orphaned directories manually:

- **Windows PowerShell:** `Remove-Item -Recurse -Force "$env:TEMP\d-flows-test-state-*"`
- **Linux/macOS:** `rm -rf /tmp/d-flows-test-state-*`
