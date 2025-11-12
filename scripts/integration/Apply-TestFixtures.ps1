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
    - MajorBumpV1ToV2: v1.2.0 tag for testing v1 → v2 promotion
    - MinorBump: v0.1.0 tag for testing minor version bumps
    - ReleaseBranchPatch: v1.2.0 and v2.0.0 tags on different branches
    - InvalidBranch: Feature branch with invalid naming for error testing

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

    Compatibility with Backup-GitState.ps1:
    - Can backup git state before applying fixtures: Backup-GitState
    - Can restore after testing: Restore-GitState -BackupName <name>
    - Recommended workflow: Backup → Apply Fixture → Run Tests → Restore
#>

# ============================================================================
# Global Variables and Configuration
# ============================================================================

# Generate a unique GUID for this script execution to ensure consistent temp directory naming
$script:TestStateGuid = [guid]::NewGuid().ToString('N')

# Get temp-based test state directory path
# If Run-ActTests.ps1 has set $env:DFLOWS_TEST_STATE_BASE, use that to ensure unified test state
# Otherwise, generate a new GUID-based path for standalone use
function Get-TestStateBasePath {
    # Check if shared environment variable is set (when called from Run-ActTests.ps1)
    if ($env:DFLOWS_TEST_STATE_BASE) {
        return $env:DFLOWS_TEST_STATE_BASE
    }
    
    # Fall back to GUID-based path for standalone use
    $tempPath = [System.IO.Path]::GetTempPath()
    $testStateDirName = "d-flows-test-state-$($script:TestStateGuid)"
    return Join-Path $tempPath $testStateDirName
}

$TestStateDirectory = Get-TestStateBasePath
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
    Fixture  = "📄"
    Scenario = "🎯"
}

# ============================================================================
# Scenario Definition Mapping
# ============================================================================

$ScenarioDefinitions = @{
    FirstRelease = @{
        Description      = "Initial release scenario - clean state with only main branch"
        Tags             = @()  # No tags
        Branches         = @("main")
        CurrentBranch    = "main"
        Notes            = "Used for testing initial v0.1.0 release (fminor-bump-main.json, multi-step-version-progression.json)"
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
    
    MajorBumpV1ToV2 = @{
        Description      = "v1 to v2 promotion scenario - v1.2.0 tag on main, no release/v1 yet"
        Tags             = @(
            @{ Name = "v1.2.0"; CommitMessage = "Release v1.2.0" }
        )
        Branches         = @("main")
        CurrentBranch    = "main"
        Notes            = "Used for testing v1 → v2 promotion (major-bump-main.json, release-branch-lifecycle.json)"
    }
    
    MinorBump = @{
        Description      = "Minor version bump scenario - v0.1.0 tag on main"
        Tags             = @(
            @{ Name = "v0.1.0"; CommitMessage = "Release v0.1.0" }
        )
        Branches         = @("main")
        CurrentBranch    = "main"
        Notes            = "Used for testing minor version bumps (minor-bump-main.json)"
    }
    
    ReleaseBranchPatch = @{
        Description      = "Release branch patch scenario - v1.2.0 on release/v1, v2.0.0 on main"
        Tags             = @(
            @{ Name = "v1.2.0"; CommitMessage = "Release v1.2.0" }
            @{ Name = "v2.0.0"; CommitMessage = "Release v2.0.0" }
        )
        Branches         = @("main", "release/v1")
        CurrentBranch    = "release/v1"
        Notes            = "Used for testing patches on older major versions (patch-bump-release-branch.json)"
    }
    
    InvalidBranch = @{
        Description      = "Invalid branch format scenario - for error testing"
        Tags             = @(
            @{ Name = "v0.1.0"; CommitMessage = "Release v0.1.0" }
        )
        Branches         = @("main", "feature/test-branch")
        CurrentBranch    = "feature/test-branch"
        Notes            = "Used for testing branch validation errors (error-invalid-branch-format.json, rollback-invalid-branch.json)"
    }
}

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
    $currentPath = Get-Location
    $searchPath = $currentPath

    while ($searchPath.Path -ne (Split-Path $searchPath.Path)) {
        Write-Debug "$($Emojis.Debug) Searching for .git in: $searchPath"
        
        $gitPath = Join-Path $searchPath.Path ".git"
        if (Test-Path $gitPath) {
            Write-Debug "$($Emojis.Debug) Found repository root: $($searchPath.Path)"
            return $searchPath.Path
        }
        
        $searchPath = Split-Path $searchPath.Path -Parent
    }

    throw "❌ Not in a git repository. Please navigate to the repository root and try again."
}

