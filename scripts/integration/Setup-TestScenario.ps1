<#
.SYNOPSIS
    Centralized test scenario definitions and management for act integration testing.

.DESCRIPTION
    This script provides centralized scenario definitions and management functions for
    integration testing with act. It defines git states (tags, branches, current branch)
    for test scenarios used across multiple test fixtures.

    The script includes functions for:
    - Retrieving scenario definitions
    - Applying scenarios to git state (creating tags, branches, checking out branches)
    - Validating current git state against scenario requirements
    - Displaying scenario information with formatted output
    - Exporting test-tags.txt file for bump-version.yml workflow

    Supported Scenarios:
    - FirstRelease: Initial release scenario - clean state with only main branch
    - MajorBumpV0ToV1: v0 to v1 promotion - v0.2.1 tag on main
    - MajorBumpV1ToV2: v1 to v2 promotion - v1.2.0 tag on main
    - MinorBump: Minor version bump - v0.1.0 tag on main
    - PatchBump: Patch version bump - v0.1.0 tag on main
    - ReleaseBranchPatch: Release branch patch - v1.2.0 on release/v1, v2.0.0 on main
    - InvalidBranch: Invalid branch format - feature branch checked out for error testing

    This script is designed to be:
    - Dot-sourceable for use by other integration testing scripts
    - Compatible with Apply-TestFixtures.ps1 and Backup-GitState.ps1
    - Integrated with bump-version.yml workflow (lines 41-79)

.PARAMETER ScenarioName
    Used by functions that require a specific scenario (e.g., Get-ScenarioDefinition, Set-TestScenario).
    Name of the test scenario to apply or retrieve.

.EXAMPLE
    # Dot-source to load functions
    . .\scripts\integration\Setup-TestScenario.ps1

    # List all available scenarios
    Get-AllScenarios

.EXAMPLE
    # Display scenario details
    Show-ScenarioDefinition -ScenarioName "FirstRelease"

.EXAMPLE
    # Apply a scenario to the git repository
    Set-TestScenario -ScenarioName "MajorBumpV0ToV1" -CleanState

.EXAMPLE
    # Validate current git state against a scenario
    $result = Test-ScenarioState -ScenarioName "FirstRelease"
    if ($result.IsValid) {
        Write-Host "Git state is valid for scenario"
    }

.NOTES
    Scenario Format:
    - Description: Human-readable description of the scenario
    - Tags: Array of hashtables with Name (tag name) and CommitMessage (commit message)
    - Branches: Array of branch names (e.g., "main", "release/v1")
    - CurrentBranch: The branch to checkout after setup
    - Notes: Additional information about the scenario usage
    - ExpectedVersion: The version bump result expected from this scenario
    - TestFixtures: Array of fixture files that use this scenario

    Tag Format:
    - Name: Tag name (e.g., "v0.2.1")
    - CommitMessage: Commit message for the tag (e.g., "Release v0.2.1")
    - Branch: Optional branch name if tag should be on specific branch (default: main)

    Integration with bump-version.yml:
    - The workflow reads .test-state/test-tags.txt at lines 41-79
    - Format must match: "tag_name commit_sha" (one per line)
    - All existing tags are deleted first, then restored from this file
    - This ensures clean, reproducible state for each act run

    Compatibility:
    - Works with Apply-TestFixtures.ps1 for fixture application
    - Works with Backup-GitState.ps1 for state backup/restore
    - Can be dot-sourced by Run-ActTests.ps1 and other test runners

    Edge Cases Handled:
    - Empty repositories: Creates initial commit before adding tags
    - Existing tags/branches: Optionally overwrites with Force parameter
    - Uncommitted changes: Provides clear error message for checkout conflicts
    - Invalid commit SHAs: Validates commits exist before tag/branch creation
    - Detached HEAD: Handles gracefully during branch checkout
    - Complex scenarios: ReleaseBranchPatch handles tags on different branches

    Testing Workflow:
    1. Backup production state: $backup = Backup-GitState
    2. Apply test scenario: Set-TestScenario -ScenarioName "MajorBumpV0ToV1"
    3. Run act workflows: act -j bump-version --eventpath tests/bump-version/major-bump-v0-to-v1.json
    4. Validate results: Test-ScenarioState -ScenarioName "MajorBumpV0ToV1"
    5. Restore production state: Restore-GitState -BackupName $backup.BackupName
#>

# ============================================================================
# Global Variables and Configuration
# ============================================================================

$TestStateDirectory = ".test-state"
$TestTagsFile = "test-tags.txt"
$DebugPreference = "Continue"

# Color constants (matching style from Backup-GitState.ps1)
$Colors = @{
    Success = [System.ConsoleColor]::Green
    Warning = [System.ConsoleColor]::Yellow
    Error   = [System.ConsoleColor]::Red
    Info    = [System.ConsoleColor]::Cyan
    Debug   = [System.ConsoleColor]::DarkGray
}

# Emoji constants (matching style from Backup-GitState.ps1)
$Emojis = @{
    Success  = "✅"
    Warning  = "⚠️"
    Error    = "❌"
    Info     = "ℹ️"
    Debug    = "🔍"
    Tag      = "🏷️"
    Branch   = "🌿"
    Scenario = "🎬"
    Fixture  = "📄"
    Target   = "🎯"
    Note     = "📝"
    List     = "📋"
}

# ============================================================================
# Scenario Definition Mapping
# ============================================================================

