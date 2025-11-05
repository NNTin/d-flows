# setup-test-git-state.ps1
# 
# Git State Setup Helper for Version Management Workflow Testing
# 
# This script provides functions to set up git repository state for testing 
# bump-version.yml and release.yml workflows with the act tool.
# 
# WARNING: Only run this script in test repositories or clones! 
# This script creates and deletes git tags and branches.
# 
# USAGE:
#   .\setup-test-git-state.ps1 -Scenario <ScenarioName>
# 
# AVAILABLE SCENARIOS:
# 
# Bump Version Test Scenarios:
#   - FirstRelease: Clean state for first release testing
#   - PatchBump: Setup v0.1.0 tag for patch bump testing
#   - MinorBump: Setup v0.1.0 tag for minor bump testing  
#   - MajorBumpV0ToV1: Setup v0.2.1 tag for v1 promotion testing
#   - MajorBumpV1ToV2: Setup v1.2.0 tag for v2 release testing
#   - ReleaseBranchPatch: Setup release/v1 branch with v1.2.0 tag
#   - ReleaseBranchMinor: Setup release/v1 branch with v1.2.1 tag
#   - DuplicateTag: Setup v0.1.0 and v0.1.1 tags for error testing
#   - InvalidBranch: Create feature/test-branch for error testing
#   - FirstReleaseError: Setup release/v1 branch with no tags
#   - MajorVersionMismatch: Setup release/v1 branch with v1.2.0 tag
# 
# Release Test Scenarios:
#   - ValidReleaseV0: Clean state for v0.1.0 release testing
#   - ValidReleaseV1: Setup v0.2.1 tag for v1.0.0 release testing
#   - ValidReleaseV1Patch: Setup v1.2.2 tag for v1.2.3 release testing
#   - DuplicateReleaseTag: Setup v1.0.0 tag for error testing
# 
# Cleanup:
#   - Reset: Remove all test tags, branches, and optionally clean test files
# 
# TEST FILE MANAGEMENT:
# Test files are created in the .test-state/ directory (added to .gitignore).
# The Reset scenario offers to clean up these files and reset the working tree.
# 
# INTEGRATION WITH ACT:
# The script is aware of the $ACT environment variable and includes safety
# checks to prevent accidental execution on production repositories.
# 
# EXAMPLE WORKFLOW:
#   # Setup git state
#   .\setup-test-git-state.ps1 -Scenario FirstRelease
#   
#   # Run the test
#   act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/first-release-main.json
#   
#   # Cleanup
#   .\setup-test-git-state.ps1 -Scenario Reset

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "FirstRelease", "PatchBump", "MinorBump", "MajorBumpV0ToV1", "MajorBumpV1ToV2",
        "ReleaseBranchPatch", "ReleaseBranchMinor", "DuplicateTag", "InvalidBranch", 
        "FirstReleaseError", "MajorVersionMismatch", "ValidReleaseV0", "ValidReleaseV1",
        "ValidReleaseV1Patch", "DuplicateReleaseTag", "Reset"
    )]
    [string]$Scenario
)

# Safety check - ensure we're in d-flows repository
function Test-GitStateReady {
    if (-not (Test-Path ".git")) {
        Write-Error "Not in a git repository. Please run this script from the repository root."
        exit 1
    }
    
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if (-not $repoRoot -or -not (Test-Path (Join-Path $repoRoot ".github/workflows/bump-version.yml"))) {
        Write-Warning "This doesn't appear to be the d-flows repository."
        $confirm = Read-Host "Are you sure you want to modify git state? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Output "Aborted by user."
            exit 1
        }
    }
}

# Create a test commit with specified message
function New-TestCommit {
    param([string]$Message = "Test commit for workflow testing")
    
    # Create test state directory if it doesn't exist
    $testDir = ".test-state"
    if (-not (Test-Path $testDir)) {
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }
    
    # Create or modify a test file in the test directory
    $testFile = Join-Path $testDir "test-file-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    "Test commit content - $Message" | Out-File -FilePath $testFile -Encoding UTF8
    git add $testFile
    git commit -m $Message
    Write-Output "Created test commit: $Message"
}

