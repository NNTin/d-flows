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
    - Exporting test-branches.txt file for workflow branch restoration
    - Exporting test-commits.bundle with all commit objects for workflow access

    Generated Files (when GenerateTestTagsFile is enabled):
    - test-tags.txt: Tag names and commit SHAs for workflow restoration
    - test-branches.txt: Branch names and commit SHAs for workflow restoration
    - test-commits.bundle: Git bundle containing all commit objects referenced by tags/branches
      (The workflow unbundles commits before restoring tags to ensure commit SHAs exist)

    Supported Scenarios:
    - FirstRelease: Initial release scenario - clean state with only main branch
    - MajorBumpV0ToV1: v0 to v1 promotion - v0.2.1 tag on main

    This script is designed to be:
    - Dot-sourceable for use by other integration testing scripts
    - Compatible with Apply-TestFixtures.ps1 and GitSnapshot module
    - Integrated with bump-version.yml workflow (line 58)
    - Exporting test-tags.txt file to system temp directory for bump-version.yml workflow access

.PARAMETER ScenarioName
    Used by functions that require a specific scenario (e.g., Get-ScenarioDefinition, Invoke-TestScenario).
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
    Invoke-TestScenario -ScenarioName "MajorBumpV0ToV1" -CleanState

.EXAMPLE
    # Validate current git state against a scenario
    $result = Test-ScenarioState -ScenarioName "FirstRelease"
    if ($result.IsValid) {
        Write-Message -Type "Success" "Git state is valid for scenario"
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
    - The workflow reads test-tags.txt from /tmp/test-state/test-tags.txt (mounted from system temp) at line 58
    - Format must match: "tag_name commit_sha" (one per line)
    - All existing tags are deleted first, then restored from this file
    - This ensures clean, reproducible state for each act run. The temp directory is automatically cleaned up after test execution.

    Test State Storage:
    - Test state stored in system temp at d-flows-test-state-<guid>/
    - Each script execution gets unique GUID-based subdirectory for isolation
    - Cross-platform: Windows (%TEMP%), Linux (/tmp)
    - Directory is mounted to /tmp/test-state in Docker containers for act workflows
    - The calling script (Run-ActTests.ps1) manages cleanup

    Compatibility:
    - Works with Apply-TestFixtures.ps1 for fixture application
    - Works with GitSnapshot module for state backup/restore
    - Can be dot-sourced by Run-ActTests.ps1 and other test runners

    Edge Cases Handled:
    - Empty repositories: Creates initial commit before adding tags
    - Existing tags/branches: Optionally overwrites with Force parameter
    - Uncommitted changes: Provides clear error message for checkout conflicts
    - Invalid commit SHAs: Validates commits exist before tag/branch creation
    - Detached HEAD: Handles gracefully during branch checkout

    Testing Workflow:
    1. Backup production state: $backup = Backup-GitState
    2. Apply test scenario: Invoke-TestScenario -ScenarioName "MajorBumpV0ToV1"
    3. Run act workflows: act -j bump-version --eventpath tests/bump-version/major-bump-main.json
    4. Validate results: Test-ScenarioState -ScenarioName "MajorBumpV0ToV1"
    5. Restore production state: Restore-GitState -BackupName $backup.BackupName
#>

# ============================================================================
# Scenario Definition Mapping
# ============================================================================

$ScenarioDefinitions = @{
    FirstRelease    = @{
        Description     = "Initial release scenario - clean state with only main branch, no existing tags"
        Tags            = @()
        Branches        = @("main")
        CurrentBranch   = "main"
        Notes           = "Used for testing initial v0.1.0 release. Referenced in: minor-bump-main.json. Documented in VERSIONING.md under 'Creating the First Release'."
        ExpectedVersion = "0.1.0"
        TestFixtures    = @("tests/bump-version/minor-bump-main.json")
    }

    MajorBumpV0ToV1 = @{
        Description            = "v0 to v1 promotion scenario - v0.2.1 tag exists on main branch"
        Tags                   = @(
            @{ Name = "v0.2.1"; CommitMessage = "Release v0.2.1" }
        )
        Branches               = @("main")
        CurrentBranch          = "main"
        Notes                  = "Used for testing v0 → v1 promotion with automatic release/v0 branch creation. Referenced in: major-bump-main.json, v0-to-v1-release-cycle.json. Documented in VERSIONING.md under 'Promoting to v1.0.0'."
        ExpectedVersion        = "1.0.0"
        ExpectedBranchCreation = "release/v0"
        TestFixtures           = @("tests/bump-version/major-bump-main.json", "tests/integration/v0-to-v1-release-cycle.json")
    }
}

Write-Message -Type "Debug" "Loaded $($ScenarioDefinitions.Count) scenario definitions"

# ============================================================================
# Helper Functions
# ============================================================================

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

        Write-Message -Type "Scenario" "Retrieved scenario definition: $ScenarioName"
        return $ScenarioDefinitions[$ScenarioName]
    }
    catch {
        Write-Message -Type "Error" $_
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
    Write-Message -Type "Debug" "Listing all available scenarios"

    $scenarios = @()
    foreach ($scenarioName in $ScenarioDefinitions.Keys) {
        $scenario = $ScenarioDefinitions[$scenarioName]
        $scenarios += @{
            Name          = $scenarioName
            Description   = $scenario.Description
            TagCount      = $scenario.Tags.Count
            BranchCount   = $scenario.Branches.Count
            CurrentBranch = $scenario.CurrentBranch
            TestFixtures  = $scenario.TestFixtures
        }
    }

    Write-Message -Type "Debug" "Found $($scenarios.Count) scenarios"
    return $scenarios
}