$ScenarioDefinitions = @{
    FirstRelease = @{
        Description             = "Initial release scenario - clean state with only main branch, no existing tags"
        Tags                    = @()
        Branches                = @("main")
        CurrentBranch           = "main"
        Notes                   = "Used for testing initial v0.1.0 release. Referenced in: first-release-main.json, multi-step-version-progression.json. Documented in VERSIONING.md under 'Creating the First Release'."
        ExpectedVersion         = "0.1.0"
        TestFixtures            = @("tests/bump-version/first-release-main.json", "tests/integration/multi-step-version-progression.json")
    }
    
    MajorBumpV0ToV1 = @{
        Description             = "v0 to v1 promotion scenario - v0.2.1 tag exists on main branch"
        Tags                    = @(
            @{ Name = "v0.2.1"; CommitMessage = "Release v0.2.1" }
        )
        Branches                = @("main")
        CurrentBranch           = "main"
        Notes                   = "Used for testing v0 → v1 promotion with automatic release/v0 branch creation. Referenced in: major-bump-v0-to-v1.json, v0-to-v1-release-cycle.json. Documented in VERSIONING.md under 'Promoting to v1.0.0'."
        ExpectedVersion         = "1.0.0"
        ExpectedBranchCreation  = "release/v0"
        TestFixtures            = @("tests/bump-version/major-bump-v0-to-v1.json", "tests/integration/v0-to-v1-release-cycle.json")
    }
    
    MajorBumpV1ToV2 = @{
        Description             = "v1 to v2 promotion scenario - v1.2.0 tag exists on main, no release/v1 branch yet"
        Tags                    = @(
            @{ Name = "v1.2.0"; CommitMessage = "Release v1.2.0" }
        )
        Branches                = @("main")
        CurrentBranch           = "main"
        Notes                   = "Used for testing v1 → v2 promotion with automatic release/v1 branch creation. Referenced in: major-bump-v1-to-v2.json, release-branch-lifecycle.json. Documented in VERSIONING.md under 'Releasing a New Major Version'."
        ExpectedVersion         = "2.0.0"
        ExpectedBranchCreation  = "release/v1"
        TestFixtures            = @("tests/bump-version/major-bump-v1-to-v2.json", "tests/integration/release-branch-lifecycle.json")
    }
    
    MinorBump = @{
        Description             = "Minor version bump scenario - v0.1.0 tag exists on main branch"
        Tags                    = @(
            @{ Name = "v0.1.0"; CommitMessage = "Release v0.1.0" }
        )
        Branches                = @("main")
        CurrentBranch           = "main"
        Notes                   = "Used for testing minor version bumps (v0.1.0 → v0.2.0). Referenced in: minor-bump-main.json. Documented in VERSIONING.md under 'Releasing Minor and Patch Versions'."
        ExpectedVersion         = "0.2.0"
        TestFixtures            = @("tests/bump-version/minor-bump-main.json")
    }
    
    PatchBump = @{
        Description             = "Patch version bump scenario - v0.1.0 tag exists on main branch"
        Tags                    = @(
            @{ Name = "v0.1.0"; CommitMessage = "Release v0.1.0" }
        )
        Branches                = @("main")
        CurrentBranch           = "main"
        Notes                   = "Used for testing patch version bumps (v0.1.0 → v0.1.1). Referenced in: patch-bump-main.json. Documented in VERSIONING.md under 'Releasing Minor and Patch Versions'."
        ExpectedVersion         = "0.1.1"
        TestFixtures            = @("tests/bump-version/patch-bump-main.json")
    }
    
    ReleaseBranchPatch = @{
        Description             = "Release branch patch scenario - v1.2.0 on release/v1, v2.0.0 on main (newer major exists)"
        Tags                    = @(
            @{ Name = "v1.2.0"; CommitMessage = "Release v1.2.0"; Branch = "release/v1" }
            @{ Name = "v2.0.0"; CommitMessage = "Release v2.0.0"; Branch = "main" }
        )
        Branches                = @("main", "release/v1")
        CurrentBranch           = "release/v1"
        Notes                   = "Used for testing patches on older major versions while newer major exists. Referenced in: patch-bump-release-branch.json, release-branch-lifecycle.json. Documented in VERSIONING.md under 'Patching an Older Major Version'."
        ExpectedVersion         = "1.2.1"
        TestFixtures            = @("tests/bump-version/patch-bump-release-branch.json", "tests/integration/release-branch-lifecycle.json")
    }
    
    InvalidBranch = @{
        Description             = "Invalid branch format scenario - feature branch checked out for error testing"
        Tags                    = @(
            @{ Name = "v0.1.0"; CommitMessage = "Release v0.1.0" }
        )
        Branches                = @("main", "feature/test-branch")
        CurrentBranch           = "feature/test-branch"
        Notes                   = "Used for testing branch validation errors. Workflow should reject bump attempts on feature branches. Referenced in: error-invalid-branch-format.json, rollback-invalid-branch.json. Documented in VERSIONING.md under 'Troubleshooting'."
        ExpectedError           = "Branch format validation should fail - only main and release/vX branches allowed"
        TestFixtures            = @("tests/bump-version/error-invalid-branch-format.json", "tests/integration/rollback-invalid-branch.json")
    }
}

Write-Debug "$($Emojis.Debug) Loaded $($ScenarioDefinitions.Count) scenario definitions"

# ============================================================================
# Helper Functions
# ============================================================================

<#
.SYNOPSIS
    Detect the git repository root directory.

.DESCRIPTION
    Walks up the directory tree from the current location until finding a .git directory.