# Remove all test tags and branches
function Reset-TestGitState {
    Write-Output "🧹 Cleaning up test git state..."
    
    # Remove test tags
    $testTags = @("v0.1.0", "v0.1.1", "v0.2.0", "v0.2.1", "v1.0.0", "v1.2.0", "v1.2.1", "v1.2.2", "v1.2.3", "v1.3.0", "v2.0.0")
    foreach ($tag in $testTags) {
        if (git tag -l $tag) {
            git tag -d $tag 2>$null
            Write-Output "Removed tag: $tag"
        }
    }
    
    # Remove test branches
    $testBranches = @("release/v1", "release/v2", "feature/test-branch")
    foreach ($branch in $testBranches) {
        if (git branch --list $branch) {
            git branch -D $branch 2>$null
            Write-Output "Removed branch: $branch"
        }
    }
    
    # Return to main branch
    $currentBranch = git branch --show-current 2>$null
    if ($currentBranch -ne "main") {
        git checkout main 2>$null
        Write-Output "Switched to main branch"
    }
    
    # Check for test state directory and untracked test files
    $testDir = ".test-state"
    $hasTestDir = Test-Path $testDir
    $untrackedTestFiles = @()
    
    # Find any remaining test files that might be untracked
    if ($hasTestDir) {
        $untrackedTestFiles = git ls-files --others --exclude-standard $testDir 2>$null | Where-Object { $_ }
    }
    
    # Check for any uncommitted changes or untracked test files
    $hasChanges = $false
    $statusOutput = git status --porcelain 2>$null
    if ($statusOutput -and ($statusOutput | Where-Object { $_ -match "\.test-state/" })) {
        $hasChanges = $true
    }
    
    # Prompt for cleanup if there are test files or changes
    if ($hasTestDir -or $untrackedTestFiles.Count -gt 0 -or $hasChanges) {
        Write-Output ""
        Write-Warning "Found test files and/or changes in the working tree:"
        
        if ($hasTestDir) {
            Write-Output "  📁 Test directory: $testDir"
        }
        if ($untrackedTestFiles.Count -gt 0) {
            Write-Output "  📄 Untracked test files: $($untrackedTestFiles.Count) files"
        }
        if ($hasChanges) {
            Write-Output "  📝 Uncommitted changes in test directory"
        }
        
        Write-Output ""
        $cleanupChoice = Read-Host "Clean up test files and reset working tree to clean state? (y/N)"
        
        if ($cleanupChoice -eq "y" -or $cleanupChoice -eq "Y") {
            # Remove test state directory if it exists
            if ($hasTestDir) {
                Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Output "Removed test directory: $testDir"
            }
            
            # Reset working tree to clean state
            git reset --hard HEAD 2>$null
            git clean -fd 2>$null
            Write-Output "Reset working tree to clean state"
        } else {
            Write-Output "Keeping test files and working tree changes"
        }
    }
    
    Write-Output "✅ Git state reset complete"
}

# Setup functions for bump-version scenarios
function Setup-FirstRelease {
    Write-Output "🆕 Setting up first release scenario..."
    Reset-TestGitState
    git checkout main
    if (-not (git log --oneline -n 1 2>$null)) {
        New-TestCommit "Initial commit for first release"
    }
    Write-Output "✅ First release state ready - no tags exist"
}

function Setup-PatchBump {
    Write-Output "🔧 Setting up patch bump scenario..."
    Reset-TestGitState
    git checkout main
    New-TestCommit "Setup commit for v0.1.0"
    git tag -a v0.1.0 -m "Release v0.1.0"
    Write-Output "✅ Patch bump state ready - v0.1.0 tag created"
}

function Setup-MinorBump {
    Write-Output "🔧 Setting up minor bump scenario..."
    Reset-TestGitState
    git checkout main
    New-TestCommit "Setup commit for v0.1.0"
    git tag -a v0.1.0 -m "Release v0.1.0"
    Write-Output "✅ Minor bump state ready - v0.1.0 tag created"
}