<#
.SYNOPSIS
    Create the test state directory if it doesn't exist.

.DESCRIPTION
    Creates test state directory in system temp location.

.EXAMPLE
    $testStateDir = New-TestStateDirectory

.NOTES
    Returns the full path to the test state directory in temp.
#>
function New-TestStateDirectory {
    $fullTestStatePath = Get-TestStateBasePath
    
    if (-not (Test-Path $fullTestStatePath)) {
        Write-Debug "$($Emojis.Debug) Creating temp test state directory: $fullTestStatePath"
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

        Write-Debug "$($Emojis.Fixture) Reading fixture file: $FixturePath"
        $content = Get-Content -Path $FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        
        Write-Debug "$($Emojis.Debug) Fixture parsed successfully"
        return $content
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to parse fixture file: $_"
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
    Write-Host "Scenario: $scenario"

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
                    Write-Debug "$($Emojis.Scenario) Found scenario in integration test: $($step.scenario)"
                    return $step.scenario
                }
            }
        }

        # Try bump-version fixture format (_comment field with scenario reference)
        if ($FixtureContent._comment) {
            # Pattern: "Setup: Run 'setup-test-git-state.ps1 -Scenario <ScenarioName>'"
            if ($FixtureContent._comment -match "Scenario\s+(\w+)") {
                $scenario = $matches[1]
                Write-Debug "$($Emojis.Scenario) Found scenario in comment: $scenario"
                return $scenario
            }
        }

        Write-Debug "$($Emojis.Debug) No scenario found in fixture"
        return $null
    } catch {
        Write-DebugMessage -Type "WARNING" -Message "Error extracting scenario: $_"
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
                    Write-Debug "$($Emojis.Debug) Found expectedState in integration test"
                    return $step.expectedState
                }
            }
        }

        return $null
    } catch {
        Write-DebugMessage -Type "WARNING" -Message "Error extracting expected state: $_"
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
    $scenarios | ForEach-Object { Write-Host $_.ScenarioName }

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
        Write-DebugMessage -Type "INFO" -Message "Scanning for scenarios in fixture files"
        
        $scenarios = @()
        $processedScenarios = @{}

        if ($FixturePath) {
            # Process single fixture
            Write-Debug "$($Emojis.Fixture) Processing single fixture: $FixturePath"
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
                Write-Debug "$($Emojis.Debug) Scanning integration fixtures: $integrationDir"
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
                        Write-Debug "$($Emojis.Debug) Skipping fixture due to error: $($fixture.Name)"
                    }
                }
            }

            # Scan bump-version fixtures
            if (Test-Path $bumpVersionDir) {
                Write-Debug "$($Emojis.Debug) Scanning bump-version fixtures: $bumpVersionDir"
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
                        Write-Debug "$($Emojis.Debug) Skipping fixture due to error: $($fixture.Name)"
                    }
                }
            }
        }

        if ($scenarios.Count -gt 0) {
            Write-DebugMessage -Type "SUCCESS" -Message "Found $($scenarios.Count) scenarios"
        } else {
            Write-DebugMessage -Type "INFO" -Message "No scenarios found"
        }

        return $scenarios
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to scan fixtures: $_"
        throw $_
    }
}

# ============================================================================
# Git State Creation Functions
# ============================================================================

<#
.SYNOPSIS
    Create a git commit.

.DESCRIPTION
    Creates a new commit in the repository. Useful for creating test commits
    that can be tagged.

.PARAMETER Message
    The commit message.

.PARAMETER AllowEmpty
    Whether to allow empty commits (commits with no file changes).
    Default: $true for test commits.

.EXAMPLE
    $sha = New-GitCommit -Message "Test commit for v1.0.0"

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
        # TODO: Creating commits is not feasible in this context as the commit will be lost on git checkout.
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
        Write-Debug "$($Emojis.Tag) Commit created: $sha"

        $sha = Get-CurrentCommitSha
        # Write-Debug "$($Emojis.Tag) We cannot create a commit because the commit will be lost on git checkout, we are not pushing: $sha"
        
        return $sha
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to create commit: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Create a git tag.