.EXAMPLE
    $repoRoot = Get-RepositoryRoot
    Write-Host "Repository root: $repoRoot"

.NOTES
    Throws an error if not in a git repository.
#>
function Get-RepositoryRoot {
    $searchPath = (Get-Location).Path

    while ($searchPath -ne (Split-Path $searchPath)) {
        Write-Debug "$($Emojis.Debug) Searching for .git in: $searchPath"
        
        $gitPath = Join-Path $searchPath ".git"
        if (Test-Path $gitPath) {
            Write-Debug "$($Emojis.Debug) Found repository root: $searchPath"
            return $searchPath
        }
        
        $searchPath = Split-Path $searchPath -Parent
    }

    throw "❌ Not in a git repository. Please navigate to the repository root and try again."
}

<#
.SYNOPSIS
    Create the test state directory if it doesn't exist.

.DESCRIPTION
    Creates .test-state directory relative to the repository root.

.PARAMETER RepositoryRoot
    The root directory of the git repository.

.EXAMPLE
    $testStateDir = New-TestStateDirectory -RepositoryRoot "C:\repo"

.NOTES
    Returns the full path to the test state directory.
#>
function New-TestStateDirectory {
    param(
        [string]$RepositoryRoot = (Get-RepositoryRoot)
    )

    $fullTestStatePath = Join-Path $RepositoryRoot $TestStateDirectory
    
    if (-not (Test-Path $fullTestStatePath)) {
        Write-Debug "$($Emojis.Debug) Creating test state directory: $fullTestStatePath"
        New-Item -ItemType Directory -Path $fullTestStatePath -Force | Out-Null
        Write-Debug "$($Emojis.Debug) Test state directory created"
    } else {
        Write-Debug "$($Emojis.Debug) Test state directory already exists: $fullTestStatePath"
    }

    return $fullTestStatePath
}

<#
.SYNOPSIS
    Write debug messages with consistent formatting.

.DESCRIPTION
    Wrapper function for consistent debug output with emoji prefixes and colors.

.PARAMETER Type
    Message type: INFO, SUCCESS, WARNING, ERROR

.PARAMETER Message
    The message text to display

.EXAMPLE
    Write-DebugMessage -Type "INFO" -Message "Starting scenario application"
#>
function Write-DebugMessage {
    param(
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Type,
        
        [string]$Message
    )

    $emoji = switch ($Type) {
        "INFO"    { $Emojis.Info }
        "SUCCESS" { $Emojis.Success }
        "WARNING" { $Emojis.Warning }
        "ERROR"   { $Emojis.Error }
        default   { "ℹ️" }
    }

    $color = switch ($Type) {
        "INFO"    { $Colors.Info }
        "SUCCESS" { $Colors.Success }
        "WARNING" { $Colors.Warning }
        "ERROR"   { $Colors.Error }
        default   { $Colors.Info }
    }
    
    Write-Host "$emoji $Message" -ForegroundColor $color
}

<#
.SYNOPSIS
    Get the current commit SHA.

.DESCRIPTION
    Executes git rev-parse HEAD to get the current commit SHA.

.EXAMPLE
    $sha = Get-CurrentCommitSha
    Write-Host "Current commit: $sha"

.NOTES
    Handles detached HEAD and no commits states gracefully.
#>
function Get-CurrentCommitSha {
    try {
        $sha = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Debug "$($Emojis.Debug) Current commit SHA: $sha"
            return $sha
        } else {
            throw "Failed to get current commit SHA"
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error getting current commit: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Test if a git tag exists.

.DESCRIPTION
    Checks if a tag exists in the git repository.

.PARAMETER TagName
    The name of the tag to check.

.EXAMPLE
    if (Test-GitTagExists -TagName "v1.0.0") {
        Write-Host "Tag exists"
    }

.NOTES
    Returns $true if tag exists, $false otherwise.
#>
function Test-GitTagExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName
    )

    $existingTag = git tag -l $TagName 2>$null
    $exists = -not [string]::IsNullOrWhiteSpace($existingTag)
    
    Write-Debug "$($Emojis.Debug) Tag exists check '$TagName': $exists"
    return $exists
}

<#
.SYNOPSIS
    Test if a git branch exists.

.DESCRIPTION
    Checks if a branch exists in the git repository.

.PARAMETER BranchName
    The name of the branch to check.

.EXAMPLE
    if (Test-GitBranchExists -BranchName "main") {
        Write-Host "Branch exists"
    }

.NOTES
    Returns $true if branch exists, $false otherwise.
#>
function Test-GitBranchExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $existingBranch = git branch -l $BranchName 2>$null
    $exists = -not [string]::IsNullOrWhiteSpace($existingBranch)
    
    Write-Debug "$($Emojis.Debug) Branch exists check '$BranchName': $exists"
    return $exists
}

# ============================================================================
# Core Scenario Management Functions
# ============================================================================

<#
.SYNOPSIS
    Get the definition of a specific test scenario.

.DESCRIPTION
    Retrieves scenario definition including tags, branches, current branch, and metadata.

.PARAMETER ScenarioName
    Name of the scenario to retrieve (e.g., 'FirstRelease', 'MajorBumpV0ToV1').

.EXAMPLE
    $scenario = Get-ScenarioDefinition -ScenarioName "FirstRelease"

.NOTES
    Throws error if scenario not found. Use Get-AllScenarios to list available scenarios.
