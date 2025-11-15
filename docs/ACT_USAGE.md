# ACT Usage Guide 🎭

> Comprehensive testing documentation for GitHub Actions workflows using act

This document complements the [`ACT_SETUP_GUIDE.md`](./ACT_SETUP_GUIDE.md) and focuses specifically on testing the `step-summary.yml` and `discord-notify.yml` workflows with various input combinations and scenarios.

## Prerequisites 📋

Before using this guide, ensure you have:

1. ✅ Completed the setup in [`ACT_SETUP_GUIDE.md`](./ACT_SETUP_GUIDE.md)
2. ✅ Valid `.actrc` configuration file
3. ✅ `.secrets` file created from `.secrets.template` (for Discord webhook testing)
4. 🐳 Docker running and act installed

## Test Fixtures Overview 📁

The `tests/` directory contains organized JSON event files for different test scenarios:

```
tests/
├── step-summary/           # Step Summary workflow tests
│   ├── minimal.json        # Required inputs only
│   ├── with-title.json     # With custom title
│   ├── with-overwrite.json # With overwrite enabled
│   └── full.json          # All inputs provided
└── discord-notify/         # Discord Notify workflow tests
    ├── minimal-message.json    # Basic message type
    ├── minimal-embed.json      # Basic embed type
    ├── embed-with-color.json   # Embed with custom color
    ├── embed-with-fields.json  # Embed with structured fields
    ├── custom-identity.json    # Custom username/avatar
    ├── full-embed.json        # All embed options
    ├── input-webhook.json     # Webhook via inputs (local testing)
    └── no-webhook.json        # Graceful failure test
```

## Step Summary Workflow Testing 📝

### Using JSON Event Files

#### Minimal Test (Required Only)
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/minimal.json
```

#### With Custom Title
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/with-title.json
```

#### With Overwrite Enabled
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/with-overwrite.json
```

#### Full Feature Test (All Inputs)
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/full.json
```

### Direct Command-Line Inputs

For quick testing without JSON files:

#### Basic Test
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml --job set-summary `
  --input markdown="# Quick Test`n`nThis is a direct command-line test."
```

#### With Title and Overwrite
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml --job set-summary `
  --input markdown="## CLI Test`n`n✅ All systems operational" `
  --input title="Command Line Test" `
  --input overwrite=true
```

## Discord Notify Workflow Testing 💬

### Using JSON Event Files

#### Minimal Message Type
```powershell
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/minimal-message.json
```

#### Minimal Embed Type
```powershell
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/minimal-embed.json
```

#### Embed with Custom Color
```powershell
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/embed-with-color.json
```

#### Embed with Structured Fields
```powershell
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/embed-with-fields.json
```

#### Custom Identity (Username/Avatar)
```powershell
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/custom-identity.json
```

#### Full Embed Features
```powershell
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/full-embed.json
```

#### Input Webhook (Local Testing)
```powershell
# Using webhook_url via inputs instead of secrets (acceptable for local testing)
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/input-webhook.json
```
> **Note**: While using `webhook_url` via inputs is supported for local testing, using secrets is the preferred and more secure approach for production workflows.

#### Graceful Failure (No Webhook)
```powershell
# Remove webhook from secrets temporarily or use empty secrets
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/no-webhook.json --secret-file /dev/null
```

### Direct Command-Line Inputs

For quick testing without JSON files:

#### Simple Message
```powershell
act workflow_call -W .github/workflows/discord-notify.yml `
  --input message_type="message" `
  --input content="Quick test from command line!"
```

#### Basic Embed
```powershell
act workflow_call -W .github/workflows/discord-notify.yml `
  --input message_type="embed" `
  --input title="CLI Test" `
  --input description="Testing from command line"
```

#### Colored Embed with Fields
```powershell
act workflow_call -W .github/workflows/discord-notify.yml `
  --input message_type="embed" `
  --input title="Build Status" `
  --input description="Build completed successfully" `
  --input color="3066993" `
  --input fields='[{"name":"Status","value":"✅ Success","inline":true}]'
```

## Secrets Management 🔐

### Recommended: Using `.secrets` File
1. Copy `.secrets.template` to `.secrets`
2. Add your Discord webhook URL:
   ```
   webhook_url=https://discord.com/api/webhooks/your/webhook/url
   ```