<#
.SYNOPSIS
    Get list of all scenario names.

.DESCRIPTION
    Returns just the scenario names without additional details.

.EXAMPLE
    $names = Get-ScenarioNames
    Write-Message -Type "Info" "Available: $($names -join ', ')"

.NOTES
    Returns array of scenario names.
#>
function Get-ScenarioNames {
    Write-Message -Type "Debug" "Retrieved scenario names"
    return @($ScenarioDefinitions.Keys)
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
    Generate test-tags.txt in temp directory for bump-version.yml (default: true).

.PARAMETER OutputPath
    Custom output path for test-tags.txt file (optional). If not provided, uses shared test state base path
    or generates GUID-based path. When called from Run-ActTests.ps1, the shared directory is used automatically.

.EXAMPLE
    Invoke-TestScenario -ScenarioName "FirstRelease"

.EXAMPLE
    Invoke-TestScenario -ScenarioName "MajorBumpV0ToV1" -CleanState $true -Force $true

.EXAMPLE
    Invoke-TestScenario -ScenarioName "MajorBumpV0ToV1" -OutputPath "C:\temp\my-test-state\test-tags.txt"

.NOTES
    Generates three files when GenerateTestTagsFile is true:
    - test-tags.txt: Tag names and commit SHAs for workflow restoration
    - test-branches.txt: Branch names and commit SHAs for workflow restoration
    - test-commits.bundle: Git bundle with all commit objects referenced by tags/branches

    Returns ProductionTagsDeleted array containing the names of production tags that were deleted when CleanState=$true

    Integrates with bump-version.yml workflow which reads these files from TEST_STATE_PATH.
    The workflow unbundles commits before restoring tags to ensure commit SHAs exist.
    Use Backup-GitState.ps1 to backup state before applying scenarios.
#>
function Invoke-TestScenario {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,

        [bool]$CleanState = $false,
        [bool]$Force = $false,
        [bool]$GenerateTestTagsFile = $true,
        [string]$OutputPath
    )
    try {
        Write-Message -Type "Info" "Applying test scenario: $ScenarioName"

        # Get scenario definition
        $scenario = Get-ScenarioDefinition -ScenarioName $ScenarioName
        Write-Message -Type "Scenario" "Scenario description: $($scenario.Description)"

        # Clean state if requested and capture production tags deleted
        $productionTagsDeleted = @()
        if ($CleanState) {
            $cleanStateResult = Clear-GitState -DeleteTags $true
            if ($cleanStateResult.PSObject.Properties.Name -contains 'DeletedTagNames') {
                $productionTagsDeleted = @($cleanStateResult.DeletedTagNames)
                Write-Message -Type "Debug" "Captured $($productionTagsDeleted.Count) production tags deleted during clean state"
            }
        }

        # Check if repository is empty
        $hasCommits = $false
        try {
            $sha = Get-CurrentCommitSha
            $hasCommits = $true
        }
        catch {
            Write-Message -Type "Debug" "Repository appears to be empty, will create initial commit"
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
            }
            catch {
                Write-Message -Type "Warning" "Failed to create tag $($tag.Name): $_"
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
                        Write-Message -Type "Branch" "Branch already exists, skipping: $branch"
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
                    }
                    else {
                        # Create initial commit if repository is empty
                        $branchSha = New-GitCommit -Message "Initial commit"
                        $hasCommits = $true
                    }
                }

                $created = New-GitBranch -BranchName $branch -CommitSha $branchSha -Force $Force
                if ($created) {
                    $branchesCreated += $branch
                }
            }
            catch {
                Write-Message -Type "Warning" "Failed to create branch ${branch}: $_"
                continue
            }
        }

        # Checkout current branch
        if ($scenario.CurrentBranch) {
            try {
                $checkoutSuccess = Set-GitBranch -BranchName $scenario.CurrentBranch
                if (-not $checkoutSuccess) {
                    Write-Message -Type "Warning" "Failed to checkout current branch, continuing anyway"
                }
            }
            catch {
                Write-Message -Type "Warning" "Error checking out current branch: $_"
            }
        }

        # Generate test-tags.txt
        $testTagsPath = $null
        $testBranchesPath = $null
        $testCommitsPath = $null
        if ($GenerateTestTagsFile) {
            if ($OutputPath) {
                $testTagsPath = Export-TestTagsFile -Tags $tagsCreated -OutputPath $OutputPath
                # Construct branches file path from tags path
                $branchesOutputPath = $OutputPath -replace 'test-tags\.txt$', 'test-branches.txt'
                $testBranchesPath = Export-TestBranchesFile -Branches $branchesCreated -OutputPath $branchesOutputPath
                # Construct commits bundle path from tags path
                $commitsOutputPath = $OutputPath -replace 'test-tags\.txt$', 'test-commits.bundle'
                $testCommitsPath = Export-TestCommitsBundle -Tags $tagsCreated -Branches $branchesCreated -OutputPath $commitsOutputPath
            }
            else {
                $testTagsPath = Export-TestTagsFile -Tags $tagsCreated
                $testBranchesPath = Export-TestBranchesFile -Branches $branchesCreated
                $testCommitsPath = Export-TestCommitsBundle -Tags $tagsCreated -Branches $branchesCreated
            }
            Write-Message -Type "Branch" "Test branches file exported to: $testBranchesPath"
            Write-Message -Type "Backup" "Test commits bundle exported to: $testCommitsPath"
        }

        Write-Message -Type "Success" "Scenario applied successfully: $ScenarioName"

        return @{
            ScenarioName          = $ScenarioName
            TagsCreated           = $tagsCreated
            ProductionTagsDeleted = $productionTagsDeleted
            BranchesCreated       = $branchesCreated
            CurrentBranch         = $scenario.CurrentBranch
            TestTagsFile          = $testTagsPath
            TestBranchesFile      = $testBranchesPath
            TestCommitsBundle     = $testCommitsPath
            CommitMap             = $commitMap
            Success               = $true
        }
    }
    catch {
        Write-Message -Type "Error" "Failed to apply scenario: $_"
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
        Write-Message -Type "Success" "Valid"
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
        Write-Message -Type "Info" "Validating git state against scenario: $ScenarioName"

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
                Write-Message -Type "Tag" "❌ Missing tag: $($tag.Name)"
                $validationMessages += "Missing tag: $($tag.Name)"
            }
            else {
                Write-Message -Type "Tag" "✅ Tag exists: $($tag.Name)"
                $validationMessages += "✅ Tag exists: $($tag.Name)"
            }
        }

        # Check branches
        foreach ($branch in $scenario.Branches) {
            if (-not (Test-GitBranchExists -BranchName $branch)) {
                $missingBranches += $branch
                $isValid = $false
                Write-Message -Type "Branch" "❌ Missing branch: $branch"
                $validationMessages += "Missing branch: $branch"
            }
            else {
                Write-Message -Type "Branch" "✅ Branch exists: $branch"
                $validationMessages += "✅ Branch exists: $branch"
            }
        }

        # Check current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($currentBranch -ne $scenario.CurrentBranch) {
            $currentBranchMismatch = $true
            $isValid = $false
            Write-Message -Type "Debug" "❌ Current branch mismatch: expected '$($scenario.CurrentBranch)', got '$currentBranch'"
            $validationMessages += "Current branch mismatch: expected '$($scenario.CurrentBranch)', got '$currentBranch'"
        }
        else {
            Write-Message -Type "Debug" "✅ Current branch correct: $currentBranch"
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
                    Write-Message -Type "Tag" "⚠️ Extra tag: $tag"
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
                    Write-Message -Type "Branch" "⚠️ Extra branch: $branch"
                    $validationMessages += "Extra branch (Strict mode): $branch"
                }
            }
        }

        # Build summary message
        if ($isValid) {
            Write-Message -Type "Success" "✅ Git state matches scenario: $ScenarioName"
        }
        else {
            $summary = "Git state does NOT match scenario: Missing tags: $($missingTags.Count), Missing branches: $($missingBranches.Count)"
            if ($currentBranchMismatch) {
                $summary += ", Branch mismatch: true"
            }
            Write-Message -Type "Warning" $summary
        }

        return @{
            IsValid               = $isValid
            MissingTags           = $missingTags
            MissingBranches       = $missingBranches
            ExtraTags             = $extraTags
            ExtraBranches         = $extraBranches
            CurrentBranchMismatch = $currentBranchMismatch
            ExpectedCurrentBranch = $scenario.CurrentBranch
            ActualCurrentBranch   = $currentBranch
            ValidationMessages    = $validationMessages
        }
    }
    catch {
        Write-Message -Type "Error" "Error validating scenario state: $_"
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

        Write-Message ""
        Write-Message "═══════════════════════════════════════════════════════════════════════════"
        Write-Message "  Scenario: $ScenarioName"
        Write-Message "═══════════════════════════════════════════════════════════════════════════"
        Write-Message ""

        Write-Message -Type "Info" "Description:"
        Write-Message -Type "Info" "  $($scenario.Description)"
        Write-Message ""

        Write-Message -Type "Tag" "Tags:"
        if ($scenario.Tags.Count -eq 0) {
            Write-Message -Type "Info" "  (none)"
        }
        else {
            foreach ($tag in $scenario.Tags) {
                Write-Message -Type "Tag" "  • $($tag.Name) - $($tag.CommitMessage)"
            }
        }
        Write-Message ""

        Write-Message -Type "Branch" "Branches:"
        if ($scenario.Branches.Count -eq 0) {
            Write-Message -Type "Info" "  (none)"
        }
        else {
            foreach ($branch in $scenario.Branches) {
                Write-Message -Type "Branch" "  • $branch"
            }
        }
        Write-Message -Type "Info" "📍 Current Branch:" -ForegroundColor Yellow
        Write-Message -Type "Info" "  $($scenario.CurrentBranch)" -ForegroundColor Green
        if ($Detailed) {
            Write-Message -Type "Target" "Expected Version:"
            Write-Message -Type "Info" "  $($scenario.ExpectedVersion)" -ForegroundColor Cyan
            if ($scenario.ExpectedBranchCreation) {
                Write-Message -Type "Info" "➕ Expected Branch Creation:" -ForegroundColor Yellow
                Write-Message -Type "Info" "  $($scenario.ExpectedBranchCreation)" -ForegroundColor Cyan
            }

            if ($scenario.TestFixtures) {
                Write-Message -Type "List" "Test Fixtures:"
                foreach ($fixture in $scenario.TestFixtures) {
                    Write-Message -Type "Info" "  • $fixture" -ForegroundColor DarkGray
                }
            }
        }

        if ($scenario.Notes) {
            Write-Message -Type "Note" "Notes:"
            Write-Message -Type "Info" "  $($scenario.Notes)" -ForegroundColor DarkGray
        }

        Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        return $scenario
    }
    catch {
        Write-Message -Type "Error" "Error displaying scenario: $_"
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
        Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Message "  Available Test Scenarios" -ForegroundColor Cyan
        Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        $scenarios = Get-AllScenarios

        foreach ($scenario in $scenarios) {
            Write-Message -Type "Scenario" "$($scenario.Name)"
            Write-Message -Type "Info" "   $($scenario.Description)" -ForegroundColor White
            Write-Message -Type "Info" "   Tags: $($scenario.TagCount), Branches: $($scenario.BranchCount), Current: $($scenario.CurrentBranch)" -ForegroundColor DarkGray
        }

        Write-Message -Type "Info" "Total scenarios: $($scenarios.Count)"

        Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        return $scenarios
    }
    catch {
        Write-Message -Type "Error" "Error displaying all scenarios: $_"
        throw $_
    }
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message "  Test Scenario Setup Script" -ForegroundColor Cyan
    Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message "This script provides centralized scenario definitions and management for act integration testing." -ForegroundColor Gray

    Write-Message "Available Functions:" -ForegroundColor Yellow
    Write-Message "  Get-ScenarioDefinition [-ScenarioName]    - Get specific scenario definition" -ForegroundColor Cyan
    Write-Message "  Get-AllScenarios                          - List all scenarios" -ForegroundColor Cyan
    Write-Message "  Get-ScenarioNames                         - Get scenario names only" -ForegroundColor Cyan
    Write-Message "  Invoke-TestScenario [-ScenarioName]          - Apply scenario to git state" -ForegroundColor Cyan
    Write-Message "  Test-ScenarioState [-ScenarioName]        - Validate current state" -ForegroundColor Cyan
    Write-Message "  Show-ScenarioDefinition [-ScenarioName]   - Display scenario details" -ForegroundColor Cyan
    Write-Message "  Show-AllScenarios                         - Display all scenarios" -ForegroundColor Cyan
    Write-Message "  Export-TestTagsFile [-Tags]               - Generate test-tags.txt" -ForegroundColor Cyan
    Write-Message "  Clear-GitState [-DeleteTags]              - Clean git state" -ForegroundColor Cyan

    Write-Message "Usage Examples:" -ForegroundColor Yellow
    Write-Message "  # Dot-source to load functions:" -ForegroundColor Gray
    Write-Message "  . .\scripts\integration\Setup-TestScenario.ps1" -ForegroundColor White
    Write-Message "  # List available scenarios:" -ForegroundColor Gray
    Write-Message "  Show-AllScenarios" -ForegroundColor White
    Write-Message "  # Apply a scenario:" -ForegroundColor Gray
    Write-Message "  Invoke-TestScenario -ScenarioName ""FirstRelease""" -ForegroundColor White
    Write-Message "  # Validate current state:" -ForegroundColor Gray
    Write-Message "  Test-ScenarioState -ScenarioName ""MajorBumpV0ToV1""" -ForegroundColor White

    Write-Message "Available Scenarios:" -ForegroundColor Yellow
    foreach ($scenarioName in (Get-ScenarioNames)) {
        Write-Message -Type "Scenario" "  $scenarioName"
    }

    Write-Message "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message ""
}