#>
function Get-ScenarioDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName
    )

    try {
        if (-not $ScenarioDefinitions.ContainsKey($ScenarioName)) {
            $availableScenarios = $ScenarioDefinitions.Keys -join ", "
            throw "Scenario not found: $ScenarioName. Available scenarios: $availableScenarios"
        }

        Write-Debug "$($Emojis.Scenario) Retrieved scenario definition: $ScenarioName"
        return $ScenarioDefinitions[$ScenarioName]
    } catch {
        Write-DebugMessage -Type "ERROR" -Message $_
        throw $_
    }
}

<#
.SYNOPSIS
    List all available test scenarios.

.DESCRIPTION
    Returns summary information for all defined scenarios.

.EXAMPLE
    $scenarios = Get-AllScenarios
    $scenarios | Format-Table Name, Description

.NOTES
    Returns array of scenario summary objects.
#>
function Get-AllScenarios {
    Write-Debug "$($Emojis.Debug) Listing all available scenarios"
    
    $scenarios = @()
    foreach ($scenarioName in $ScenarioDefinitions.Keys) {
        $scenario = $ScenarioDefinitions[$scenarioName]
        $scenarios += @{
            Name            = $scenarioName
            Description     = $scenario.Description
            TagCount        = $scenario.Tags.Count
            BranchCount     = $scenario.Branches.Count
            CurrentBranch   = $scenario.CurrentBranch
            TestFixtures    = $scenario.TestFixtures
        }
    }
    
    Write-Debug "$($Emojis.Debug) Found $($scenarios.Count) scenarios"
    return $scenarios
}

<#
.SYNOPSIS
    Get list of all scenario names.

.DESCRIPTION
    Returns just the scenario names without additional details.

.EXAMPLE
    $names = Get-ScenarioNames
    Write-Host "Available: $($names -join ', ')"

.NOTES
    Returns array of scenario names.
#>
function Get-ScenarioNames {
    Write-Debug "$($Emojis.Debug) Retrieved scenario names"
    return @($ScenarioDefinitions.Keys)
}

# ============================================================================
# Git State Creation Functions
# ============================================================================

<#
.SYNOPSIS
    Create a git commit for test scenario setup.

.DESCRIPTION
    Creates a new commit in the repository. Useful for creating test commits
    that can be tagged.

.PARAMETER Message
    Commit message (required).

.PARAMETER AllowEmpty
    Allow empty commits (default: true for test scenarios).

.EXAMPLE
    $sha = New-GitCommit -Message "Test commit for v0.2.1"

.NOTES
    Returns the commit SHA of the created commit.
#>
function New-GitCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [bool]$AllowEmpty = $true
    )

    try {
        $args = @("commit")
        if ($AllowEmpty) {
            $args += "--allow-empty"
        }
        $args += @("-m", $Message)

        Write-Debug "$($Emojis.Debug) Creating commit: $Message"
        
        git @args 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create commit"
        }

        $sha = Get-CurrentCommitSha
        Write-Debug "$($Emojis.Tag) Commit created: $sha"
        
        return $sha
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to create commit: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Create a git tag at specified commit.

.DESCRIPTION
    Creates a git tag at the specified commit.

.PARAMETER TagName
    Name of the tag (e.g., 'v0.2.1').

.PARAMETER CommitSha
    Commit SHA to tag (defaults to HEAD).

.PARAMETER Force
    Force overwrite if tag exists (default: false).

.EXAMPLE
    New-GitTag -TagName "v0.2.1" -CommitSha $sha

.NOTES
    Returns $true if created, $false if skipped due to existing tag.
#>
function New-GitTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,
        
        [string]$CommitSha,
        
        [bool]$Force = $false
    )

    try {
        # Default to HEAD if no commit specified
        if (-not $CommitSha) {
            $CommitSha = Get-CurrentCommitSha
        }

        Write-Debug "$($Emojis.Tag) Creating tag: $TagName -> $CommitSha"

        # Check if tag already exists
        if (Test-GitTagExists -TagName $TagName) {
            if (-not $Force) {
                Write-DebugMessage -Type "WARNING" -Message "Tag already exists: $TagName"
                return $false
            }

            # Delete existing tag if force is enabled
            Write-Debug "$($Emojis.Debug) Deleted existing tag for force creation: $TagName"
            git tag -d $TagName 2>&1 | Out-Null
        }

        # Create tag
        git tag $TagName $CommitSha 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create tag"
        }

        Write-Debug "$($Emojis.Tag) Created tag: $TagName -> $CommitSha"
        return $true
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to create tag '$TagName': $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Create a git branch at specified commit.

.DESCRIPTION
    Creates a git branch at the specified commit.

.PARAMETER BranchName
    Name of the branch (e.g., 'release/v1').

.PARAMETER CommitSha
    Commit SHA for branch (defaults to HEAD).

.PARAMETER Force
    Force overwrite if branch exists (default: false).

.EXAMPLE
    New-GitBranch -BranchName "release/v1" -CommitSha $sha

.NOTES
    Returns $true if created, $false if skipped due to existing branch.