### Alternative: Command-Line Secrets
```powershell
act workflow_call -W .github/workflows/discord-notify.yml `
  -s webhook_url="https://discord.com/api/webhooks/your/webhook/url" `
  -e tests/discord-notify/minimal-embed.json
```

### Environment Variables
```powershell
$env:webhook_url="https://discord.com/api/webhooks/your/webhook/url"
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/minimal-embed.json
```

## Advanced Testing Scenarios 🚀

### Running Specific Jobs Only
```powershell
# Run only the 'send-notification' job in discord-notify workflow
act workflow_call -W .github/workflows/discord-notify.yml --job send-notification -e tests/discord-notify/minimal-embed.json
```

### Verbose Output for Debugging
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/full.json --verbose
```

### Dry-Run Mode (Validation Only)
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/minimal.json --dryrun
```

### Testing with Different Runner Images
```powershell
# Use a specific Ubuntu version
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/minimal.json -P ubuntu-latest=ubuntu:20.04
```

### Offline Mode (Cached Actions Only)
```powershell
act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/minimal.json --action-offline-mode
```

## Tips and Best Practices 💡

### Pre-Flight Checks
```powershell
# Verify workflow syntax
act --list

# Check available workflows and jobs
act -l
```

### Debugging Docker Issues
```powershell
# Check Docker logs if workflow fails
docker logs $(docker ps -l -q)

# Clean up stopped containers
docker container prune
```

### Testing Without Secrets
```powershell
# For validation-only runs (Discord workflow will skip notification)
act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/minimal-embed.json --secret-file /dev/null
```

### JSON Validation
```powershell
# Validate JSON syntax before running
Get-Content tests/step-summary/full.json | ConvertFrom-Json
```

## Common Issues 🔧

### Webhook URL Not Working
- 🔍 **Problem**: Discord notifications not appearing
- ✅ **Solution**: Test with webhook.site or similar mock services:
  ```powershell
  # Get a test webhook URL from https://webhook.site
  act workflow_call -W .github/workflows/discord-notify.yml `
    -s webhook_url="https://webhook.site/your-unique-id" `
    -e tests/discord-notify/minimal-message.json
  ```

### JSON Parsing Errors
- 🔍 **Problem**: `invalid character` errors
- ✅ **Solution**: Validate JSON syntax and escape special characters:
  ```powershell
  # Test JSON syntax
  Get-Content tests/discord-notify/full-embed.json | ConvertFrom-Json
  ```

### Step Summary Not Visible
- 🔍 **Problem**: Can't see step summary output
- ✅ **Solution**: Step summaries are logged, not displayed. Check workflow logs for the summary content.

### Docker Container Issues
- 🔍 **Problem**: Container startup failures
- ✅ **Solution**: 
  ```powershell
  # Update act runner images
  act --pull

  # Clean Docker cache
  docker system prune
  ```

## Quick Reference 📚

| Test Scenario | Command | Tests |
|--------------|---------|--------|
| **Step Summary - Minimal** | `act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/minimal.json` | Required input only, default values |
| **Step Summary - With Title** | `act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/with-title.json` | Custom title functionality |
| **Step Summary - Overwrite** | `act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/with-overwrite.json` | Summary replacement vs. append |
| **Step Summary - Full** | `act workflow_dispatch -W .github/workflows/step-summary.yml -e tests/step-summary/full.json` | All input parameters |
| **Discord - Message** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/minimal-message.json` | Basic message type |
| **Discord - Embed** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/minimal-embed.json` | Basic embed type |
| **Discord - Colored** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/embed-with-color.json` | Color customization |
| **Discord - Fields** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/embed-with-fields.json` | Structured data display |
| **Discord - Identity** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/custom-identity.json` | Custom username/avatar |
| **Discord - Full** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/full-embed.json` | All embed features |
| **Discord - Input Webhook** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/input-webhook.json` | Webhook via inputs (local testing) |
| **Discord - No Webhook** | `act workflow_call -W .github/workflows/discord-notify.yml -e tests/discord-notify/no-webhook.json --secret-file /dev/null` | Graceful failure handling |

## Version Management Workflow Testing 🔄

> Testing `bump-version.yml` and `release.yml` workflows with git state management

The `bump-version.yml` and `release.yml` workflows require specific git state to function properly. We provide a comprehensive helper script to set up the correct git state for each test scenario.

### Git State Setup Helper

Use the `setup-test-git-state.ps1` script to prepare your repository for testing:

```powershell
# Setup git state for a specific test scenario
.\setup-test-git-state.ps1 -Scenario <ScenarioName>

