<#
.SYNOPSIS
    Apply test fixtures to set up git state for act integration testing.

.DESCRIPTION
    This script applies test fixtures and scenarios to create reproducible git repository
    state (tags and branches) for integration testing with act. It parses fixture JSON files
    to extract scenario requirements, creates the necessary git state, and generates
    test-tags.txt in system temp directory for the bump-version.yml workflow.

    The script supports:
    - Parsing fixture JSON files to extract scenarios
    - Applying predefined scenarios directly
    - Creating git tags and branches for test scenarios
    - Generating test-tags.txt compatible with bump-version.yml
    - Validating git state against scenario requirements
    - Displaying scenario definitions for debugging

    Scenarios include:
    - FirstRelease: Clean state for initial v0.1.0 release
    - MajorBumpV0ToV1: v0.2.1 tag for testing v0 → v1 promotion

.PARAMETER FixturePath
    Path to a test fixture JSON file. The script will parse this file, extract the scenario,
    and apply it. Either FixturePath or Scenario must be provided.

.PARAMETER Scenario
    Name of a scenario to apply directly (e.g., "MajorBumpV0ToV1"). Either FixturePath or
    Scenario must be provided.

.PARAMETER CleanState
    If specified, delete existing git tags and branches before applying the fixture/scenario.
    Useful for ensuring clean, reproducible state. Default: $false.

.PARAMETER Force
    If specified, overwrite existing tags and branches during scenario application.
    Default: $false.

.PARAMETER OutputPath
    Custom path for the generated test-tags.txt file. Default: <temp>/d-flows-test-state-<guid>/test-tags.txt.

.EXAMPLE
    # Dot-source to load functions
    . .\scripts\integration\Apply-TestFixtures.ps1

    # Apply a fixture by file path
    Apply-TestFixtures -FixturePath "tests/bump-version/major-bump-main.json"

.EXAMPLE
    # Apply a scenario directly
    Apply-TestFixtures -Scenario "MajorBumpV0ToV1"

    # Apply scenario with clean state
    Apply-TestFixtures -Scenario "FirstRelease" -CleanState

.EXAMPLE
    # Validate current git state matches a scenario
    Test-ScenarioState -ScenarioName "MajorBumpV0ToV1"

    # Show scenario definition
    Show-ScenarioDefinition -ScenarioName "MajorBumpV0ToV1"

.EXAMPLE
    # List all scenarios referenced in fixture files
    Get-FixtureScenarios

.NOTES
    Fixture Format:
    - Bump-version fixtures have _comment field describing the scenario
    - Integration test fixtures have steps array with setup-git-state action
    - Both formats are supported for flexibility

    Tag Format in test-tags.txt:
    - Plain text file: "tag_name commit_sha" (one per line)
    - Matches format expected by bump-version.yml line 58
    - File is stored in system temp directory and mounted to /tmp/test-state in Docker containers
    - Comments starting with # are allowed

    Edge Cases Handled:
    - Empty repository: Creates initial commit before adding tags
    - Existing tags/branches: Optionally overwrites with Force parameter
    - Uncommitted changes: Provides clear error message for checkout conflicts
    - Invalid commit SHAs: Validates commits exist before tag/branch creation
    - Detached HEAD: Handles gracefully during branch checkout

    Integration with bump-version.yml:
    - The workflow reads test-tags.txt from /tmp/test-state/test-tags.txt (mounted from system temp) at line 58
    - All existing tags are deleted first
    - Tags are restored from test-tags.txt
    - This ensures clean, reproducible state for each act run. The temp directory is managed by the calling script.

    Test State Storage:
    - Test state stored in system temp at d-flows-test-state-<guid>/
    - Cross-platform temp path resolution (Windows: %TEMP%, Linux: /tmp)
    - Each script execution gets unique GUID-based subdirectory for isolation
    - Directory is mounted to /tmp/test-state in Docker containers

    Compatibility with GitSnapshot Module:
    - Can backup git state before applying fixtures: Backup-GitState
    - Can restore after testing: Restore-GitState -BackupName <name>
    - Recommended workflow: Backup → Apply Fixture → Run Tests → Restore
#>

# ============================================================================
# Scenario Definition Mapping
# ============================================================================