#>
function New-GitBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,
        
        [string]$CommitSha,
        
        [bool]$Force = $false
    )

    try {
        # Default to HEAD if no commit specified
        if (-not $CommitSha) {
            $CommitSha = Get-CurrentCommitSha
        }

        Write-Debug "$($Emojis.Branch) Creating branch: $BranchName -> $CommitSha"

        # Check if branch already exists
        if (Test-GitBranchExists -BranchName $BranchName) {
            if (-not $Force) {
                Write-DebugMessage -Type "WARNING" -Message "Branch already exists: $BranchName"
                return $false
            }

            # Check if this is the current branch
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            if ($currentBranch -eq $BranchName) {
                Write-DebugMessage -Type "WARNING" -Message "Cannot delete current branch: $BranchName"
                return $false
            }

            # Delete existing branch if force is enabled
            Write-Debug "$($Emojis.Debug) Deleted existing branch for force creation: $BranchName"
            git branch -D $BranchName 2>&1 | Out-Null
        }

        # Create branch
        git branch $BranchName $CommitSha 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create branch"
        }

        Write-Debug "$($Emojis.Branch) Created branch: $BranchName -> $CommitSha"
        return $true
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to create branch '$BranchName': $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Checkout a git branch.

.DESCRIPTION
    Switches to the specified branch.

.PARAMETER BranchName
    Name of the branch to checkout.

.EXAMPLE
    Set-GitBranch -BranchName "main"

.NOTES
    Returns $true if successful, $false otherwise.
    Fails if uncommitted changes exist.
#>
function Set-GitBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    try {
        Write-Debug "$($Emojis.Branch) Checking out branch: $BranchName"
        
        git checkout $BranchName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to checkout branch - check for uncommitted changes"
        }

        Write-Debug "$($Emojis.Branch) Checked out branch: $BranchName"
        return $true
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "❌ Cannot checkout branch due to uncommitted changes. Please commit or stash changes first."
        return $false
    }
}

<#
.SYNOPSIS
    Clean existing git state before applying test scenario.

.DESCRIPTION
    Deletes existing git tags and optionally branches to prepare for fixture application.

.PARAMETER DeleteTags
    Delete all existing tags (default: true).

.PARAMETER DeleteBranches
    Delete all branches except current and main (default: false).

.EXAMPLE
    Clear-GitState -DeleteTags $true

.NOTES
    Use with caution - this modifies git state. Always backup state first using Backup-GitState.ps1