# Run your test
act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/<test-file>.json

# Clean up when done
.\setup-test-git-state.ps1 -Scenario Reset
```

### Available Scenarios

**Bump Version Test Scenarios:**
- `FirstRelease` - Clean state for first release testing
- `MajorBumpV0ToV1` - Setup v0.2.1 tag for v1 promotion testing

**Cleanup:**
- `Reset` - Remove all test tags and branches

### Testing Workflow Examples

#### Example 1: First Release Testing

```powershell
# Setup clean state
.\setup-test-git-state.ps1 -Scenario FirstRelease

# Test first release
act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/minor-bump-main.json

# Should calculate version v0.1.0 and trigger release workflow
# Check the output for version calculation and job triggers

# Cleanup
.\setup-test-git-state.ps1 -Scenario Reset
```

#### Example 2: Patch Bump Testing

```powershell
# Setup with v0.1.0 tag
.\setup-test-git-state.ps1 -Scenario PatchBump

# Test patch bump
act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/patch-bump-main.json

# Should calculate version v0.1.1 and trigger release workflow
# Verify no release branch is created for patch bumps

# Cleanup
.\setup-test-git-state.ps1 -Scenario Reset
```

### Safety Notes

⚠️ **IMPORTANT**: The `setup-test-git-state.ps1` script creates and deletes git tags and branches. Only use it in:
- Test repositories
- Local clones of your repository
- Never on production or shared repositories

The script includes safety checks and will warn you if it doesn't detect the expected repository structure.

### Debugging Test Failures

If a test fails, check the following:

1. **Git State**: Verify the correct git state was set up:
   ```powershell
   git tag -l        # Check existing tags
   git branch -a     # Check existing branches
   git log --oneline -5  # Check recent commits
   ```

2. **Test Fixture**: Verify the JSON test fixture matches your scenario
3. **Workflow Syntax**: Use `act --list` to verify workflow syntax
4. **Dependencies**: Ensure all required GitHub Actions are available locally

### Comprehensive Test Suite

To run all bump-version tests:

```powershell
# Array of all bump-version test scenarios
$bumpTests = @(
    @{Scenario="FirstRelease"; Test="minor-bump-main.json"},
    @{Scenario="MajorBumpV0ToV1"; Test="major-bump-main.json"}
)

# Run each test
foreach ($test in $bumpTests) {
    Write-Message -Type "Info" "Testing: $($test.Test)"
    .\setup-test-git-state.ps1 -Scenario $test.Scenario
    act workflow_dispatch -W .github/workflows/bump-version.yml -e "tests/bump-version/$($test.Test)"
    .\setup-test-git-state.ps1 -Scenario Reset
    Write-Message -Type "Info" "Completed: $($test.Test)`n"
}
```

### Version Management Test Reference

| Test Scenario | Setup Command | Test Command | Expected Outcome |
|--------------|---------------|--------------|------------------|
| **First Release** | `.\setup-test-git-state.ps1 -Scenario FirstRelease` | `act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/minor-bump-main.json` | Calculate v0.1.0, trigger release |
| **Major Bump v0→v1** | `.\setup-test-git-state.ps1 -Scenario MajorBumpV0ToV1` | `act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/major-bump-main.json` | Calculate v1.0.0, trigger release |

## Integration Testing 🧪

Integration tests validate:
- ✅ Complete release cycles (v0.1.1 → v1.0.0)
- ✅ Multi-workflow orchestration (bump-version → release)
- ✅ Rollback and error recovery scenarios
- ✅ Backward compatibility for v0 users
- ✅ Release branch creation and maintenance
- ✅ Major tag stability and updates

**Quick Start:**
```powershell
# Run all integration tests
.\scripts\integration\Run-ActTests.ps1 -RunAll

# Run specific scenario
.\scripts\integration\Run-ActTests.ps1 -TestName "Complete v0.1.1 to v1.0.0 Release Cycle"

# Run with verbose output
.\scripts\integration\Run-ActTests.ps1 -TestName "Invalid Branch" -SkipBackup -SkipCleanup -Verbose
```

---

🎯 **Happy Testing!**
These test fixtures and commands provide comprehensive coverage of all workflows. These integration tests run in CI.