$ScenarioDefinitions = @{
    FirstRelease = @{
        Description      = "Initial release scenario - clean state with only main branch"
        Tags             = @()  # No tags
        Branches         = @("main")
        CurrentBranch    = "main"
        Notes            = "Used for testing initial v0.1.0 release (minor-bump-main.json)"
    }
    
    MajorBumpV0ToV1 = @{
        Description      = "v0 to v1 promotion scenario - v0.2.1 tag on main"
        Tags             = @(
            @{ Name = "v0.2.1"; CommitMessage = "Release v0.2.1" }
        )
        Branches         = @("main")
        CurrentBranch    = "main"
        Notes            = "Used for testing v0 → v1 promotion (major-bump-main.json, v0-to-v1-release-cycle.json)"
    }
}

# ============================================================================
# Fixture Parsing Functions
# ============================================================================

<#
.SYNOPSIS
    Parse a fixture JSON file.

.DESCRIPTION
    Reads and parses a test fixture JSON file.

.PARAMETER FixturePath
    Path to the fixture JSON file to parse.

.EXAMPLE
    $fixture = Get-FixtureContent -FixturePath "tests/bump-version/major-bump-main.json"

.NOTES
    Throws error if file not found or JSON parsing fails.
#>
function Get-FixtureContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FixturePath
    )

    try {
        if (-not (Test-Path $FixturePath)) {
            throw "Fixture file not found: $FixturePath"
        }

        Write-Message -Type "Fixture" "Reading fixture file: $FixturePath"
        $content = Get-Content -Path $FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        
        Write-Message -Type "Debug" "Fixture parsed successfully"
        return $content
    } catch {
        Write-Message -Type "Error" "Failed to parse fixture file: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Extract scenario name from a fixture.

.DESCRIPTION
    Parses fixture to extract the scenario name. Supports both integration test
    fixtures (with steps array) and bump-version fixtures (with _comment field).

.PARAMETER FixtureContent
    Parsed fixture content (JSON object).

.EXAMPLE
    $scenario = Get-ScenarioFromFixture -FixtureContent $fixture
    Write-Message -Type "Info" "Scenario: $scenario"

.NOTES
    Returns scenario name or $null if not found.
#>
function Get-ScenarioFromFixture {
    param(
        [Parameter(Mandatory = $true)]
        [object]$FixtureContent
    )

    try {
        # Try integration test fixture format (steps array with setup-git-state)
        if ($FixtureContent.steps) {
            foreach ($step in $FixtureContent.steps) {
                if ($step.action -eq "setup-git-state" -and $step.scenario) {
                    Write-Message -Type "Scenario" "Found scenario in integration test: $($step.scenario)"
                    return $step.scenario
                }
            }
        }

        # Try bump-version fixture format (_comment field with scenario reference)
        if ($FixtureContent._comment) {
            # Pattern: "Setup: Run 'setup-test-git-state.ps1 -Scenario <ScenarioName>'"
            if ($FixtureContent._comment -match "Scenario\s+(\w+)") {
                $scenario = $matches[1]
                Write-Message -Type "Scenario" "Found scenario in comment: $scenario"
                return $scenario
            }
        }

        Write-Message -Type "Debug" "No scenario found in fixture"
        return $null
    } catch {
        Write-Message -Type "Warning" "Error extracting scenario: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Extract expected git state from integration test fixture.

.DESCRIPTION
    Parses integration test fixture to extract the expected git state
    (tags, branches, current branch).

.PARAMETER FixtureContent
    Parsed fixture content (JSON object).

.EXAMPLE
    $state = Get-ExpectedStateFromFixture -FixtureContent $fixture

.NOTES
    Returns hashtable with expected state or $null if not found.
#>
function Get-ExpectedStateFromFixture {
    param(
        [Parameter(Mandatory = $true)]
        [object]$FixtureContent
    )

    try {
        if ($FixtureContent.steps) {
            foreach ($step in $FixtureContent.steps) {
                if ($step.action -eq "setup-git-state" -and $step.expectedState) {
                    Write-Message -Type "Debug" "Found expectedState in integration test"
                    return $step.expectedState
                }
            }
        }

        return $null
    } catch {
        Write-Message -Type "Warning" "Error extracting expected state: $_"
        return $null
    }
}

<#
.SYNOPSIS
    List all scenarios referenced in fixture files.

.DESCRIPTION
    Scans fixture files and returns unique scenario names found.

.PARAMETER FixturePath
    Optional path to a specific fixture file. If not provided, scans all fixtures.

.EXAMPLE
    $scenarios = Get-FixtureScenarios
    $scenarios | ForEach-Object { Write-Message -Type "Info" $_.ScenarioName }

.EXAMPLE
    $scenario = Get-FixtureScenarios -FixturePath "tests/bump-version/major-bump-main.json"

.NOTES
    Returns array of objects with ScenarioName and FixtureFile properties.
#>
function Get-FixtureScenarios {
    param(
        [string]$FixturePath
    )

    try {
        Write-Message -Type "Info" "Scanning for scenarios in fixture files"
        
        $scenarios = @()
        $processedScenarios = @{}

        if ($FixturePath) {
            # Process single fixture
            Write-Message -Type "Fixture" "Processing single fixture: $FixturePath"
            $content = Get-FixtureContent -FixturePath $FixturePath
            $scenario = Get-ScenarioFromFixture -FixtureContent $content
            
            if ($scenario) {
                $scenarios += @{
                    ScenarioName = $scenario
                    FixtureFile  = (Split-Path $FixturePath -Leaf)
                }
            }
        } else {
            # Scan all fixtures
            $repoRoot = Get-RepositoryRoot
            $integrationDir = Join-Path $repoRoot "tests/integration"
            $bumpVersionDir = Join-Path $repoRoot "tests/bump-version"

            # Scan integration fixtures
            if (Test-Path $integrationDir) {
                Write-Message -Type "Debug" "Scanning integration fixtures: $integrationDir"
                $integrationFixtures = Get-ChildItem -Path $integrationDir -Filter "*.json" -ErrorAction SilentlyContinue
                
                foreach ($fixture in $integrationFixtures) {
                    try {
                        $content = Get-FixtureContent -FixturePath $fixture.FullName
                        $scenario = Get-ScenarioFromFixture -FixtureContent $content
                        
                        if ($scenario -and -not $processedScenarios.ContainsKey($scenario)) {
                            $scenarios += @{
                                ScenarioName = $scenario
                                FixtureFile  = $fixture.Name
                            }
                            $processedScenarios[$scenario] = $true
                        }
                    } catch {
                        Write-Message -Type "Debug" "Skipping fixture due to error: $($fixture.Name)"
                    }
                }
            }

            # Scan bump-version fixtures
            if (Test-Path $bumpVersionDir) {
                Write-Message -Type "Debug" "Scanning bump-version fixtures: $bumpVersionDir"
                $bumpVersionFixtures = Get-ChildItem -Path $bumpVersionDir -Filter "*.json" -ErrorAction SilentlyContinue
                
                foreach ($fixture in $bumpVersionFixtures) {
                    try {
                        $content = Get-FixtureContent -FixturePath $fixture.FullName
                        $scenario = Get-ScenarioFromFixture -FixtureContent $content
                        
                        if ($scenario -and -not $processedScenarios.ContainsKey($scenario)) {
                            $scenarios += @{
                                ScenarioName = $scenario
                                FixtureFile  = $fixture.Name
                            }
                            $processedScenarios[$scenario] = $true
                        }
                    } catch {
                        Write-Message -Type "Debug" "Skipping fixture due to error: $($fixture.Name)"
                    }
                }
            }
        }

        if ($scenarios.Count -gt 0) {
            Write-Message -Type "Success" "Found $($scenarios.Count) scenarios"
        } else {
            Write-Message -Type "Info" "No scenarios found"
        }

        return $scenarios
    } catch {
        Write-Message -Type "Error" "Failed to scan fixtures: $_"
        throw $_
    }
}

# ============================================================================
# Scenario Application Functions
# ============================================================================

<#
.SYNOPSIS
    Apply a predefined scenario's git state.

.DESCRIPTION
    Creates the git tags and branches required by a scenario.

.PARAMETER ScenarioName
    Name of the scenario to apply (e.g., "MajorBumpV0ToV1").

.PARAMETER CleanState
    Whether to clean existing tags before applying. Default: $false.

.PARAMETER Force
    Whether to overwrite existing tags/branches. Default: $false.

.EXAMPLE
    $result = Apply-Scenario -ScenarioName "MajorBumpV0ToV1"

.EXAMPLE
    $result = Apply-Scenario -ScenarioName "FirstRelease" -CleanState -Force

.NOTES
    Returns hashtable with scenario application results including tags created,
    branches created, and path to generated test-tags.txt file.
#>
function Apply-Scenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,
        
        [bool]$CleanState = $false,
        [bool]$Force = $false,
        [object]$ExpectedState = $null,
        [string]$OutputPath
    )

    try {
        Write-Message -Type "Info" "Applying scenario: $ScenarioName"

        # Validate scenario exists
        if (-not $ScenarioDefinitions.ContainsKey($ScenarioName)) {
            $availableScenarios = $ScenarioDefinitions.Keys -join ", "
            throw "Unknown scenario: $ScenarioName. Available scenarios: $availableScenarios"
        }

        $scenario = $ScenarioDefinitions[$ScenarioName]
        Write-Message -Type "Scenario" "Scenario description: $($scenario.Description)"

        # Apply expectedState overrides if provided
        if ($ExpectedState) {
            Write-Message -Type "Debug" "Applying expectedState overrides from fixture"
            
            # Override tags if specified in expectedState
            if ($ExpectedState.tags) {
                Write-Message -Type "Debug" "Overriding tags from fixture: $($ExpectedState.tags -join ', ')"
                $scenario.Tags = @()
                foreach ($tagName in $ExpectedState.tags) {
                    $scenario.Tags += @{ Name = $tagName; CommitMessage = "Release $tagName" }
                }
            }
            
            # Override branches if specified in expectedState
            if ($ExpectedState.branches) {
                Write-Message -Type "Debug" "Overriding branches from fixture: $($ExpectedState.branches -join ', ')"
                $scenario.Branches = $ExpectedState.branches
            }
            
            # Override currentBranch if specified in expectedState
            if ($ExpectedState.currentBranch) {
                Write-Message -Type "Debug" "Overriding currentBranch from fixture: $($ExpectedState.currentBranch)"
                $scenario.CurrentBranch = $ExpectedState.currentBranch
            }
            
            Write-Message -Type "Info" "Fixture-specific state overrides applied to scenario"
        }

        # Clean state if requested
        if ($CleanState) {
            Clear-GitState -DeleteTags $true
        }

        $repoRoot = Get-RepositoryRoot
        
        # Check if repository is empty
        $hasCommits = $false
        $firstSha = $null
        try {
            $firstSha = Get-CurrentCommitSha
            $hasCommits = $true
        } catch {
            Write-Message -Type "Debug" "Repository appears to be empty, will create initial commit"
            $hasCommits = $false
        }

        # Create commits and tags
        $tagsCreated = @()
        $tagCommitMap = @{}

        foreach ($tag in $scenario.Tags) {
            try {
                # Create commit for this tag
                $sha = New-GitCommit -Message $tag.CommitMessage
                $tagCommitMap[$tag.Name] = $sha

                # Create tag
                $created = New-GitTag -TagName $tag.Name -CommitSha $sha -Force $Force
                if ($created) {
                    $tagsCreated += $tag.Name
                }
            } catch {
                Write-Message -Type "Warning" "Failed to create tag $($tag.Name): $_"
                continue
            }
        }

        # Create branches (without tags)
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

                # If we have tags, point branch to appropriate tag's commit
                # Otherwise create at HEAD
                $branchSha = $null
                foreach ($tag in $scenario.Tags) {
                    if ($tagCommitMap.ContainsKey($tag.Name)) {
                        $branchSha = $tagCommitMap[$tag.Name]
                        break
                    }
                }

                if (-not $branchSha) {
                    if ($hasCommits) {
                        $branchSha = Get-CurrentCommitSha
                    } else {
                        # Create initial commit if repository is empty
                        $branchSha = New-GitCommit -Message "Initial commit"
                    }
                }

                $created = New-GitBranch -BranchName $branch -CommitSha $branchSha -Force $Force
                if ($created) {
                    $branchesCreated += $branch
                }
            } catch {
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
            } catch {
                Write-Message -Type "Warning" "Error checking out current branch: $_"
            }
        }

        # Generate test-tags.txt
        $testTagsPath = $null
        if ($OutputPath) {
            $testTagsPath = Export-TestTagsFile -Tags $tagsCreated -OutputPath $OutputPath
        } else {
            $testTagsPath = Export-TestTagsFile -Tags $tagsCreated
        }

        Write-Message -Type "Success" "Scenario applied successfully: $ScenarioName"

        return @{
            ScenarioName      = $ScenarioName
            TagsCreated       = $tagsCreated
            BranchesCreated   = $branchesCreated
            CurrentBranch     = $scenario.CurrentBranch
            TestTagsFile      = $testTagsPath
        }
    } catch {
        Write-Message -Type "Error" "Failed to apply scenario: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Apply a test fixture to set up git state.

.DESCRIPTION
    Main public function. Parses a fixture JSON file or applies a scenario directly,
    then creates the necessary git state (tags, branches) and generates test-tags.txt.

.PARAMETER FixturePath
    Path to a test fixture JSON file. Either FixturePath or Scenario must be provided.

.PARAMETER Scenario
    Name of a scenario to apply directly. Either FixturePath or Scenario must be provided.

.PARAMETER CleanState
    Whether to clean existing tags before applying. Default: $false.

.PARAMETER Force
    Whether to overwrite existing tags/branches. Default: $false.

.PARAMETER OutputPath
    Custom path for the generated test-tags.txt file.

.EXAMPLE
    Apply-TestFixtures -FixturePath "tests/bump-version/major-bump-main.json"

.EXAMPLE
    Apply-TestFixtures -Scenario "MajorBumpV0ToV1" -CleanState

.EXAMPLE
    Apply-TestFixtures -FixturePath "tests/integration/v0-to-v1-release-cycle.json" -OutputPath "custom/test-tags.txt"

.NOTES
    Returns hashtable with scenario application results.
#>
function Apply-TestFixtures {
    param(
        [string]$FixturePath,
        [string]$Scenario,
        [bool]$CleanState = $false,
        [bool]$Force = $false,
        [string]$OutputPath
    )

    try {
        # Validate parameters
        if (-not $FixturePath -and -not $Scenario) {
            throw "Either FixturePath or Scenario parameter must be provided"
        }

        if ($FixturePath -and $Scenario) {
            Write-Message -Type "Warning" "Both FixturePath and Scenario provided, Scenario will be ignored"
            $Scenario = $null
        }

        Write-Message -Type "Info" "Starting test fixture application"

        $scenarioToApply = $null
        $fixtureOverrides = $null

        # Extract scenario from fixture if provided
        if ($FixturePath) {
            Write-Message -Type "Fixture" "Processing fixture file: $FixturePath"
            
            $content = Get-FixtureContent -FixturePath $FixturePath
            $scenarioToApply = Get-ScenarioFromFixture -FixtureContent $content
            
            if (-not $scenarioToApply) {
                Write-Message -Type "Warning" "No scenario found in fixture file: $FixturePath"
                Write-Message -Type "Info" "Fixture content available but scenario extraction failed"
                return $null
            }

            # Extract expected state from fixture if present
            $expectedState = Get-ExpectedStateFromFixture -FixtureContent $content
            if ($expectedState) {
                Write-Message -Type "Debug" "Found expectedState in fixture - applying overrides"
                $fixtureOverrides = $expectedState
            }
        } elseif ($Scenario) {
            $scenarioToApply = $Scenario
        }

        # Apply scenario with optional fixture overrides
        if ($fixtureOverrides) {
            Write-Message -Type "Debug" "Applying fixture-specific state overrides to scenario '$scenarioToApply'"
            if ($OutputPath) {
                $result = Apply-Scenario -ScenarioName $scenarioToApply -CleanState $CleanState -Force $Force -ExpectedState $fixtureOverrides -OutputPath $OutputPath
            } else {
                $result = Apply-Scenario -ScenarioName $scenarioToApply -CleanState $CleanState -Force $Force -ExpectedState $fixtureOverrides
            }
        } else {
            if ($OutputPath) {
                $result = Apply-Scenario -ScenarioName $scenarioToApply -CleanState $CleanState -Force $Force -OutputPath $OutputPath
            } else {
                $result = Apply-Scenario -ScenarioName $scenarioToApply -CleanState $CleanState -Force $Force
            }
        }

        # Update output path if specified (already handled in Apply-Scenario if OutputPath provided)
        # This is kept for backward compatibility but shouldn't regenerate if already done
        if ($OutputPath -and $result -and -not $result.TestTagsFile) {
            Write-Message -Type "Debug" "Regenerating test-tags.txt at custom path (fallback)"
            $result.TestTagsFile = Export-TestTagsFile -OutputPath $OutputPath -Tags $result.TagsCreated
        }

        return $result
    } catch {
        Write-Message -Type "Error" "Failed to apply test fixtures: $_"
        throw $_
    }
}

# ============================================================================
# Validation Functions
# ============================================================================

<#
.SYNOPSIS
    Validate that current git state matches scenario requirements.

.DESCRIPTION
    Checks if the current git state has all required tags, branches, and current branch.

.PARAMETER ScenarioName
    Name of the scenario to validate against.

.EXAMPLE
    $result = Test-ScenarioState -ScenarioName "MajorBumpV0ToV1"
    if ($result.IsValid) {
        Write-Message -Type "Success" "State matches scenario"
    }

.NOTES
    Returns hashtable with IsValid, MissingTags, MissingBranches, CurrentBranchMismatch.
#>
function Test-ScenarioState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName
    )

    try {
        Write-Message -Type "Info" "Validating scenario state: $ScenarioName"

        # Validate scenario exists
        if (-not $ScenarioDefinitions.ContainsKey($ScenarioName)) {
            throw "Unknown scenario: $ScenarioName"
        }

        $scenario = $ScenarioDefinitions[$ScenarioName]
        $missingTags = @()
        $missingBranches = @()
        $currentBranchMismatch = $false

        # Check tags
        foreach ($tag in $scenario.Tags) {
            if (-not (Test-GitTagExists -TagName $tag.Name)) {
                $missingTags += $tag.Name
                Write-Message -Type "Tag" "Missing tag: $($tag.Name)"
            }
        }

        # Check branches
        foreach ($branch in $scenario.Branches) {
            if (-not (Test-GitBranchExists -BranchName $branch)) {
                $missingBranches += $branch
                Write-Message -Type "Branch" "Missing branch: $branch"
            }
        }

        # Check current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($currentBranch -ne $scenario.CurrentBranch) {
            $currentBranchMismatch = $true
            Write-Message -Type "Debug" "Current branch mismatch: expected '$($scenario.CurrentBranch)', got '$currentBranch'"
        }

        $isValid = ($missingTags.Count -eq 0 -and $missingBranches.Count -eq 0 -and -not $currentBranchMismatch)

        if ($isValid) {
            Write-Message -Type "Success" "Git state matches scenario: $ScenarioName"
        } else {
            Write-Message -Type "Warning" "Git state does not match scenario"
        }

        return @{
            IsValid                  = $isValid
            MissingTags              = $missingTags
            MissingBranches          = $missingBranches
            CurrentBranchMismatch    = $currentBranchMismatch
            ExpectedCurrentBranch    = $scenario.CurrentBranch
            ActualCurrentBranch      = $currentBranch
        }
    } catch {
        Write-Message -Type "Error" "Error validating scenario state: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Display scenario definition for debugging.

.DESCRIPTION
    Shows the tags, branches, and other details of a scenario.

.PARAMETER ScenarioName
    Name of the scenario to display.

.EXAMPLE
    Show-ScenarioDefinition -ScenarioName "MajorBumpV0ToV1"

.NOTES
    Displays formatted output with colored sections.
#>
function Show-ScenarioDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName
    )

    try {
        # Validate scenario exists
        if (-not $ScenarioDefinitions.ContainsKey($ScenarioName)) {
            $availableScenarios = $ScenarioDefinitions.Keys -join ", "
            Write-Message -Type "Error" "Unknown scenario: $ScenarioName. Available: $availableScenarios"
            return
        }

        $scenario = $ScenarioDefinitions[$ScenarioName]

        Write-Message -Type "Info" "==============================================================================" -ForegroundColor Cyan
        Write-Message -Type "Info" "  Scenario: $ScenarioName" -ForegroundColor Cyan
        Write-Message -Type "Info" "==============================================================================" -ForegroundColor Cyan
        Write-Message -Type "Info" "Description:" -ForegroundColor Yellow
        Write-Message -Type "Info" "  $($scenario.Description)" -ForegroundColor Gray
        Write-Message -Type "Info" "Tags:" -ForegroundColor Yellow
        if ($scenario.Tags.Count -eq 0) {
            Write-Message -Type "Info" "  (none)" -ForegroundColor Gray
        } else {
            foreach ($tag in $scenario.Tags) {
                Write-Message -Type "Tag" "  $($tag.Name) - $($tag.CommitMessage)"
            }
        }
        Write-Message -Type "Info" "Branches:" -ForegroundColor Yellow
        if ($scenario.Branches.Count -eq 0) {
            Write-Message -Type "Info" "  (none)" -ForegroundColor Gray
        } else {
            foreach ($branch in $scenario.Branches) {
                Write-Message -Type "Branch" "  $branch"
            }
        }
        Write-Message -Type "Info" "Current Branch:" -ForegroundColor Yellow
        Write-Message -Type "Info" "  $($scenario.CurrentBranch)" -ForegroundColor Cyan
        if ($scenario.Notes) {
            Write-Message -Type "Info" "Notes:" -ForegroundColor Yellow
            Write-Message -Type "Info" "  $($scenario.Notes)" -ForegroundColor Gray
            }

        Write-Message -Type "Info" "==============================================================================" -ForegroundColor Cyan
        return $scenario
    } catch {
        Write-Message -Type "Error" "Error displaying scenario: $_"
        throw $_
    }
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Message -Type "Info" "==============================================================================" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Test Fixtures Application Script" -ForegroundColor Cyan
    Write-Message -Type "Info" "==============================================================================" -ForegroundColor Cyan
    Write-Message -Type "Info" "This script applies test fixtures to set up git state for act integration testing." -ForegroundColor Gray

    Write-Message -Type "Info" "Available Functions:" -ForegroundColor Yellow
    Write-Message -Type "Info" "  Apply-TestFixtures [-FixturePath | -Scenario] - Apply fixture or scenario" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Apply-Scenario [-ScenarioName]              - Apply scenario directly" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Get-FixtureScenarios                        - List scenarios from fixtures" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Show-ScenarioDefinition [-ScenarioName]     - Display scenario details" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Test-ScenarioState [-ScenarioName]          - Validate git state" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Export-TestTagsFile                         - Generate test-tags.txt" -ForegroundColor Cyan
    Write-Message -Type "Info" "  Clear-GitState                              - Clean existing git state" -ForegroundColor Cyan

    Write-Message -Type "Info" "Available Scenarios:" -ForegroundColor Yellow
    foreach ($scenarioName in $ScenarioDefinitions.Keys) {
        $scenario = $ScenarioDefinitions[$scenarioName]
        Write-Message -Type "Scenario" "  $scenarioName"
        Write-Message -Type "Info" "      $($scenario.Description)" -ForegroundColor Gray
    }

    Write-Message "Usage Examples:" -ForegroundColor Yellow
    Write-Message "  # Dot-source to load functions:" -ForegroundColor Gray
    Write-Message "  . .\scripts\integration\Apply-TestFixtures.ps1" -ForegroundColor White
    Write-Message "  # Apply fixture by file path:" -ForegroundColor Gray
    Write-Message "  Apply-TestFixtures -FixturePath 'tests/bump-version/major-bump-main.json'" -ForegroundColor White
    Write-Message "  # Apply scenario directly:" -ForegroundColor Gray
    Write-Message "  Apply-TestFixtures -Scenario 'MajorBumpV0ToV1'" -ForegroundColor White
    Write-Message "  # List available scenarios:" -ForegroundColor Gray
    Write-Message "  Get-FixtureScenarios" -ForegroundColor White
    Write-Message "  # Validate current state:" -ForegroundColor Gray
    Write-Message "  Test-ScenarioState -ScenarioName 'MajorBumpV0ToV1'" -ForegroundColor White
    Write-Message "==============================================================================" -ForegroundColor Cyan
    Write-Message ""
}