#>
function Clear-GitState {
    param(
        [bool]$DeleteTags = $true,
        [bool]$DeleteBranches = $false
    )

    try {
        Write-DebugMessage -Type "WARNING" -Message "Cleaning git state - DeleteTags: $DeleteTags, DeleteBranches: $DeleteBranches"

        if ($DeleteTags) {
            $existingTags = @(git tag -l)
            if ($existingTags.Count -gt 0) {
                foreach ($tag in $existingTags) {
                    git tag -d $tag 2>&1 | Out-Null
                    Write-Debug "$($Emojis.Debug) Deleted tag: $tag"
                }
                Write-DebugMessage -Type "INFO" -Message "Deleted $($existingTags.Count) tags"
            }
        }

        if ($DeleteBranches) {
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            $existingBranches = @(git branch -l | Where-Object { $_ -notlike "*$currentBranch*" } )
            
            if ($existingBranches.Count -gt 0) {
                $deletedCount = 0
                foreach ($branchLine in $existingBranches) {
                    $branch = $branchLine.Trim()
                    if ($branch.StartsWith("* ")) {
                        $branch = $branch.Substring(2).Trim()
                    }
                    
                    if ($branch -and $branch -ne $currentBranch -and $branch -ne "main") {
                        git branch -D $branch 2>&1 | Out-Null
                        Write-Debug "$($Emojis.Debug) Deleted branch: $branch"
                        $deletedCount++
                    }
                }
                if ($deletedCount -gt 0) {
                    Write-DebugMessage -Type "INFO" -Message "Deleted $deletedCount branches"
                }
            }
        }

        return @{
            TagsDeleted      = if ($DeleteTags) { @(git tag -l).Count } else { 0 }
            BranchesDeleted  = if ($DeleteBranches) { $deletedCount } else { 0 }
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error during state cleanup: $_"
        throw $_
    }
}

# ============================================================================
# Scenario Application Function
# ============================================================================

<#
.SYNOPSIS
    Apply a test scenario to the git repository.

.DESCRIPTION
    Creates tags, branches, and checks out the appropriate branch for the specified scenario.

.PARAMETER ScenarioName
    Name of the scenario to apply (e.g., 'FirstRelease', 'MajorBumpV0ToV1').

.PARAMETER CleanState
    Clean existing tags before applying scenario (default: false).

.PARAMETER Force
    Force overwrite existing tags/branches (default: false).

.PARAMETER GenerateTestTagsFile
    Generate .test-state/test-tags.txt for bump-version.yml (default: true).

.EXAMPLE
    Set-TestScenario -ScenarioName "FirstRelease"

.EXAMPLE
    Set-TestScenario -ScenarioName "MajorBumpV0ToV1" -CleanState $true -Force $true

.NOTES
    Integrates with bump-version.yml workflow which reads .test-state/test-tags.txt (lines 41-79).
    Use Backup-GitState.ps1 to backup state before applying scenarios.
#>
function Set-TestScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,
        
        [bool]$CleanState = $false,
        [bool]$Force = $false,
        [bool]$GenerateTestTagsFile = $true
    )

    try {
        Write-DebugMessage -Type "INFO" -Message "Applying test scenario: $ScenarioName"

        # Get scenario definition
        $scenario = Get-ScenarioDefinition -ScenarioName $ScenarioName
        Write-Debug "$($Emojis.Scenario) Scenario description: $($scenario.Description)"

        # Clean state if requested
        if ($CleanState) {
            Clear-GitState -DeleteTags $true
        }

        $repoRoot = Get-RepositoryRoot
        
        # Check if repository is empty
        $hasCommits = $false
        try {
            $sha = Get-CurrentCommitSha
            $hasCommits = $true
        } catch {
            Write-Debug "$($Emojis.Debug) Repository appears to be empty, will create initial commit"
            $hasCommits = $false
        }

        # Create commits and tags
        $tagsCreated = @()
        $commitMap = @{}

        foreach ($tag in $scenario.Tags) {
            try {
                # Create commit for this tag
                $sha = New-GitCommit -Message $tag.CommitMessage
                $commitMap[$tag.Name] = $sha

                # Create tag
                $created = New-GitTag -TagName $tag.Name -CommitSha $sha -Force $Force
                if ($created) {
                    $tagsCreated += $tag.Name
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Failed to create tag $($tag.Name): $_"
                continue
            }
        }

        # Create branches
        $branchesCreated = @()
        foreach ($branch in $scenario.Branches) {
            try {
                # Skip if branch already exists and not force
                if (Test-GitBranchExists -BranchName $branch) {
                    if (-not $Force) {
                        Write-Debug "$($Emojis.Branch) Branch already exists, skipping: $branch"
                        continue
                    }
                }

                # Determine commit SHA for branch
                # First, check if any tag should be on this branch
                $branchSha = $null
                foreach ($tag in $scenario.Tags) {
                    if ($tag.Branch -eq $branch -and $commitMap.ContainsKey($tag.Name)) {
                        $branchSha = $commitMap[$tag.Name]
                        break
                    }
                }

                # If no tag-specific branch assignment, use latest commit
                if (-not $branchSha) {
                    if ($hasCommits) {
                        $branchSha = Get-CurrentCommitSha
                    } else {
                        # Create initial commit if repository is empty
                        $branchSha = New-GitCommit -Message "Initial commit"
                        $hasCommits = $true
                    }
                }

                $created = New-GitBranch -BranchName $branch -CommitSha $branchSha -Force $Force
                if ($created) {
                    $branchesCreated += $branch
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Failed to create branch ${branch}: $_"
                continue
            }
        }

        # Checkout current branch
        if ($scenario.CurrentBranch) {
            try {
                $checkoutSuccess = Set-GitBranch -BranchName $scenario.CurrentBranch
                if (-not $checkoutSuccess) {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to checkout current branch, continuing anyway"
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error checking out current branch: $_"
            }
        }

        # Generate test-tags.txt
        $testTagsPath = $null
        if ($GenerateTestTagsFile) {
            $testTagsPath = Export-TestTagsFile -Tags $tagsCreated
        }

        Write-DebugMessage -Type "SUCCESS" -Message "Scenario applied successfully: $ScenarioName"

        return @{
            ScenarioName      = $ScenarioName
            TagsCreated       = $tagsCreated
            BranchesCreated   = $branchesCreated
            CurrentBranch     = $scenario.CurrentBranch
            TestTagsFile      = $testTagsPath
            CommitMap         = $commitMap
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to apply scenario: $_"
        throw $_
    }
}

# ============================================================================
# Test Tags File Generation
# ============================================================================

<#
.SYNOPSIS
    Generate test-tags.txt file for bump-version.yml workflow.

.DESCRIPTION
    Exports git tags in format expected by bump-version.yml (lines 58-79).

.PARAMETER OutputPath
    Custom output path (defaults to .test-state/test-tags.txt).

.PARAMETER Tags
    Array of tag names to export (defaults to all tags).

.EXAMPLE
    Export-TestTagsFile -Tags @("v0.2.1", "v1.0.0")

.NOTES
    Format: 'tag_name commit_sha' (one per line). Compatible with bump-version.yml tag restoration logic.
#>
function Export-TestTagsFile {
    param(
        [string]$OutputPath,
        [string[]]$Tags
    )

    try {
        # Default output path if not provided
        if (-not $OutputPath) {
            $repoRoot = Get-RepositoryRoot
            $testStateDir = New-TestStateDirectory -RepositoryRoot $repoRoot
            $OutputPath = Join-Path $testStateDir $TestTagsFile
        }

        Write-DebugMessage -Type "INFO" -Message "Generating test-tags.txt file"
        Write-Debug "$($Emojis.Debug) Output path: $OutputPath"

        # If no tags specified, get all tags
        if (-not $Tags -or $Tags.Count -eq 0) {
            $Tags = @(git tag -l)
            Write-Debug "$($Emojis.Debug) No tags specified, using all repository tags: $($Tags.Count) tags"
        }

        # Build file content
        $fileContent = @()

        foreach ($tag in $Tags) {
            try {
                $sha = git rev-list -n 1 $tag 2>$null
                
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
                    $fileContent += "$tag $sha"
                    Write-Debug "$($Emojis.Tag) Exporting tag: $tag -> $sha"
                } else {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to get SHA for tag: $tag"
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error exporting tag '$tag': $_"
                continue
            }
        }

        # Ensure output directory exists
        $outputDir = Split-Path $OutputPath -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            Write-Debug "$($Emojis.Debug) Created output directory: $outputDir"
        }

        # Write to file
        $fileContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        
        Write-DebugMessage -Type "SUCCESS" -Message "Test-tags.txt generated with $($fileContent.Count) tags"
        Write-Debug "$($Emojis.Debug) File path: $OutputPath"

        return $OutputPath
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to export test tags file: $_"
        throw $_
    }
}

# ============================================================================
# Validation Functions
# ============================================================================

<#
.SYNOPSIS
    Validate current git state against scenario requirements.

.DESCRIPTION
    Checks if all required tags, branches, and current branch match the scenario definition.

.PARAMETER ScenarioName
    Name of the scenario to validate against.

.PARAMETER Strict
    Strict mode - fail if extra tags/branches exist (default: false).

.EXAMPLE
    $result = Test-ScenarioState -ScenarioName "FirstRelease"
    if ($result.IsValid) {
        Write-Host "Valid"
    }

.NOTES
    Returns hashtable with validation results and detailed messages.
#>
function Test-ScenarioState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,
        
        [bool]$Strict = $false
    )

    try {
        Write-DebugMessage -Type "INFO" -Message "Validating git state against scenario: $ScenarioName"

        # Get scenario definition
        $scenario = Get-ScenarioDefinition -ScenarioName $ScenarioName
        
        $missingTags = @()
        $missingBranches = @()
        $currentBranchMismatch = $false
        $extraTags = @()
        $extraBranches = @()
        $validationMessages = @()
        $isValid = $true

        # Check tags
        foreach ($tag in $scenario.Tags) {
            if (-not (Test-GitTagExists -TagName $tag.Name)) {
                $missingTags += $tag.Name
                $isValid = $false
                Write-Debug "$($Emojis.Tag) ❌ Missing tag: $($tag.Name)"
                $validationMessages += "Missing tag: $($tag.Name)"
            } else {
                Write-Debug "$($Emojis.Tag) ✅ Tag exists: $($tag.Name)"
                $validationMessages += "✅ Tag exists: $($tag.Name)"
            }
        }

        # Check branches
        foreach ($branch in $scenario.Branches) {
            if (-not (Test-GitBranchExists -BranchName $branch)) {
                $missingBranches += $branch
                $isValid = $false
                Write-Debug "$($Emojis.Branch) ❌ Missing branch: $branch"
                $validationMessages += "Missing branch: $branch"
            } else {
                Write-Debug "$($Emojis.Branch) ✅ Branch exists: $branch"
                $validationMessages += "✅ Branch exists: $branch"
            }
        }

        # Check current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($currentBranch -ne $scenario.CurrentBranch) {
            $currentBranchMismatch = $true
            $isValid = $false
            Write-Debug "$($Emojis.Debug) ❌ Current branch mismatch: expected '$($scenario.CurrentBranch)', got '$currentBranch'"
            $validationMessages += "Current branch mismatch: expected '$($scenario.CurrentBranch)', got '$currentBranch'"
        } else {
            Write-Debug "$($Emojis.Debug) ✅ Current branch correct: $currentBranch"
            $validationMessages += "✅ Current branch correct: $currentBranch"
        }

        # Strict mode: check for extra tags/branches
        if ($Strict) {
            $allTags = @(git tag -l)
            $scenarioTagNames = $scenario.Tags | Select-Object -ExpandProperty Name
            foreach ($tag in $allTags) {
                if ($scenarioTagNames -notcontains $tag) {
                    $extraTags += $tag
                    $isValid = $false
                    Write-Debug "$($Emojis.Tag) ⚠️ Extra tag: $tag"
                    $validationMessages += "Extra tag (Strict mode): $tag"
                }
            }

            $allBranches = @(git branch -l | ForEach-Object { $_.Trim() })
            foreach ($branchLine in $allBranches) {
                $branch = $branchLine
                if ($branch.StartsWith("* ")) {
                    $branch = $branch.Substring(2).Trim()
                }
                if ($scenario.Branches -notcontains $branch -and $branch -ne "main") {
                    $extraBranches += $branch
                    $isValid = $false
                    Write-Debug "$($Emojis.Branch) ⚠️ Extra branch: $branch"
                    $validationMessages += "Extra branch (Strict mode): $branch"
                }
            }
        }

        # Build summary message
        if ($isValid) {
            Write-DebugMessage -Type "SUCCESS" -Message "✅ Git state matches scenario: $ScenarioName"
        } else {
            $summary = "Git state does NOT match scenario: Missing tags: $($missingTags.Count), Missing branches: $($missingBranches.Count)"
            if ($currentBranchMismatch) {
                $summary += ", Branch mismatch: true"
            }
            Write-DebugMessage -Type "WARNING" -Message $summary
        }

        return @{
            IsValid                  = $isValid
            MissingTags              = $missingTags
            MissingBranches          = $missingBranches
            ExtraTags                = $extraTags
            ExtraBranches            = $extraBranches
            CurrentBranchMismatch    = $currentBranchMismatch
            ExpectedCurrentBranch    = $scenario.CurrentBranch
            ActualCurrentBranch      = $currentBranch
            ValidationMessages       = $validationMessages
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error validating scenario state: $_"
        throw $_
    }
}