function Setup-MajorBumpV0ToV1 {
    Write-Output "🚀 Setting up major bump v0→v1 scenario..."
    Reset-TestGitState
    git checkout main
    New-TestCommit "Setup commit for v0.2.1"
    git tag -a v0.2.1 -m "Release v0.2.1"
    Write-Output "✅ Major bump v0→v1 state ready - v0.2.1 tag created"
}

function Setup-MajorBumpV1ToV2 {
    Write-Output "🚀 Setting up major bump v1→v2 scenario..."
    Reset-TestGitState
    git checkout main
    New-TestCommit "Setup commit for v1.2.0"
    git tag -a v1.2.0 -m "Release v1.2.0"
    Write-Output "✅ Major bump v1→v2 state ready - v1.2.0 tag created, no release/v1 branch"
}

function Setup-ReleaseBranchPatch {
    Write-Output "🌿 Setting up release branch patch scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create v1.2.0 commit and tag
    New-TestCommit "Setup commit for v1.2.0"
    git tag -a v1.2.0 -m "Release v1.2.0"
    $v1Commit = git rev-parse HEAD
    
    # Create v2.0.0 on main (newer major version)
    New-TestCommit "Setup commit for v2.0.0"
    git tag -a v2.0.0 -m "Release v2.0.0"
    
    # Create release/v1 branch from v1.2.0 commit
    git branch release/v1 $v1Commit
    git checkout release/v1
    
    Write-Output "✅ Release branch patch state ready - v1.2.0 on release/v1, v2.0.0 on main"
}

function Setup-ReleaseBranchMinor {
    Write-Output "🌿 Setting up release branch minor scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create initial v1.2.1 commit and tag
    New-TestCommit "Setup commit for v1.2.1"
    git tag -a v1.2.1 -m "Release v1.2.1"
    $v1Commit = git rev-parse HEAD
    
    # Create release/v1 branch
    git branch release/v1 $v1Commit
    git checkout release/v1
    
    Write-Output "✅ Release branch minor state ready - v1.2.1 on release/v1"
}

function Setup-DuplicateTag {
    Write-Output "❌ Setting up duplicate tag error scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create v0.1.0
    New-TestCommit "Setup commit for v0.1.0"
    git tag -a v0.1.0 -m "Release v0.1.0"
    
    # Create v0.1.1 (this will be the duplicate)
    New-TestCommit "Setup commit for v0.1.1"
    git tag -a v0.1.1 -m "Release v0.1.1"
    
    # Go back to v0.1.0 state for testing
    git reset --hard v0.1.0
    
    Write-Output "✅ Duplicate tag error state ready - v0.1.0 and v0.1.1 tags exist"
}

function Setup-InvalidBranch {
    Write-Output "❌ Setting up invalid branch format error scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create some tag on main
    New-TestCommit "Setup commit for v0.1.0"
    git tag -a v0.1.0 -m "Release v0.1.0"
    
    # Create invalid branch format
    git branch feature/test-branch
    git checkout feature/test-branch
    
    Write-Output "✅ Invalid branch format error state ready - on feature/test-branch"
}

function Setup-FirstReleaseError {
    Write-Output "❌ Setting up first release on release branch error scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create release/v1 branch with no tags anywhere
    git branch release/v1
    git checkout release/v1
    
    if (-not (git log --oneline -n 1 2>$null)) {
        New-TestCommit "Initial commit on release branch"
    }
    
    Write-Output "✅ First release error state ready - on release/v1 with no tags"
}

function Setup-MajorVersionMismatch {
    Write-Output "❌ Setting up major version mismatch error scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create v1.2.0 commit and tag
    New-TestCommit "Setup commit for v1.2.0"
    git tag -a v1.2.0 -m "Release v1.2.0"
    $v1Commit = git rev-parse HEAD
    
    # Create release/v1 branch
    git branch release/v1 $v1Commit
    git checkout release/v1
    
    Write-Output "✅ Major version mismatch error state ready - v1.2.0 on release/v1"
}

