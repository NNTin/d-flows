# Integration Testing Guide 🧪

> Comprehensive guide for integration testing of multi-workflow version management scenarios

## Table of Contents

- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Integration Test Suite Overview](#integration-test-suite-overview)
- [Running Integration Tests](#running-integration-tests)
- [Understanding Test Results](#understanding-test-results)
- [Test Scenario Details](#test-scenario-details)
- [Rollback and Error Recovery Testing](#rollback-and-error-recovery-testing)
- [Backward Compatibility Testing](#backward-compatibility-testing)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Limitations and Known Issues](#limitations-and-known-issues)
- [Contributing](#contributing)
- [Reference](#reference)

## Introduction

Integration testing validates the complete version management system by testing multi-workflow interactions, state transitions, and end-to-end scenarios. While unit tests (see [ACT_USAGE.md](./ACT_USAGE.md)) test individual workflows in isolation, integration tests verify that workflows work correctly together and maintain system integrity across complete release cycles.

### What Integration Tests Validate

- ✅ **Complete Release Cycles**: Full workflows from version bump through release creation
- ✅ **Multi-Workflow Orchestration**: bump-version → release workflow chains
- ✅ **State Transitions**: Git state management across workflow boundaries
- ✅ **Error Recovery**: Graceful failure handling and recovery procedures
- ✅ **Backward Compatibility**: v0 users not affected by v1.0.0 release
- ✅ **Release Branch Management**: Automatic branch creation and maintenance
- ✅ **Major Tag Stability**: Tag updates don't break existing references

### When to Run Integration Tests

- **Before releases**: Validate complete release cycle before production release
- **After major changes**: Ensure workflow modifications don't break orchestration
- **In CI/CD pipelines**: Automated validation on all branches
- **Regularly**: Schedule periodic runs to catch regressions

### Integration vs. Unit Testing

| Aspect | Unit Tests | Integration Tests |
|--------|-----------|-------------------|
| Scope | Individual workflows | Multi-workflow scenarios |
| Input | Specific test fixtures | Complete release cycles |
| Validation | Workflow outputs | System state and transitions |
| Speed | Fast (< 1 minute each) | Slower (2-5 minutes per scenario) |
| Use Case | Development, debugging | Pre-release validation |

## Prerequisites

Before running integration tests, ensure you have:

1. ✅ Completed setup from [ACT_SETUP_GUIDE.md](./ACT_SETUP_GUIDE.md)
   - Docker running
   - act tool installed
   - `.actrc` configuration file
   - `.secrets` file with Docker credentials

2. ✅ Understanding of version management from [VERSIONING.md](./VERSIONING.md)
   - Version numbering scheme (semantic versioning)
   - Release branch model
   - Major version tag behavior
   - v0 → v1 promotion requirements

3. ✅ Familiarity with unit testing from [ACT_USAGE.md](./ACT_USAGE.md)
   - How to run act commands
   - Test fixture format
   - Workflow execution patterns

4. ✅ Git knowledge
   - Basic git commands (tag, branch, checkout)
   - Understanding of HEAD references
   - Ability to diagnose git state issues

## Integration Test Suite Overview

### Orchestration Script: `run-integration-tests.ps1`

The main integration test orchestration script (`run-integration-tests.ps1`) handles:

- **Test Execution**: Runs test scenarios sequentially
- **Git State Management**: Sets up and cleans up git state between tests
- **Output Capture**: Logs workflow execution details
- **Result Validation**: Checks git state after each test
- **Report Generation**: Creates console and JSON reports
- **Error Handling**: Continues running remaining tests if one fails

### Available Test Scenarios

| Scenario | File | Purpose |
|----------|------|---------|
| **CompleteReleaseCycle** | `v0-to-v1-release-cycle.json` | v0.1.1 → v1.0.0 complete flow |
| **MultiStepVersionProgression** | `multi-step-version-progression.json` | Sequential version bumps |
| **ReleaseBranchLifecycle** | `release-branch-lifecycle.json` | Release branch creation & maintenance |
| **DuplicateTagRecovery** | `rollback-duplicate-tag.json` | Error recovery from duplicate tags |
| **InvalidBranchRecovery** | `rollback-invalid-branch.json` | Error recovery from invalid branches |
| **FailedReleaseRetry** | `rollback-failed-release.json` | Manual retry after release failure |
| **V0BackwardCompatibility** | `backward-compatibility-v0.json` | v0 users after v1.0.0 release |
| **MajorTagStability** | `major-tag-stability.json` | Major tag update behavior |

### Test Categories

**Release Cycles** (validate complete workflows):
- `CompleteReleaseCycle` - v0.1.1 → v1.0.0 major release
- `MultiStepVersionProgression` - All bump types in sequence
- `ReleaseBranchLifecycle` - Release branch creation and maintenance

**Error Recovery** (validate resilience):
- `DuplicateTagRecovery` - Recovery from duplicate tag errors
- `InvalidBranchRecovery` - Recovery from invalid branch errors
- `FailedReleaseRetry` - Recovery from failed release workflow

**Backward Compatibility** (validate compatibility):
- `V0BackwardCompatibility` - v0 users unaffected by v1 release
- `MajorTagStability` - Major tag update behavior

## Running Integration Tests

### Quick Start

```powershell
# Run all integration tests
.\run-integration-tests.ps1

# Run specific scenario
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle

# Run with verbose output for debugging
.\run-integration-tests.ps1 -Verbose

# Generate JSON report
.\run-integration-tests.ps1 -ReportFormat JSON -ReportPath ./test-results.json

# Run both console and JSON reporting
.\run-integration-tests.ps1 -ReportFormat Both -ReportPath ./test-results.json
```

### Running Specific Scenarios

```powershell
# Test v0 → v1 release
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle

# Test all bump types
.\run-integration-tests.ps1 -Scenario MultiStepVersionProgression

# Test release branch functionality
.\run-integration-tests.ps1 -Scenario ReleaseBranchLifecycle

# Test error recovery
.\run-integration-tests.ps1 -Scenario DuplicateTagRecovery
.\run-integration-tests.ps1 -Scenario InvalidBranchRecovery

# Test backward compatibility
.\run-integration-tests.ps1 -Scenario V0BackwardCompatibility
```

### Advanced Usage

**Run all error recovery tests:**
```powershell
@("DuplicateTagRecovery", "InvalidBranchRecovery", "FailedReleaseRetry") | ForEach-Object {
    .\run-integration-tests.ps1 -Scenario $_
}
```

**Run all backward compatibility tests:**
```powershell
@("V0BackwardCompatibility", "MajorTagStability") | ForEach-Object {
    .\run-integration-tests.ps1 -Scenario $_
}
```

**Full test suite with JSON reporting:**
```powershell
.\run-integration-tests.ps1 -ReportFormat JSON -ReportPath ./full-results.json -Verbose
```

## Understanding Test Results

### Console Output

Test output shows:
- ✅ Green checkmark for passed tests
- ❌ Red X for failed tests
- Test name and duration
- Error messages (if failed)

Example:
```
================================================================================
🧪 Integration Test Suite - d-flows Version Management System
================================================================================
Repository: C:/privat/gitssh/d-flows
Start Time: 2025-11-05T14:30:00Z
Report Format: Console

Running 8 test(s): (All)

─────────────────────────────────────────────────────────────────────────────
🎯 Complete v0.1.1 to v1.0.0 Release Cycle
─────────────────────────────────────────────────────────────────────────────

✅ PASS | Complete v0.1.1 to v1.0.0 Release Cycle (42.15s)
```

### Test Status Indicators

- **✅ PASS**: Test completed successfully, all validations passed
- **❌ FAIL**: Test failed, see error message for details
- **⏭️  SKIP**: Test was skipped (specified scenario not selected)

### JSON Report

JSON reports include:
- Test execution metadata (date, duration, repository)
- Test summary (total, passed, failed)
- Per-test results with timestamps and durations
- Failure details and error messages

Example JSON structure:
```json
{
  "TestSuite": "Integration Tests",
  "ExecutionDate": "2025-11-05T14:30:00Z",
  "Duration": 425.3,
  "Summary": {
    "Total": 8,
    "Passed": 8,
    "Failed": 0,
    "SkippedTests": 0
  },
  "Tests": [
    {
      "Name": "Complete v0.1.1 to v1.0.0 Release Cycle",
      "Scenario": "CompleteReleaseCycle",
      "Passed": true,
      "Duration": 42.15,
      "Error": null
    }
  ]
}
```

### Common Failure Patterns

**"Git state not cleaned up between runs"**
- Solution: Run `setup-test-git-state.ps1 -Scenario Reset` before retrying

**"Workflow execution timeout"**
- Check Docker is running: `docker ps`
- Ensure act images are downloaded: `act --pull`

**"Tag validation failed"**
- Verify git state: `git tag -l` and `git branch -a`
- Check if setup-test-git-state created expected tags

**"Version calculation incorrect"**
- Review workflow output logs in verbose mode
- Check VERSIONING.md for expected behavior

## Test Scenario Details

### 1. Complete v0.1.1 to v1.0.0 Release Cycle

**Purpose**: Validates the critical v0 → v1 major version promotion scenario

**Steps**:
1. Setup v0.2.1 tag on main branch
2. Execute bump-version workflow (should calculate v1.0.0)
3. Validate version calculation is correct
4. Execute release workflow (should create v1.0.0 and v1 tags)
5. Validate release artifacts (v1.0.0 tag, v1 major tag)
6. Validate no release/v0 branch created
7. Validate backward compatibility (v0 tag still accessible)

**Expected Outcomes**:
- NEW_VERSION = 1.0.0
- v1.0.0 tag created
- v1 major tag created and points to v1.0.0
- No release/v0 branch created
- v0.2.1 tag still accessible
- v0 and v1 tags coexist

**Common Issues**:
- "v1.0.0 tag not created" → Check release workflow execution
- "v0 tag missing" → Verify backward compatibility logic in release workflow
- "release/v0 branch created" → Check bump-version shouldn't create v0 branch

### 2. Multi-Step Version Progression

**Purpose**: Tests all bump types in sequence with correct version calculation

**Steps**:
1. Setup clean state (no tags)
2. Execute first release (v0.1.0)
3. Execute patch bump (v0.1.0 → v0.1.1)
4. Execute minor bump (v0.1.1 → v0.2.0)
5. Execute major bump (v0.2.0 → v1.0.0)
6. Validate each step's version calculation
7. Validate tag creation at each step
8. Validate major tag updates

**Expected Outcomes**:
- Each bump type executes successfully
- Version progression follows semantic versioning
- Patch bump only increments patch component
- Minor bump resets patch to 0
- Major bump resets minor and patch to 0
- All tags exist (v0.1.0, v0.1.1, v0.2.0, v1.0.0)
- Major tags updated (v0 → v1)

**Validation Points**:
- NEW_VERSION outputs match expected versions
- Git tags created for each version
- Major tag progression v0 → v1

### 3. Release Branch Lifecycle

**Purpose**: Tests automatic release branch creation and parallel major version maintenance

**Steps**:
1. Setup v1.2.0 tag on main
2. Execute major bump (v1.2.0 → v2.0.0)
3. Validate release/v1 branch created
4. Validate release/v1 branch from v1.2.0 commit
5. Execute patch on release/v1 (v1.2.0 → v1.2.1)
6. Execute minor on main (v2.0.0 → v2.1.0)
7. Validate both major versions maintained independently

**Expected Outcomes**:
- v2.0.0 calculated on main
- release/v1 branch created from v1.2.0
- v2.0.0 and v2 tags created
- v1.2.1 created on release/v1
- v2.1.0 created on main
- v1 tag points to v1.2.1
- v2 tag points to v2.1.0
- No cross-contamination between branches

**Validation Points**:
- Branch existence and naming
- Tag points-to relationships
- Version calculations on different branches
- Major tag independence

## Rollback and Error Recovery Testing

### Overview of Error Recovery Tests

The integration test suite includes three error recovery scenarios that validate the system's resilience:

1. **Duplicate Tag Error Recovery** - Detects and recovers from duplicate tags
2. **Invalid Branch Format Error Recovery** - Handles invalid branch names
3. **Failed Release Retry** - Recovers from failed release workflows

### How Error Recovery Works

**Workflow Error Detection**:
- Workflows validate inputs before making changes
- Errors are detected early to prevent partial state changes
- Clear error messages explain the problem and recovery steps

**Graceful Failure**:
- Workflows exit cleanly without side effects
- No partial tags/branches created
- State remains consistent for retry

**Recovery Process**:
1. Identify the error from workflow output
2. Fix the underlying issue (delete tag, switch branch, etc.)
3. Retry the workflow
4. Validate success after recovery

### Duplicate Tag Error Recovery

**Scenario**: Two tags with consecutive versions exist (v0.1.0 and v0.1.1)

**Workflow Behavior**:
- Workflow detects duplicate
- Exits with error message
- No new tags/branches created

**Recovery Steps**:
```powershell
# Delete the conflicting tag
git tag -d v0.1.1

# Retry the bump workflow
.\run-integration-tests.ps1 -Scenario DuplicateTagRecovery
```

**Expected Result**: Version bumps successfully after removing duplicate

### Invalid Branch Format Error Recovery

**Scenario**: Running bump-version on `feature/test-branch` instead of `main` or `release/vX`

**Workflow Behavior**:
- Workflow validates branch format
- Returns error explaining valid formats
- No changes made to repository

**Recovery Steps**:
```powershell
# Switch to valid branch
git checkout main

# Retry the bump workflow
.\run-integration-tests.ps1 -Scenario InvalidBranchRecovery
```

**Expected Result**: Workflow succeeds on valid branch

### Failed Release Workflow Retry

**Scenario**: bump-version succeeds but release workflow fails or doesn't run

**Workflow Behavior**:
- bump-version completes independently
- Version calculation is stable
- Release workflow can be run separately

**Recovery Steps**:
```powershell
# Manually trigger release workflow with calculated version
act workflow_call -W .github/workflows/release.yml -e tests/release/valid-release-v0.1.1.json
```

**Expected Result**: Release workflow completes successfully

## Backward Compatibility Testing

### Why Backward Compatibility Matters

When releasing v1.0.0 after v0.2.1:
- Users may still reference v0 in their workflows
- Existing integrations depend on v0 tags
- Major version release should be non-breaking

### V0 Backward Compatibility Test

**What Gets Tested**:
1. v0 major tag exists and points to latest v0.x.x
2. v1 major tag exists and points to v1.0.0
3. All individual version tags remain accessible
4. Tag resolution works correctly
5. Users pinned to v0 get v0.2.1
6. Users pinned to v1 get v1.0.0

**Example User Scenarios**:
```yaml
# User pinned to v0 gets v0.2.1 (latest v0 version)
- uses: d-flows/action@v0

# User pinned to v0.2.1 gets exactly v0.2.1
- uses: d-flows/action@v0.2.1

# User pinned to v1 gets v1.0.0 (latest v1 version)
- uses: d-flows/action@v1

# User pinned to v1.0.0 gets exactly v1.0.0
- uses: d-flows/action@v1.0.0
```

### Major Tag Stability Test

**What Gets Tested**:
1. v1 tag updates to latest when new versions released
2. Previous versions still accessible (v1.0.0, v1.1.0 still exist)
3. Users pinned to v1 automatically get updates
4. Users pinned to v1.0.0 stay on v1.0.0
5. Force-push operations don't break references

**Version Progression Example**:
```
v1.0.0 released
  ↓
v1 tag points to v1.0.0

v1.1.0 released
  ↓
v1 tag updated to point to v1.1.0
v1.0.0 still accessible

v1.2.0 released
  ↓
v1 tag updated to point to v1.2.0
v1.0.0 and v1.1.0 still accessible
```

## CI/CD Integration

### GitHub Actions Integration

Example workflow to run integration tests in CI/CD:

```yaml
name: Integration Tests
on: [pull_request, workflow_dispatch, push]
jobs:
  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Run integration tests
        run: |
          pwsh -File ./run-integration-tests.ps1 -Verbose -ReportFormat JSON -ReportPath test-results.json
      
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: integration-test-results
          path: test-results.json
      
      - name: Comment PR with results
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v6
        with:
          script: |
            const fs = require('fs');
            const results = JSON.parse(fs.readFileSync('test-results.json', 'utf8'));
            const summary = results.Summary;
            const comment = `
            ## Integration Test Results
            - ✅ Passed: ${summary.Passed}
            - ❌ Failed: ${summary.Failed}
            - Total: ${summary.Total}
            `;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: comment
            });
```

### JSON Report Processing

Parse JSON reports for CI/CD analysis:

```powershell
$report = Get-Content test-results.json | ConvertFrom-Json

# Check if all tests passed
if ($report.Summary.Failed -eq 0) {
  Write-Host "✅ All integration tests passed"
  exit 0
} else {
  Write-Host "❌ $($report.Summary.Failed) test(s) failed"
  $report.Tests | Where-Object { -not $_.Passed } | ForEach-Object {
    Write-Host "  Failed: $($_.Name)"
    Write-Host "  Error: $($_.Error)"
  }
  exit 1
}
```

### Setting Up Automated Runs

**Schedule integration tests before releases**:
```yaml
name: Pre-Release Integration Tests
on:
  schedule:
    - cron: '0 2 * * 0'  # Weekly on Sunday
  workflow_dispatch:
```

**Run on every main branch commit**:
```yaml
on:
  push:
    branches: [main]
```

**Run on pull requests that modify workflows**:
```yaml
on:
  pull_request:
    paths:
      - '.github/workflows/**'
      - 'run-integration-tests.ps1'
```

## Troubleshooting

### Common Integration Test Failures

#### 1. "Test fails with 'tag already exists'"

**Symptom**: Test fails on first run with tag error

**Cause**: Git state not cleaned up between test runs

**Solution**:
```powershell
# Reset git state completely
.\setup-test-git-state.ps1 -Scenario Reset

# Verify state is clean
git tag -l     # Should be empty
git branch -a  # Should only show main

# Retry test
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle
```

#### 2. "Workflow execution timeout or hangs"

**Symptom**: Test script hangs waiting for workflow completion

**Cause**: Docker not running or act images not available

**Solution**:
```powershell
# Check Docker is running
docker ps

# If not, start Docker
# (on Windows, usually via Docker Desktop)

# Pull latest act images
act --pull

# Verify act setup
.\verify-act-setup.ps1

# Retry test
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle
```

#### 3. "Tag validation failed - tag doesn't exist"

**Symptom**: Test completes but tag validation fails

**Cause**: Workflow executed but didn't create expected tag

**Solution**:
```powershell
# Run with verbose output to see workflow logs
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle -Verbose

# Check git state manually
git tag -l
git log --oneline

# Verify test fixture is correct
Get-Content tests/bump-version/major-bump-v0-to-v1.json | ConvertFrom-Json

# Check workflow syntax
act --list
```

#### 4. "Version calculation incorrect"

**Symptom**: NEW_VERSION output doesn't match expected value

**Cause**: Workflow version calculation logic error or test fixture mismatch

**Solution**:
```powershell
# Review VERSIONING.md for expected behavior
Get-Content VERSIONING.md

# Run bump-version manually with fixture to debug
act workflow_dispatch -W .github/workflows/bump-version.yml \
  -e tests/bump-version/major-bump-v0-to-v1.json \
  --verbose

# Check bump-version.yml workflow logic
Get-Content .github/workflows/bump-version.yml

# Verify git state matches fixture expectations
git tag -l
git branch -a
```

#### 5. "Reset script leaves behind test files"

**Symptom**: Test files from .test-state/ remain in working tree

**Cause**: File system cleanup issue

**Solution**:
```powershell
# Manually clean up
Remove-Item -Path .test-state -Recurse -Force -ErrorAction SilentlyContinue

# Reset working tree
git reset --hard
git clean -fd

# Verify clean state
git status
```

### Debugging Integration Tests

**Enable Verbose Output**:
```powershell
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle -Verbose
```

**Capture Detailed Logs**:
```powershell
# Save logs to file
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle -Verbose | Tee-Object -FilePath test-debug.log
```

**Test Specific Workflow**:
```powershell
# Test bump-version workflow directly
act workflow_dispatch -W .github/workflows/bump-version.yml \
  -e tests/bump-version/major-bump-v0-to-v1.json \
  --verbose
```

**Inspect Git State**:
```powershell
# Check all tags
git tag -l -n1

# Check all branches
git branch -av

# Check specific tag details
git show v1.0.0
```

**Check Docker Logs**:
```powershell
# See container logs
docker logs $(docker ps -l -q)

# Clean up containers
docker container prune
```

## Best Practices

### Running Integration Tests Effectively

1. **Always Clean Up Before Testing**:
   ```powershell
   .\setup-test-git-state.ps1 -Scenario Reset
   ```

2. **Start with Individual Scenarios**:
   ```powershell
   # Test one scenario first
   .\run-integration-tests.ps1 -Scenario CompleteReleaseCycle
   ```

3. **Use Verbose Mode for Debugging**:
   ```powershell
   .\run-integration-tests.ps1 -Scenario CompleteReleaseCycle -Verbose
   ```

4. **Run Full Suite Before Releases**:
   ```powershell
   .\run-integration-tests.ps1
   ```

5. **Save Reports for Analysis**:
   ```powershell
   .\run-integration-tests.ps1 -ReportFormat JSON -ReportPath releases/v1.0.0-results.json
   ```

### Test Development Best Practices

1. **Keep integration test scenarios focused** - Each scenario should test one concept
2. **Document expected behavior** - Include clear comments in scenario JSON
3. **Validate at each step** - Don't skip validation after each workflow execution
4. **Test error conditions** - Include negative test cases for error recovery
5. **Maintain git state** - Always clean up after tests
6. **Version control test files** - Keep scenario JSON files in version control
7. **Review test coverage** - Ensure all critical paths are tested

### Performance Considerations

- **Single scenario**: ~30-60 seconds
- **All scenarios**: ~5-10 minutes
- **With verbose output**: +20-30% time
- **Run schedule**: Before releases or on schedule, not on every commit

## Limitations and Known Issues

### Act Tool Limitations

1. **Cannot fully simulate GitHub release creation** - Act cannot interact with GitHub API to create releases
   - **Workaround**: Validate release workflow inputs and tag creation logic

2. **Cannot simulate workflow triggers** - Act cannot trigger dependent workflows via `gh workflow run`
   - **Workaround**: Manually execute dependent workflows in test

3. **Limited secret handling** - Acts secrets are simpler than GitHub Secrets
   - **Workaround**: Test with environment variables for CI/CD scenarios

4. **Local environment differences** - Local machine differences from GitHub Actions runners
   - **Workaround**: Run in GitHub Actions as final validation

### Git State Management

1. **Tag name collisions** - Using common tag names might conflict with real releases
   - **Workaround**: Use dedicated test tag naming scheme
   - **Implementation**: Tests use unique tag names (e.g., v0.1.0, v1.0.0 for tests)

2. **Branch cleanup** - Test branches may not clean up if tests interrupted
   - **Workaround**: Manually run `git branch -D release/v1` if needed

3. **Untracked files** - Test files created in `.test-state/` directory
   - **Workaround**: Directory is in `.gitignore`, use `setup-test-git-state.ps1 -Scenario Reset` to clean

### Performance Considerations

1. **Docker startup time** - First test run slower due to container startup
2. **Large test suites** - Running all 8 tests takes 5-10 minutes
3. **Network dependencies** - Act pull downloads images from internet

### Workarounds and Mitigation

- Run on fast machines with SSD for better performance
- Warm up Docker before running tests
- Use CI/CD for comprehensive testing
- Use unit tests for rapid development iteration

## Contributing

### Adding New Integration Test Scenarios

1. **Create scenario JSON file** in `tests/integration/`
   ```
   tests/integration/my-new-scenario.json
   ```

2. **Define scenario structure**:
   ```json
   {
     "name": "My New Test Scenario",
     "description": "What this scenario tests",
     "steps": [
       {
         "name": "Step 1",
         "action": "setup-git-state|run-workflow|validate-state",
         ...
       }
     ],
     "cleanup": { "action": "reset-git-state" },
     "expectedDuration": "30-60 seconds",
     "tags": ["category", "keyword"]
   }
   ```

3. **Implement test function** in `run-integration-tests.ps1`:
   ```powershell
   function Test-MyNewScenario {
     # Implementation
   }
   ```

4. **Add to scenarios dictionary**:
   ```powershell
   $Scenarios = @{
     "MyNewScenario" = @{
       Name = "My New Test Scenario"
       Description = "..."
       File = "my-new-scenario.json"
       Tags = "category", "keyword"
     }
   }
   ```

5. **Document in this guide** - Add section in "Test Scenario Details"

6. **Test your test** - Run and verify it works correctly

### Test Scenario JSON Format Specification

```json
{
  "name": "String - Display name of scenario",
  "description": "String - Detailed description of what is tested",
  "steps": [
    {
      "name": "String - Step description",
      "action": "Enum: setup-git-state|run-workflow|validate-state|execute-command|comment",
      
      // For setup-git-state
      "scenario": "String - setup-test-git-state scenario name",
      "expectedState": {
        "tags": ["v0.1.0"],
        "branches": ["main", "release/v1"],
        "currentBranch": "main"
      },
      
      // For run-workflow
      "workflow": "String - workflow filename",
      "fixture": "String - path to test fixture JSON",
      "expectedFailure": "Boolean - whether workflow should fail",
      "expectedErrorMessage": "String or Array - expected error text",
      "expectedOutputs": {
        "KEY": "expected value"
      },
      
      // For validate-state
      "checks": [
        { "type": "tag-exists|branch-exists|...", ...props }
      ]
    }
  ],
  "cleanup": {
    "action": "reset-git-state"
  },
  "expectedDuration": "String - estimated test duration",
  "tags": ["Array", "of", "keywords"]
}
```

## Reference

### Documentation

- [VERSIONING.md](./VERSIONING.md) - Version management strategy and workflow behavior
- [ACT_USAGE.md](./ACT_USAGE.md) - Unit testing guide for individual workflows
- [ACT_SETUP_GUIDE.md](./ACT_SETUP_GUIDE.md) - Setup and configuration guide
- [README.md](./README.md) - Project overview and quick start

### Test Files

- `run-integration-tests.ps1` - Main orchestration script
- `setup-test-git-state.ps1` - Git state setup helper
- `tests/integration/*.json` - Test scenario definitions
- `tests/bump-version/*.json` - Bump-version workflow test fixtures
- `tests/release/*.json` - Release workflow test fixtures

### Workflows

- `.github/workflows/bump-version.yml` - Version calculation and bump workflow
- `.github/workflows/release.yml` - Release creation workflow

### External Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Act Documentation](https://github.com/nektos/act)
- [Semantic Versioning](https://semver.org/)
- [Git Tagging](https://git-scm.com/book/en/v2/Git-Basics-Tagging)

---

🎯 **Integration tests are essential for validating complex multi-workflow scenarios before production releases.** Start with unit tests for development, then use integration tests to validate complete release cycles before major releases.