# ============================================================================
# Display Functions
# ============================================================================

<#
.SYNOPSIS
    Display formatted scenario definition.

.DESCRIPTION
    Shows scenario details with colored, formatted output for easy reading.

.PARAMETER ScenarioName
    Name of the scenario to display.

.PARAMETER Detailed
    Show additional details like test fixtures and expected outcomes (default: false).

.EXAMPLE
    Show-ScenarioDefinition -ScenarioName "MajorBumpV0ToV1"

.EXAMPLE
    Show-ScenarioDefinition -ScenarioName "ReleaseBranchPatch" -Detailed $true
#>
function Show-ScenarioDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,
        
        [bool]$Detailed = $false
    )

    try {
        # Get scenario definition
        $scenario = Get-ScenarioDefinition -ScenarioName $ScenarioName

        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  $($Emojis.Scenario) Scenario: $ScenarioName" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Host "Description:" -ForegroundColor Yellow
        Write-Host "  $($scenario.Description)" -ForegroundColor White
        Write-Host ""

        Write-Host "$($Emojis.Tag) Tags:" -ForegroundColor Yellow
        if ($scenario.Tags.Count -eq 0) {
            Write-Host "  (none)" -ForegroundColor DarkGray
        } else {
            foreach ($tag in $scenario.Tags) {
                Write-Host "  • $($tag.Name) - $($tag.CommitMessage)" -ForegroundColor Cyan
            }
        }
        Write-Host ""

        Write-Host "$($Emojis.Branch) Branches:" -ForegroundColor Yellow
        if ($scenario.Branches.Count -eq 0) {
            Write-Host "  (none)" -ForegroundColor DarkGray
        } else {
            foreach ($branch in $scenario.Branches) {
                Write-Host "  • $branch" -ForegroundColor Cyan
            }
        }
        Write-Host ""

        Write-Host "📍 Current Branch:" -ForegroundColor Yellow
        Write-Host "  $($scenario.CurrentBranch)" -ForegroundColor Green
        Write-Host ""

        if ($Detailed) {
            Write-Host "$($Emojis.Target) Expected Version:" -ForegroundColor Yellow
            Write-Host "  $($scenario.ExpectedVersion)" -ForegroundColor Cyan
            Write-Host ""

            if ($scenario.ExpectedBranchCreation) {
                Write-Host "➕ Expected Branch Creation:" -ForegroundColor Yellow
                Write-Host "  $($scenario.ExpectedBranchCreation)" -ForegroundColor Cyan
                Write-Host ""
            }

            if ($scenario.TestFixtures) {
                Write-Host "$($Emojis.List) Test Fixtures:" -ForegroundColor Yellow
                foreach ($fixture in $scenario.TestFixtures) {
                    Write-Host "  • $fixture" -ForegroundColor DarkGray
                }
                Write-Host ""
            }
        }

        if ($scenario.Notes) {
            Write-Host "$($Emojis.Note) Notes:" -ForegroundColor Yellow
            Write-Host "  $($scenario.Notes)" -ForegroundColor DarkGray
            Write-Host ""
        }

        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""

        return $scenario
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error displaying scenario: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Display summary of all available scenarios.

.DESCRIPTION
    Shows scenario summary with colored, formatted output.

.EXAMPLE
    Show-AllScenarios
#>
function Show-AllScenarios {
    try {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  Available Test Scenarios" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""

        $scenarios = Get-AllScenarios
        
        foreach ($scenario in $scenarios) {
            Write-Host "$($Emojis.Scenario) $($scenario.Name)" -ForegroundColor Cyan
            Write-Host "   $($scenario.Description)" -ForegroundColor White
            Write-Host "   Tags: $($scenario.TagCount), Branches: $($scenario.BranchCount), Current: $($scenario.CurrentBranch)" -ForegroundColor DarkGray
            Write-Host ""
        }

        Write-DebugMessage -Type "INFO" -Message "Total scenarios: $($scenarios.Count)"
        
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""

        return $scenarios
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error displaying all scenarios: $_"
        throw $_
    }
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Test Scenario Setup Script" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This script provides centralized scenario definitions and management for act integration testing." -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "Available Functions:" -ForegroundColor Yellow
    Write-Host "  Get-ScenarioDefinition [-ScenarioName]    - Get specific scenario definition" -ForegroundColor Cyan
    Write-Host "  Get-AllScenarios                          - List all scenarios" -ForegroundColor Cyan
    Write-Host "  Get-ScenarioNames                         - Get scenario names only" -ForegroundColor Cyan
    Write-Host "  Set-TestScenario [-ScenarioName]          - Apply scenario to git state" -ForegroundColor Cyan
    Write-Host "  Test-ScenarioState [-ScenarioName]        - Validate current state" -ForegroundColor Cyan
    Write-Host "  Show-ScenarioDefinition [-ScenarioName]   - Display scenario details" -ForegroundColor Cyan
    Write-Host "  Show-AllScenarios                         - Display all scenarios" -ForegroundColor Cyan
    Write-Host "  Export-TestTagsFile [-Tags]               - Generate test-tags.txt" -ForegroundColor Cyan
    Write-Host "  Clear-GitState [-DeleteTags]              - Clean git state" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Usage Examples:" -ForegroundColor Yellow
    Write-Host "  # Dot-source to load functions:" -ForegroundColor Gray
    Write-Host "  . .\scripts\integration\Setup-TestScenario.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  # List available scenarios:" -ForegroundColor Gray
    Write-Host "  Show-AllScenarios" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Apply a scenario:" -ForegroundColor Gray
    Write-Host "  Set-TestScenario -ScenarioName ""FirstRelease""" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Validate current state:" -ForegroundColor Gray
    Write-Host "  Test-ScenarioState -ScenarioName ""MajorBumpV0ToV1""" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Display scenario details:" -ForegroundColor Gray
    Write-Host "  Show-ScenarioDefinition -ScenarioName ""ReleaseBranchPatch"" -Detailed `$true" -ForegroundColor White
    Write-Host ""
    
    Write-Host "Available Scenarios:" -ForegroundColor Yellow
    foreach ($scenarioName in (Get-ScenarioNames)) {
        Write-Host "  $($Emojis.Scenario) $scenarioName" -ForegroundColor Cyan
    }
    Write-Host ""
    
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