.DESCRIPTION
    Creates a git tag at the specified commit.

.PARAMETER TagName
    The name of the tag to create.

.PARAMETER CommitSha
    The commit SHA to tag. Defaults to HEAD.

.PARAMETER Force
    Whether to overwrite existing tags. Default: $false.

.EXAMPLE
    $created = New-GitTag -TagName "v1.0.0"

.EXAMPLE
    $created = New-GitTag -TagName "v1.0.0" -CommitSha "abc123def456" -Force

.NOTES
    Returns $true if tag was created, $false if skipped due to existing tag.
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
                Write-DebugMessage -Type "WARNING" -Message "Tag already exists and Force not set: $TagName"
                return $false
            }

            # Delete existing tag if force is enabled
            Write-Debug "$($Emojis.Debug) Deleting existing tag for force restore: $TagName"
            git tag -d $TagName 2>&1 | Out-Null
        }

        # Create tag
        git tag $TagName $CommitSha 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create tag"
        }

        Write-Debug "$($Emojis.Tag) Tag created successfully: $TagName"
        return $true
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to create tag '$TagName': $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Create a git branch.

.DESCRIPTION
    Creates a git branch at the specified commit.

.PARAMETER BranchName
    The name of the branch to create.

.PARAMETER CommitSha
    The commit SHA for the branch. Defaults to HEAD.

.PARAMETER Force
    Whether to overwrite existing branches. Default: $false.

.EXAMPLE
    $created = New-GitBranch -BranchName "release/v1"

.EXAMPLE
    $created = New-GitBranch -BranchName "release/v1" -CommitSha "abc123def456" -Force

.NOTES
    Returns $true if branch was created, $false if skipped due to existing branch.
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
                Write-DebugMessage -Type "WARNING" -Message "Branch already exists and Force not set: $BranchName"
                return $false
            }

            # Check if this is the current branch
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            if ($currentBranch -eq $BranchName) {
                Write-DebugMessage -Type "WARNING" -Message "Cannot delete current branch: $BranchName"
                return $false
            }

            # Delete existing branch if force is enabled
            Write-Debug "$($Emojis.Debug) Deleting existing branch for force restore: $BranchName"
            git branch -D $BranchName 2>&1 | Out-Null
        }

        # Create branch
        git branch $BranchName $CommitSha 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create branch"
        }

        Write-Debug "$($Emojis.Branch) Branch created successfully: $BranchName"
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
    The name of the branch to checkout.

.EXAMPLE
    Set-GitBranch -BranchName "main"

.NOTES
    Returns $true if successful, $false otherwise.
    Provides clear error message about uncommitted changes if checkout fails.
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

        Write-Debug "$($Emojis.Branch) Branch checked out: $BranchName"
        return $true
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to checkout branch '$BranchName': $_"
        return $false
    }
}

# ============================================================================
# Test Tags File Generation
# ============================================================================

<#
.SYNOPSIS
    Generate test-tags.txt file for bump-version.yml workflow.

.DESCRIPTION
    Creates a test-tags.txt file in the format expected by the bump-version.yml
    workflow. The file contains all test tags in "tag_name commit_sha" format.

.PARAMETER OutputPath
    Path to write the test-tags.txt file. Defaults to .test-state/test-tags.txt.

.PARAMETER Tags
    Array of tag names to export. If not provided, exports all tags in repository.

.EXAMPLE
    Export-TestTagsFile -Tags @("v0.2.1", "v1.0.0")

.EXAMPLE
    Export-TestTagsFile -OutputPath "custom/path/test-tags.txt" -Tags @("v1.0.0")

.NOTES
    Output format matches bump-version.yml lines 58-79 expectations:
    - Plain text file with "tag_name commit_sha" format
    - One tag per line
    - Comments starting with # are allowed
    - File is used by workflow at lines 41-79 for tag restoration