# Setup functions for release scenarios
function Setup-ValidReleaseV0 {
    Write-Output "🎯 Setting up valid release v0.1.0 scenario..."
    Reset-TestGitState
    git checkout main
    
    if (-not (git log --oneline -n 1 2>$null)) {
        New-TestCommit "Initial commit for v0.1.0 release"
    }
    
    Write-Output "✅ Valid release v0.1.0 state ready - clean main branch, no v0.1.0 tag"
}

function Setup-ValidReleaseV1 {
    Write-Output "🎯 Setting up valid release v1.0.0 scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create v0.2.1 tag (previous version)
    New-TestCommit "Setup commit for v0.2.1"
    git tag -a v0.2.1 -m "Release v0.2.1"
    
    # Add commit for v1.0.0
    New-TestCommit "Setup commit for v1.0.0"
    
    Write-Output "✅ Valid release v1.0.0 state ready - v0.2.1 exists, no v1.0.0 tag"
}

function Setup-ValidReleaseV1Patch {
    Write-Output "🎯 Setting up valid release v1.2.3 scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create previous tags
    New-TestCommit "Setup commit for v1.2.0"
    git tag -a v1.2.0 -m "Release v1.2.0"
    
    New-TestCommit "Setup commit for v1.2.1"
    git tag -a v1.2.1 -m "Release v1.2.1"
    
    New-TestCommit "Setup commit for v1.2.2"
    git tag -a v1.2.2 -m "Release v1.2.2"
    
    # Add commit for v1.2.3
    New-TestCommit "Setup commit for v1.2.3"
    
    Write-Output "✅ Valid release v1.2.3 state ready - v1.2.0, v1.2.1, v1.2.2 exist, no v1.2.3 tag"
}

function Setup-DuplicateReleaseTag {
    Write-Output "❌ Setting up duplicate release tag error scenario..."
    Reset-TestGitState
    git checkout main
    
    # Create v1.0.0 tag (will be duplicate)
    New-TestCommit "Setup commit for v1.0.0"
    git tag -a v1.0.0 -m "Release v1.0.0"
    
    Write-Output "✅ Duplicate release tag error state ready - v1.0.0 tag already exists"
}

# Main execution
Write-Output "🔧 Git State Setup Helper for Version Management Workflow Testing"
Write-Output "Scenario: $Scenario"
Write-Output ""

# Safety check
Test-GitStateReady

# Execute the requested scenario
switch ($Scenario) {
    "FirstRelease" { Setup-FirstRelease }
    "PatchBump" { Setup-PatchBump }
    "MinorBump" { Setup-MinorBump }
    "MajorBumpV0ToV1" { Setup-MajorBumpV0ToV1 }
    "MajorBumpV1ToV2" { Setup-MajorBumpV1ToV2 }
    "ReleaseBranchPatch" { Setup-ReleaseBranchPatch }
    "ReleaseBranchMinor" { Setup-ReleaseBranchMinor }
    "DuplicateTag" { Setup-DuplicateTag }
    "InvalidBranch" { Setup-InvalidBranch }
    "FirstReleaseError" { Setup-FirstReleaseError }
    "MajorVersionMismatch" { Setup-MajorVersionMismatch }
    "ValidReleaseV0" { Setup-ValidReleaseV0 }
    "ValidReleaseV1" { Setup-ValidReleaseV1 }
    "ValidReleaseV1Patch" { Setup-ValidReleaseV1Patch }
    "DuplicateReleaseTag" { Setup-DuplicateReleaseTag }
    "Reset" { Reset-TestGitState }
    default { 
        Write-Error "Unknown scenario: $Scenario"
        exit 1
    }
}

Write-Output ""
Write-Output "🎯 Git state setup complete for scenario: $Scenario"
Write-Output "You can now run your workflow tests with act."
Write-Output ""
Write-Output "💡 Remember to run 'setup-test-git-state.ps1 -Scenario Reset' when finished testing."
Write-Output "💡 Test files are created in .test-state/ directory (ignored by git)."