#>
function Export-TestTagsFile {
    param(
        [string]$OutputPath,
        [string[]]$Tags
    )

    try {
        # Default output path if not provided
        if (-not $OutputPath) {
            $testStateDir = New-TestStateDirectory
            $OutputPath = Join-Path $testStateDir $TestTagsFile
        }

        Write-DebugMessage -Type "INFO" -Message "Generating test-tags.txt file"
        Write-Debug "$($Emojis.Debug) Output path: $OutputPath"

        # Only export tags that were explicitly passed
        if (-not $Tags -or $Tags.Count -eq 0) {
            Write-Debug "$($Emojis.Debug) No tags specified, will write header only"
            $Tags = @()
        }

        # Build file content (no header - direct tag entries only)
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
        
        $tagCount = $fileContent.Count
        Write-DebugMessage -Type "SUCCESS" -Message "Test-tags.txt generated with $tagCount tags"
        Write-Debug "$($Emojis.Debug) File path: $OutputPath"

        return $OutputPath
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to export test tags file: $_"
        throw $_
    }
}

# ============================================================================
# Scenario Application Functions
# ============================================================================

<#
.SYNOPSIS
    Clean existing git state.

.DESCRIPTION
    Deletes existing git tags and optionally branches to prepare for fixture application.

.PARAMETER DeleteTags
    Whether to delete all tags. Default: $true.

.PARAMETER DeleteBranches
    Whether to delete all branches (except current). Default: $false (safer).

.EXAMPLE
    Clear-GitState -DeleteTags $true

.EXAMPLE
    Clear-GitState -DeleteTags $true -DeleteBranches $true

.NOTES
    Provides warning messages about cleanup operations.
#>
function Clear-GitState {
    param(
        [bool]$DeleteTags = $true,
        [bool]$DeleteBranches = $false
    )

    try {
        if ($DeleteTags) {
            $existingTags = @(git tag -l)
            if ($existingTags.Count -gt 0) {
                Write-DebugMessage -Type "WARNING" -Message "Deleting $($existingTags.Count) existing tags"
                
                foreach ($tag in $existingTags) {
                    git tag -d $tag 2>&1 | Out-Null
                    Write-Debug "$($Emojis.Debug) Deleted tag: $tag"
                }
            }
        }

        if ($DeleteBranches) {
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            $existingBranches = @(git branch -l | Where-Object { $_ -notlike "*$currentBranch*" } )
            
            if ($existingBranches.Count -gt 0) {
                Write-DebugMessage -Type "WARNING" -Message "Deleting $($existingBranches.Count) existing branches (excluding current)"
                
                foreach ($branchLine in $existingBranches) {
                    $branch = $branchLine.Trim()
                    if ($branch.StartsWith("* ")) {
                        $branch = $branch.Substring(2).Trim()
                    }
                    
                    if ($branch -and $branch -ne $currentBranch) {
                        git branch -D $branch 2>&1 | Out-Null
                        Write-Debug "$($Emojis.Debug) Deleted branch: $branch"
                    }
                }
            }
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error during state cleanup: $_"
        throw $_
    }
}

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
        Write-DebugMessage -Type "INFO" -Message "Applying scenario: $ScenarioName"

        # Validate scenario exists
        if (-not $ScenarioDefinitions.ContainsKey($ScenarioName)) {
            $availableScenarios = $ScenarioDefinitions.Keys -join ", "
            throw "Unknown scenario: $ScenarioName. Available scenarios: $availableScenarios"
        }

        $scenario = $ScenarioDefinitions[$ScenarioName]
        Write-Debug "$($Emojis.Scenario) Scenario description: $($scenario.Description)"

        # Apply expectedState overrides if provided
        if ($ExpectedState) {
            Write-Debug "$($Emojis.Debug) Applying expectedState overrides from fixture"
            
            # Override tags if specified in expectedState
            if ($ExpectedState.tags) {
                Write-Debug "$($Emojis.Debug) Overriding tags from fixture: $($ExpectedState.tags -join ', ')"
                $scenario.Tags = @()
                foreach ($tagName in $ExpectedState.tags) {
                    $scenario.Tags += @{ Name = $tagName; CommitMessage = "Release $tagName" }
                }
            }
            
            # Override branches if specified in expectedState
            if ($ExpectedState.branches) {
                Write-Debug "$($Emojis.Debug) Overriding branches from fixture: $($ExpectedState.branches -join ', ')"
                $scenario.Branches = $ExpectedState.branches
            }
            
            # Override currentBranch if specified in expectedState
            if ($ExpectedState.currentBranch) {
                Write-Debug "$($Emojis.Debug) Overriding currentBranch from fixture: $($ExpectedState.currentBranch)"
                $scenario.CurrentBranch = $ExpectedState.currentBranch
            }
            
            Write-DebugMessage -Type "INFO" -Message "Fixture-specific state overrides applied to scenario"
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
            Write-Debug "$($Emojis.Debug) Repository appears to be empty, will create initial commit"
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
                Write-DebugMessage -Type "WARNING" -Message "Failed to create tag $($tag.Name): $_"
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
                        Write-Debug "$($Emojis.Branch) Branch already exists, skipping: $branch"
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
        if ($OutputPath) {
            $testTagsPath = Export-TestTagsFile -Tags $tagsCreated -OutputPath $OutputPath
        } else {
            $testTagsPath = Export-TestTagsFile -Tags $tagsCreated
        }

        Write-DebugMessage -Type "SUCCESS" -Message "Scenario applied successfully: $ScenarioName"

        return @{
            ScenarioName      = $ScenarioName
            TagsCreated       = $tagsCreated
            BranchesCreated   = $branchesCreated
            CurrentBranch     = $scenario.CurrentBranch
            TestTagsFile      = $testTagsPath
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to apply scenario: $_"
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
            Write-DebugMessage -Type "WARNING" -Message "Both FixturePath and Scenario provided, Scenario will be ignored"
            $Scenario = $null
        }

        Write-DebugMessage -Type "INFO" -Message "Starting test fixture application"

        $scenarioToApply = $null
        $fixtureOverrides = $null

        # Extract scenario from fixture if provided
        if ($FixturePath) {
            Write-Debug "$($Emojis.Fixture) Processing fixture file: $FixturePath"
            
            $content = Get-FixtureContent -FixturePath $FixturePath
            $scenarioToApply = Get-ScenarioFromFixture -FixtureContent $content
            
            if (-not $scenarioToApply) {
                Write-DebugMessage -Type "WARNING" -Message "No scenario found in fixture file: $FixturePath"
                Write-DebugMessage -Type "INFO" -Message "Fixture content available but scenario extraction failed"
                return $null
            }

            # Extract expected state from fixture if present
            $expectedState = Get-ExpectedStateFromFixture -FixtureContent $content
            if ($expectedState) {
                Write-Debug "$($Emojis.Debug) Found expectedState in fixture - applying overrides"
                $fixtureOverrides = $expectedState
            }
        } elseif ($Scenario) {
            $scenarioToApply = $Scenario
        }

        # Apply scenario with optional fixture overrides
        if ($fixtureOverrides) {
            Write-Debug "$($Emojis.Debug) Applying fixture-specific state overrides to scenario '$scenarioToApply'"
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
            Write-Debug "$($Emojis.Debug) Regenerating test-tags.txt at custom path (fallback)"
            $result.TestTagsFile = Export-TestTagsFile -OutputPath $OutputPath -Tags $result.TagsCreated
        }

        return $result
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to apply test fixtures: $_"
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
        Write-Host "State matches scenario"
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
        Write-DebugMessage -Type "INFO" -Message "Validating scenario state: $ScenarioName"

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
                Write-Debug "$($Emojis.Tag) Missing tag: $($tag.Name)"
            }
        }

        # Check branches
        foreach ($branch in $scenario.Branches) {
            if (-not (Test-GitBranchExists -BranchName $branch)) {
                $missingBranches += $branch
                Write-Debug "$($Emojis.Branch) Missing branch: $branch"
            }
        }

        # Check current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($currentBranch -ne $scenario.CurrentBranch) {
            $currentBranchMismatch = $true
            Write-Debug "$($Emojis.Debug) Current branch mismatch: expected '$($scenario.CurrentBranch)', got '$currentBranch'"
        }

        $isValid = ($missingTags.Count -eq 0 -and $missingBranches.Count -eq 0 -and -not $currentBranchMismatch)

        if ($isValid) {
            Write-DebugMessage -Type "SUCCESS" -Message "Git state matches scenario: $ScenarioName"
        } else {
            Write-DebugMessage -Type "WARNING" -Message "Git state does not match scenario"
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
        Write-DebugMessage -Type "ERROR" -Message "Error validating scenario state: $_"
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
            Write-DebugMessage -Type "ERROR" -Message "Unknown scenario: $ScenarioName. Available: $availableScenarios"
            return
        }

        $scenario = $ScenarioDefinitions[$ScenarioName]

        Write-Host ""
        Write-Host "==============================================================================" -ForegroundColor Cyan
        Write-Host "  Scenario: $ScenarioName" -ForegroundColor Cyan
        Write-Host "==============================================================================" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Host "Description:" -ForegroundColor Yellow
        Write-Host "  $($scenario.Description)" -ForegroundColor Gray
        Write-Host ""

        Write-Host "Tags:" -ForegroundColor Yellow
        if ($scenario.Tags.Count -eq 0) {
            Write-Host "  (none)" -ForegroundColor Gray
        } else {
            foreach ($tag in $scenario.Tags) {
                Write-Host "  $($Emojis.Tag) $($tag.Name) - $($tag.CommitMessage)" -ForegroundColor Cyan
            }
        }
        Write-Host ""

        Write-Host "Branches:" -ForegroundColor Yellow
        if ($scenario.Branches.Count -eq 0) {
            Write-Host "  (none)" -ForegroundColor Gray
        } else {
            foreach ($branch in $scenario.Branches) {
                Write-Host "  $($Emojis.Branch) $branch" -ForegroundColor Cyan
            }
        }
        Write-Host ""

        Write-Host "Current Branch:" -ForegroundColor Yellow
        Write-Host "  $($scenario.CurrentBranch)" -ForegroundColor Cyan
        Write-Host ""

        if ($scenario.Notes) {
            Write-Host "Notes:" -ForegroundColor Yellow
            Write-Host "  $($scenario.Notes)" -ForegroundColor Gray
            Write-Host ""
        }

        Write-Host "==============================================================================" -ForegroundColor Cyan
        Write-Host ""

        return $scenario
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Error displaying scenario: $_"
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
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host "  Test Fixtures Application Script" -ForegroundColor Cyan
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This script applies test fixtures to set up git state for act integration testing." -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "Available Functions:" -ForegroundColor Yellow
    Write-Host "  Apply-TestFixtures [-FixturePath | -Scenario] - Apply fixture or scenario" -ForegroundColor Cyan
    Write-Host "  Apply-Scenario [-ScenarioName]              - Apply scenario directly" -ForegroundColor Cyan
    Write-Host "  Get-FixtureScenarios                        - List scenarios from fixtures" -ForegroundColor Cyan
    Write-Host "  Show-ScenarioDefinition [-ScenarioName]     - Display scenario details" -ForegroundColor Cyan
    Write-Host "  Test-ScenarioState [-ScenarioName]          - Validate git state" -ForegroundColor Cyan
    Write-Host "  Export-TestTagsFile                         - Generate test-tags.txt" -ForegroundColor Cyan
    Write-Host "  Clear-GitState                              - Clean existing git state" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Available Scenarios:" -ForegroundColor Yellow
    foreach ($scenarioName in $ScenarioDefinitions.Keys) {
        $scenario = $ScenarioDefinitions[$scenarioName]
        Write-Host "  $($Emojis.Scenario) $scenarioName" -ForegroundColor Cyan
        Write-Host "      $($scenario.Description)" -ForegroundColor Gray
    }
    Write-Host ""
    
    Write-Host "Usage Examples:" -ForegroundColor Yellow
    Write-Host "  # Dot-source to load functions:" -ForegroundColor Gray
    Write-Host "  . .\scripts\integration\Apply-TestFixtures.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Apply fixture by file path:" -ForegroundColor Gray
    Write-Host "  Apply-TestFixtures -FixturePath 'tests/bump-version/major-bump-main.json'" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Apply scenario directly:" -ForegroundColor Gray
    Write-Host "  Apply-TestFixtures -Scenario 'MajorBumpV0ToV1'" -ForegroundColor White
    Write-Host ""
    Write-Host "  # List available scenarios:" -ForegroundColor Gray
    Write-Host "  Get-FixtureScenarios" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Validate current state:" -ForegroundColor Gray
    Write-Host "  Test-ScenarioState -ScenarioName 'MajorBumpV0ToV1'" -ForegroundColor White
    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host ""
}
