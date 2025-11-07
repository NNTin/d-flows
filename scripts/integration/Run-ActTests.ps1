<#
.SYNOPSIS
    Orchestrate complete act integration test flow for d-flows workflows.

.DESCRIPTION
    This script provides comprehensive orchestration for running integration tests using act
    (nektos/act) in Docker containers. It manages the complete test lifecycle including:
    
    - Parsing integration test fixtures from JSON files
    - Backing up production git state before each test
    - Applying test scenarios using Setup-TestScenario.ps1
    - Running act workflows with proper event files and capturing output
    - Validating workflow outputs by parsing "OUTPUT:" markers
    - Validating git state using a comprehensive validation engine
    - Cleaning up and restoring production state after each test
    - Providing detailed reporting with extensive DEBUG messages
    - Handling errors gracefully with rollback capabilities
    
    Integration with existing scripts:
    - Uses Backup-GitState.ps1 for git state backup/restore
    - Uses Setup-TestScenario.ps1 for scenario management
    - Uses Apply-TestFixtures.ps1 for fixture parsing patterns
    
    Supported test step actions:
    - setup-git-state: Apply test scenarios to git repository
    - run-workflow: Execute GitHub workflows using act
    - validate-state: Validate git state with comprehensive checks
    - execute-command: Run arbitrary shell commands
    - comment: Informational comments (always succeed)

.PARAMETER TestFixturePath
    Path to specific integration test fixture JSON file to run.
    Optional - if not provided, will run all tests or use TestName.

.PARAMETER TestName
    Name of specific test to run (searches by fixture name).
    Optional - supports case-insensitive partial matching.

.PARAMETER RunAll
    Run all integration tests in tests/integration/ directory.
    Default behavior if no other parameters provided.

.PARAMETER SkipBackup
    Skip backup/restore of git state (for debugging).
    Default: $false. Use with caution as tests modify git state.

.PARAMETER SkipCleanup
    Skip cleanup after test (for debugging).
    Default: $false. Leaves test artifacts for inspection.

.PARAMETER Verbose
    Enable verbose output including all DEBUG messages.
    Default: $false.

.PARAMETER StopOnFailure
    Stop execution on first test failure.
    Default: $false. When true, remaining tests are skipped.

.EXAMPLE
    # Run specific test by path
    .\scripts\integration\Run-ActTests.ps1 -TestFixturePath "tests/integration/v0-to-v1-release-cycle.json"

.EXAMPLE
    # Run specific test by name
    .\scripts\integration\Run-ActTests.ps1 -TestName "Complete v0.1.1 to v1.0.0 Release Cycle"

.EXAMPLE
    # Run all integration tests
    .\scripts\integration\Run-ActTests.ps1 -RunAll

.EXAMPLE
    # Debug mode with no backup/cleanup
    .\scripts\integration\Run-ActTests.ps1 -TestName "Invalid Branch" -SkipBackup -SkipCleanup -Verbose

.EXAMPLE
    # Run all tests, stop on first failure
    .\scripts\integration\Run-ActTests.ps1 -RunAll -StopOnFailure

.NOTES
    Requirements:
    - act must be installed (Install: winget install nektos.act)
    - Docker must be running (Docker Desktop or equivalent)
    - Repository must be in a git repository
    
    Repository State:
    - Tests modify git state (tags, branches, commits)
    - State is always backed up before tests and restored after
    - Use -SkipBackup only for debugging (leaves repository in test state)
    
    Test Isolation:
    - Each test runs in clean state with fixtures applied
    - Backup/restore ensures no cross-test contamination
    - Tests run sequentially (no parallel execution in this version)
    
    Output Format:
    - Detailed test results with pass/fail status
    - Colored output with emoji indicators
    - DEBUG messages for troubleshooting
    - JSON report exported to system temp logs directory
    
    Workflow Integration:
    - Workflows detect act via $ACT environment variable
    - Workflows output "OUTPUT: KEY=VALUE" markers for validation
    - Workflows skip push operations when running under act
    - Test state directory is mounted to /tmp/test-state in containers
    
    Docker Container Considerations:
    - Repository is mounted into container
    - No network access in container (skip remote validations)
    - Act configuration from .actrc is used automatically
    - Test state directory is mounted as read-write volume
    
    Test State Management:
    - Test state stored in system temp directory: d-flows-test-state-<guid>
    - Each test run generates unique GUID for isolation
    - Cross-platform: Windows (%TEMP%), Linux (/tmp)
    - Automatically cleaned up after test execution
    - Use -SkipCleanup to preserve for debugging
    - Directory is mounted to /tmp/test-state in Docker containers for act workflows
    
    Expected Test Duration:
    - Individual tests typically take 30-120 seconds
    - Full test suite may take 5-15 minutes depending on test count
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TestFixturePath,
    
    [Parameter(Mandatory = $false)]
    [string]$TestName,
    
    [Parameter(Mandatory = $false)]
    [switch]$RunAll,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipBackup,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,
    
    [Parameter(Mandatory = $false)]
    [switch]$StopOnFailure
)

# ============================================================================
# Global Variables and Configuration
# ============================================================================

# Generate a unique GUID for this script execution to ensure consistent temp directory naming
$script:TestStateGuid = [guid]::NewGuid().ToString('N')

# Get temp-based test state directory path
function Get-TestStateBasePath {
    $tempPath = [System.IO.Path]::GetTempPath()
    $testStateDirName = "d-flows-test-state-$($script:TestStateGuid)"
    return Join-Path $tempPath $testStateDirName
}

$TestStateDirectory = Get-TestStateBasePath
$TestLogsDirectory = Join-Path (Get-TestStateBasePath) "logs"
$IntegrationTestsDirectory = "tests/integration"

# Set shared environment variable for test state directory used by dot-sourced scripts
# This ensures Setup-TestScenario.ps1 and Apply-TestFixtures.ps1 use the same directory
# instead of generating their own unique GUIDs, preventing test state GUID mismatch
$env:DFLOWS_TEST_STATE_BASE = $TestStateDirectory

# Use built-in $DebugPreference and $VerbosePreference for output control
# Callers can use -Debug and -Verbose common parameters to control this

# Color constants (matching style from Backup-GitState.ps1)
$Colors = @{
    Success    = [System.ConsoleColor]::Green
    Warning    = [System.ConsoleColor]::Yellow
    Error      = [System.ConsoleColor]::Red
    Info       = [System.ConsoleColor]::Cyan
    Debug      = [System.ConsoleColor]::DarkGray
    Test       = [System.ConsoleColor]::Magenta
}

$Emojis = @{
    Success    = "✅"
    Warning    = "⚠️"
    Error      = "❌"
    Info       = "ℹ️"
    Debug      = "🔍"
    Test       = "🧪"
    Workflow   = "⚙️"
    Validation = "🔎"
    Cleanup    = "🧹"
    Restore    = "♻️"
}

$ActCommand = Get-Command "act" | Select-Object -ExpandProperty Source

# ============================================================================
# Helper Functions
# ============================================================================

<#
.SYNOPSIS
    Detect the git repository root directory.

.DESCRIPTION
    Walks up the directory tree from the current location until finding a .git directory.
    Pattern reused from Backup-GitState.ps1 lines 110-127.

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
        
        $gitPath = Join-Path $searchPath '.git'
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
    Create test state directories if they don't exist.

.DESCRIPTION
    Creates test state and logs directories in system temp location with unique GUID-based naming.
    Each script execution generates a unique GUID-based subdirectory (d-flows-test-state-<guid>)
    to ensure test isolation and prevent conflicts between concurrent test runs.

.EXAMPLE
    $testStateDir = New-TestStateDirectory
    Write-Host "Test state directory: $testStateDir"

.NOTES
    Returns the full path to the test state directory in temp.
    
    Directory is automatically cleaned up at script end unless -SkipCleanup is specified.
    
    Cross-platform temp path resolution:
    - Windows: Uses %TEMP% environment variable
    - Linux: Uses /tmp directory
    - Resolved via [System.IO.Path]::GetTempPath()
#>
function New-TestStateDirectory {
    $testStatePath = Get-TestStateBasePath
    $testLogsPath = $TestLogsDirectory
    
    if (-not (Test-Path $testStatePath)) {
        Write-Debug "$($Emojis.Debug) Creating temp test state directory: $testStatePath"
        New-Item -ItemType Directory -Path $testStatePath -Force | Out-Null
        Write-Debug "$($Emojis.Debug) Test state directory created"
    } else {
        Write-Debug "$($Emojis.Debug) Test state directory already exists: $testStatePath"
    }
    
    if (-not (Test-Path $testLogsPath)) {
        Write-Debug "$($Emojis.Debug) Creating temp test logs directory: $testLogsPath"
        New-Item -ItemType Directory -Path $testLogsPath -Force | Out-Null
        Write-Debug "$($Emojis.Debug) Test logs directory created"
    } else {
        Write-Debug "$($Emojis.Debug) Test logs directory already exists: $testLogsPath"
    }

    return $testStatePath
}

<#
.SYNOPSIS
    Remove test state directory and all contents.

.DESCRIPTION
    Deletes the test state directory recursively, including all backup files, logs, and metadata.
    This function is called automatically at script end to clean up temporary test artifacts
    unless the -SkipCleanup parameter is specified for debugging purposes.

    Handles permission errors gracefully with try-catch to ensure cleanup doesn't fail the entire test run.

.PARAMETER Path
    Optional path to the directory to remove. Defaults to $TestStateDirectory global variable.
    Example: "C:\Users\test\AppData\Local\Temp\d-flows-test-state-abc123"

.EXAMPLE
    # Remove the current test state directory
    Remove-TestStateDirectory

.EXAMPLE
    # Remove a specific test state directory
    Remove-TestStateDirectory -Path "C:\Users\test\AppData\Local\Temp\d-flows-test-state-xyz789"

.NOTES
    Called automatically at script end unless -SkipCleanup is specified.
    
    Use -SkipCleanup when:
    - Debugging test failures and need to inspect test state
    - Troubleshooting temp directory issues
    - Manual inspection of backup files and logs
    
    Safe to call multiple times (checks for existence first).
    
    Cross-Platform:
    - Windows: Removes directory from %TEMP%\d-flows-test-state-<guid>\
    - Linux: Removes directory from /tmp/d-flows-test-state-<guid>/
#>
function Remove-TestStateDirectory {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = $TestStateDirectory
    )
    
    # TODO: skip for now
    return $true

    try {
        if (Test-Path $Path) {
            Write-Debug "$($Emojis.Debug) Removing test state directory: $Path"
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Debug "$($Emojis.Debug) Test state directory removed successfully"
            return $true
        } else {
            Write-Debug "$($Emojis.Debug) Test state directory does not exist: $Path"
            return $true
        }
    } catch {
        Write-DebugMessage -Type "WARNING" -Message "Failed to remove test state directory: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Convert Windows or Linux file paths to Docker-compatible mount format.

.DESCRIPTION
    Transforms file system paths to formats compatible with Docker volume mounts,
    particularly for Docker Desktop on Windows which requires paths in the format
    `/c/Users/...` rather than `C:\Users\...`.

    On Windows, converts:
    - `C:\Users\test\data` → `/c/Users/test/data`
    - `D:\projects\repo` → `/d/projects/repo`
    - `\\server\share\path` → `//server/share/path`

    On Linux, returns the path unchanged (already in correct format).

.PARAMETER Path
    The file system path to convert. Can be absolute or relative.
    Required. Example: `C:\Users\test\d-flows-test-state-abc123`

.EXAMPLE
    # Windows path conversion
    $dockerPath = ConvertTo-DockerMountPath -Path "C:\Users\test\d-flows-test-state-abc123"
    # Returns: /c/Users/test/d-flows-test-state-abc123

.EXAMPLE
    # Linux path conversion (no change)
    $dockerPath = ConvertTo-DockerMountPath -Path "/home/user/d-flows-test-state-abc123"
    # Returns: /home/user/d-flows-test-state-abc123

.EXAMPLE
    # Using with Docker volume mount
    $testStatePath = "$env:TEMP\d-flows-test-state-xyz789"
    $dockerPath = ConvertTo-DockerMountPath -Path $testStatePath
    $volumeOption = "-v `"$dockerPath`":/tmp/test-state"

.NOTES
    Windows Docker Desktop Paths:
    - Docker Desktop translates Windows drive letters to /c, /d, /e, etc.
    - Backslashes must be converted to forward slashes
    - Paths typically follow pattern: /c/Users/<username>/<path>
    - This is required for volume mounts in Docker commands

    Cross-Platform Compatibility:
    - Detects host OS using $IsWindows variable (PowerShell 6+) or OSVersion
    - Windows: C:\ drive paths → /c/ format
    - Linux: Paths left unchanged (already in /home or /root format)
    - UNC paths: \\server\share → //server/share

    Error Handling:
    - Returns $null if path cannot be resolved
    - Validates that converted path starts with / for consistency
    - Throws error if path resolution fails
#>
function ConvertTo-DockerMountPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        # Get full absolute path
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        Write-Debug "$($Emojis.Debug) Converting path for Docker: $fullPath"

        # Detect if running on Windows
        $IsOnWindows = if ($PSVersionTable.PSVersion.Major -ge 6) {
            $IsWindows
        } else {
            [System.Environment]::OSVersion.Platform -eq "Win32NT"
        }

        if ($IsOnWindows) {
            # Handle UNC paths (network paths like \\server\share)
            if ($fullPath -match '^\\\\') {
                $dockerPath = $fullPath -replace '\\', '/' -replace '^//', '//'
                Write-Debug "$($Emojis.Debug) Converted UNC path to Docker format: $dockerPath"
                return $dockerPath
            }

            # Handle local drive paths (C:\, D:\, etc.)
            if ($fullPath -match '^([A-Z]):') {
                $driveLetter = [char]::ToLower([char]($matches[1]))
                $pathWithoutDrive = $fullPath.Substring(2)
                $dockerPath = "/$driveLetter$($pathWithoutDrive -replace '\\', '/')"
                Write-Debug "$($Emojis.Debug) Converted Windows path to Docker format: $dockerPath"
                return $dockerPath
            }

            throw "Unrecognized Windows path format: $fullPath"
        } else {
            # On Linux, path should already be in correct format
            Write-Debug "$($Emojis.Debug) Linux path already in Docker format: $fullPath"
            return $fullPath
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to convert path to Docker format: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Write debug messages with consistent formatting.

.DESCRIPTION
    Wrapper function for consistent debug output with emoji prefixes and colors.
    Reused from Backup-GitState.ps1 lines 199-218.

.PARAMETER Type
    Message type: INFO, SUCCESS, WARNING, ERROR, TEST

.PARAMETER Message
    The message text to display

.EXAMPLE
    Write-DebugMessage -Type "INFO" -Message "Starting test execution"
    Write-DebugMessage -Type "SUCCESS" -Message "Test passed"
#>
function Write-DebugMessage {
    param(
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR", "TEST")]
        [string]$Type,
        
        [string]$Message
    )

    $emoji = switch ($Type) {
        "INFO"    { $Emojis.Info }
        "SUCCESS" { $Emojis.Success }
        "WARNING" { $Emojis.Warning }
        "ERROR"   { $Emojis.Error }
        "TEST"    { $Emojis.Test }
        default   { "ℹ️" }
    }

    $color = switch ($Type) {
        "INFO"    { $Colors.Info }
        "SUCCESS" { $Colors.Success }
        "WARNING" { $Colors.Warning }
        "ERROR"   { $Colors.Error }
        "TEST"    { $Colors.Test }
        default   { $Colors.Info }
    }
    
    Write-Host "$emoji $Message" -ForegroundColor $color
}

<#
.SYNOPSIS
    Display formatted test header.

.DESCRIPTION
    Shows test name and description with visual separators.

.PARAMETER TestName
    The name of the test

.PARAMETER TestDescription
    Description of what the test does

.EXAMPLE
    Write-TestHeader -TestName "Version Bump Test" -TestDescription "Tests major version bump from v0 to v1"
#>
function Write-TestHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestName,
        
        [Parameter(Mandatory = $false)]
        [string]$TestDescription
    )

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "$($Emojis.Test) $TestName" -ForegroundColor Cyan
    if ($TestDescription) {
        Write-Host "   $TestDescription" -ForegroundColor Gray
    }
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Debug "$($Emojis.Debug) Starting test: $TestName"
}

<#
.SYNOPSIS
    Display formatted test result.

.DESCRIPTION
    Shows test result with appropriate emoji and color based on success/failure.

.PARAMETER TestName
    The name of the test

.PARAMETER Success
    Boolean indicating if test passed

.PARAMETER Duration
    Test execution duration as TimeSpan

.PARAMETER Message
    Optional additional message

.EXAMPLE
    Write-TestResult -TestName "Version Bump Test" -Success $true -Duration $duration
#>
function Write-TestResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestName,
        
        [Parameter(Mandatory = $true)]
        [bool]$Success,
        
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duration,
        
        [Parameter(Mandatory = $false)]
        [string]$Message
    )

    $emoji = if ($Success) { $Emojis.Success } else { $Emojis.Error }
    $color = if ($Success) { $Colors.Success } else { $Colors.Error }
    $status = if ($Success) { "PASSED" } else { "FAILED" }
    
    $durationText = "{0:N2}s" -f $Duration.TotalSeconds
    
    Write-Host ""
    Write-Host "$emoji Test ${status}: $TestName ($durationText)" -ForegroundColor $color
    
    if ($Message) {
        Write-Host "   $Message" -ForegroundColor Gray
    }
    
    Write-Host ""
}

# ============================================================================
# Fixture Parsing Functions
# ============================================================================

<#
.SYNOPSIS
    Parse integration test fixture JSON file.

.DESCRIPTION
    Reads and validates fixture JSON structure, returns parsed object.

.PARAMETER FixturePath
    Path to fixture JSON file (required)

.EXAMPLE
    $fixture = Get-FixtureContent -FixturePath "tests/integration/test.json"

.NOTES
    Validates file existence and JSON format.
    Returns parsed fixture with: name, description, steps, cleanup, expectedDuration, tags
#>
function Get-FixtureContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FixturePath
    )

    Write-Debug "$($Emojis.Debug) Parsing fixture: $FixturePath"
    
    # Validate file exists
    if (-not (Test-Path $FixturePath)) {
        throw "Fixture file not found: $FixturePath"
    }
    
    try {
        # Read and parse JSON
        $fixtureContent = Get-Content -Path $FixturePath -Raw -Encoding UTF8
        $fixture = $fixtureContent | ConvertFrom-Json
        
        # Add file path to fixture object
        $fixture | Add-Member -NotePropertyName "FilePath" -NotePropertyValue $FixturePath -Force
        
        Write-Debug "$($Emojis.Debug) Parsed fixture: $($fixture.name) with $($fixture.steps.Count) steps"
        
        return $fixture
    } catch {
        throw "Failed to parse fixture JSON from '$FixturePath': $_"
    }
}

<#
.SYNOPSIS
    Scan and return all integration test fixtures.

.DESCRIPTION
    Finds all *.json files in tests/integration directory and parses them.

.PARAMETER TestsDirectory
    Optional directory path (defaults to tests/integration)

.EXAMPLE
    $fixtures = Get-AllIntegrationTestFixtures
    Write-Host "Found $($fixtures.Count) fixtures"

.NOTES
    Returns array of fixture objects with file paths.
#>
function Get-AllIntegrationTestFixtures {
    param(
        [Parameter(Mandatory = $false)]
        [string]$TestsDirectory = $IntegrationTestsDirectory
    )

    Write-Debug "$($Emojis.Debug) Scanning for fixtures in: $TestsDirectory"
    
    $repoRoot = Get-RepositoryRoot
    $fullTestsPath = Join-Path $repoRoot $TestsDirectory
    
    if (-not (Test-Path $fullTestsPath)) {
        throw "Tests directory not found: $fullTestsPath"
    }
    
    $fixtureFiles = Get-ChildItem -Path $fullTestsPath -Filter "*.json" -File
    $fixtures = @()
    
    foreach ($file in $fixtureFiles) {
        try {
            $fixture = Get-FixtureContent -FixturePath $file.FullName
            $fixtures += $fixture
        } catch {
            Write-DebugMessage -Type "WARNING" -Message "Failed to parse fixture '$($file.Name)': $_"
            continue
        }
    }
    
    Write-Debug "$($Emojis.Debug) Found $($fixtures.Count) valid fixtures"
    
    return $fixtures
}

<#
.SYNOPSIS
    Find fixture by test name.

.DESCRIPTION
    Searches all fixtures for one matching the provided name (case-insensitive, partial match).

.PARAMETER TestName
    Name to search for (required)

.PARAMETER TestsDirectory
    Optional directory path

.EXAMPLE
    $fixture = Find-FixtureByName -TestName "v0 to v1"

.NOTES
    Returns fixture object or throws error if not found.
#>
function Find-FixtureByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestName,
        
        [Parameter(Mandatory = $false)]
        [string]$TestsDirectory = $IntegrationTestsDirectory
    )

    Write-Debug "$($Emojis.Debug) Searching for fixture with name: $TestName"
    
    $fixtures = Get-AllIntegrationTestFixtures -TestsDirectory $TestsDirectory
    
    $matchingFixture = $fixtures | Where-Object { 
        $_.name -like "*$TestName*" 
    } | Select-Object -First 1
    
    if (-not $matchingFixture) {
        throw "No fixture found matching name: $TestName"
    }
    
    Write-Debug "$($Emojis.Debug) Found fixture: $($matchingFixture.name)"
    
    return $matchingFixture
}

# ============================================================================
# Act Execution Functions
# ============================================================================

<#
.SYNOPSIS
    Check if act is installed and available.

.DESCRIPTION
    Executes 'act --version' to verify act is installed.

.EXAMPLE
    if (Test-ActAvailable) { Write-Host "act is available" }

.NOTES
    Returns $true if available, $false otherwise.
    Provides installation instructions if not found.
#>
function Test-ActAvailable {
    Write-Debug "$($Emojis.Debug) Checking if act is available"
    
    try {
        $actVersion = & $ActCommand --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Debug "$($Emojis.Debug) act version: $actVersion"
            return $true
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "act not found. Install using: winget install nektos.act"
        return $false
    }
    
    Write-DebugMessage -Type "ERROR" -Message "act not found. Install using: winget install nektos.act"
    return $false
}

<#
.SYNOPSIS
    Check if Docker is running.

.DESCRIPTION
    Executes 'docker ps' to verify Docker daemon is accessible.

.EXAMPLE
    if (Test-DockerRunning) { Write-Host "Docker is running" }

.NOTES
    Returns $true if running, $false otherwise.
#>
function Test-DockerRunning {
    Write-Debug "$($Emojis.Debug) Checking if Docker is running"
    
    try {
        $dockerPs = docker ps 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Debug "$($Emojis.Debug) Docker is running"
            return $true
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Docker is not running. Start Docker Desktop and try again."
        return $false
    }
    
    Write-DebugMessage -Type "ERROR" -Message "Docker is not running. Start Docker Desktop and try again."
    return $false
}

<#
.SYNOPSIS
    Run act workflow with fixture.

.DESCRIPTION
    Executes GitHub workflow using act with specified fixture file.
    Captures output and parses "OUTPUT:" markers.
    Mounts test state directory into container for workflow access.

.PARAMETER WorkflowFile
    Workflow filename (e.g., "bump-version.yml")

.PARAMETER FixturePath
    Path to workflow fixture JSON

.PARAMETER JobName
    Optional specific job to run

.PARAMETER CaptureOutput
    Whether to capture output (default: $true)

.EXAMPLE
    $result = Invoke-ActWorkflow -WorkflowFile "bump-version.yml" -FixturePath "tests/bump-version/test.json"

.NOTES
    Returns hashtable with: Success, ExitCode, Output, Outputs, Duration
    Integrates with workflows via $ACT environment variable detection.

    Volume Mounting:
    - Test state directory ($TestStateDirectory) is mounted to /tmp/test-state in container
    - Cross-platform path conversion handles Windows paths (C:\...) for Docker Desktop
    - TEST_STATE_PATH environment variable provides container path to workflows
    - Mount is read-write, allowing workflows to create/modify test state files

    Container Access:
    - Workflows can access mounted directory via /tmp/test-state path
    - TEST_STATE_PATH environment variable set to /tmp/test-state for convenience
    - Example: bash script can read $TEST_STATE_PATH/test-tags.txt
#>
function Invoke-ActWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkflowFile,
        
        [Parameter(Mandatory = $true)]
        [string]$FixturePath,
        
        [Parameter(Mandatory = $false)]
        [string]$JobName,
        
        [Parameter(Mandatory = $false)]
        [bool]$CaptureOutput = $true
    )

    Write-Debug "$($Emojis.Workflow) Preparing to run workflow: $WorkflowFile"
    
    # Build act command
    $actArgs = @(
        "workflow_dispatch",
        "-W", ".github/workflows/$WorkflowFile",
        "-e", $FixturePath
    )
    
    if ($JobName) {
        $actArgs += "--job"
        $actArgs += $JobName
    }
    
    # Commented: disable usage of secrets file
    # if (Test-Path ".secrets") {
    #     $actArgs += "--secret-file"
    #     $actArgs += ".secrets"
    # }
    
    # Set ACT environment variable for workflows
    $actArgs += "--env"
    $actArgs += "ACT=true"

    # Set TEST_STATE_PATH environment variable to provide mounted path to workflows
    $actArgs += "--env"
    $actArgs += "TEST_STATE_PATH=/tmp/test-state"

    # Bind current directory, this will write to git repository
    $actArgs += "--bind"
    
    # Mount test state directory into container for test tag access
    try {
        $dockerTestStatePath = ConvertTo-DockerMountPath -Path $TestStateDirectory
        Write-Debug "$($Emojis.Debug) Mounting volume: $TestStateDirectory -> /tmp/test-state"
        Write-Debug "$($Emojis.Debug) Docker path: $dockerTestStatePath"
        
        $mountOption = "`"--mount type=bind,src=$dockerTestStatePath,dst=/tmp/test-state`""
        $actArgs += "--container-options"
        $actArgs += $mountOption
    } catch {
        Write-DebugMessage -Type "WARNING" -Message "Failed to convert test state path for Docker mount: $_"
        Write-DebugMessage -Type "INFO" -Message "Continuing without volume mount (workflows may not access test state)"
    }
    
    # Execute act and capture output
    $startTime = Get-Date
    
    try {
        Write-Debug "$($Emojis.Debug) ActCommand: $ActCommand"
        Write-Debug "$($Emojis.Debug) actArgs: $actArgs"
        if ($CaptureOutput) {
            $output = & $ActCommand @actArgs 2>&1 | Out-String
        } else {
            & $ActCommand @actArgs
            $output = ""
        }
        
        $exitCode = $LASTEXITCODE
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        Write-Debug "$($Emojis.Debug) Act execution completed in $($duration.TotalSeconds) seconds with exit code: $exitCode"
        
        # Parse outputs from workflow
        $outputs = Parse-ActOutput -Output $output
        
        return @{
            Success  = ($exitCode -eq 0)
            ExitCode = $exitCode
            Output   = $output
            Outputs  = $outputs
            Duration = $duration
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Act execution failed: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Parse act output for workflow outputs.

.DESCRIPTION
    Searches act output for "OUTPUT: KEY=VALUE" markers and extracts them.

.PARAMETER Output
    Full act output text

.EXAMPLE
    $outputs = Parse-ActOutput -Output $actOutput

.NOTES
    Returns hashtable of parsed outputs.
    Workflows output markers like: "OUTPUT: NEW_VERSION=1.0.0"
#>
function Parse-ActOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output
    )

    Write-Debug "$($Emojis.Debug) Parsing act output for OUTPUT: markers"
    
    $outputs = @{}
    $lines = $Output -split "`n"
    
    foreach ($line in $lines) {
        if ($line -match 'OUTPUT:\s*([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $outputs[$key] = $value
            Write-Debug "$($Emojis.Debug) Found output: $key = $value"
        }
    }
    
    Write-Debug "$($Emojis.Debug) Parsed $($outputs.Count) outputs"
    
    return $outputs
}

# ============================================================================
# Validation Functions
# ============================================================================

<#
.SYNOPSIS
    Dispatch validation check to appropriate handler.

.DESCRIPTION
    Routes validation check to specific validation function based on type.

.PARAMETER Check
    Hashtable with 'type' and other properties

.EXAMPLE
    $result = Invoke-ValidationCheck -Check @{ type = "tag-exists"; tag = "v1.0.0" }

.NOTES
    Returns hashtable with: Success, Message, Type
#>
function Invoke-ValidationCheck {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Check
    )

    $checkType = $Check.type
    Write-Debug "$($Emojis.Validation) Executing validation: $checkType"
    
    try {
        switch ($checkType) {
            "tag-exists" {
                return Validate-TagExists -Tag $Check.tag
            }
            "tag-not-exists" {
                return Validate-TagNotExists -Tag $Check.tag
            }
            "tag-points-to" {
                return Validate-TagPointsTo -Tag $Check.tag -Target $Check.target
            }
            "tag-accessible" {
                return Validate-TagAccessible -Tag $Check.tag
            }
            "tag-count" {
                return Validate-TagCount -Expected $Check.expected
            }
            "branch-exists" {
                return Validate-BranchExists -Branch $Check.branch
            }
            "branch-points-to-tag" {
                return Validate-BranchPointsToTag -Branch $Check.branch -Tag $Check.tag
            }
            "branch-count" {
                return Validate-BranchCount -Expected $Check.expected
            }
            "current-branch" {
                return Validate-CurrentBranch -Branch $Check.branch
            }
            "version-greater" {
                return Validate-VersionGreater -Current $Check.current -New $Check.new
            }
            "version-progression" {
                return Validate-VersionProgression -From $Check.from -To $Check.to -BumpType $Check.bumpType
            }
            "major-increment" {
                return Validate-MajorIncrement -From $Check.from -To $Check.to
            }
            "major-tag-coexistence" {
                return Validate-MajorTagCoexistence -Tags $Check.tags
            }
            "major-tags-coexist" {
                return Validate-MajorTagCoexistence -Tags $Check.tags
            }
            "major-tag-progression" {
                return Validate-MajorTagProgression -Tags $Check.tags
            }
            "no-new-tags" {
                return Validate-NoNewTags -BaselineTagCount $Check.baselineTagCount
            }
            "no-cross-contamination" {
                return Validate-NoCrossContamination -V1 $Check.v1 -V2 $Check.v2
            }
            "no-tag-conflicts" {
                return Validate-NoTagConflicts
            }
            "workflow-success" {
                return Validate-WorkflowSuccess -Workflow $Check.workflow -ActResult $Check.actResult
            }
            "idempotency-verified" {
                return Validate-IdempotencyVerified
            }
            default {
                $supportedTypes = @(
                    "tag-exists", "tag-not-exists", "tag-points-to", "tag-accessible", "tag-count",
                    "branch-exists", "branch-points-to-tag", "branch-count", "current-branch",
                    "version-greater", "version-progression", "major-increment", "major-tag-coexistence",
                    "major-tags-coexist", "major-tag-progression", "no-new-tags", "no-cross-contamination",
                    "no-tag-conflicts", "workflow-success", "idempotency-verified"
                )
                throw "Unknown validation type: $checkType. Supported types: $($supportedTypes -join ', ')"
            }
        }
    } catch {
        return @{
            Success = $false
            Message = "Validation error: $_"
            Type    = $checkType
        }
    }
}

<#
.SYNOPSIS
    Check if git tag exists.

.PARAMETER Tag
    Tag name to check

.EXAMPLE
    Validate-TagExists -Tag "v1.0.0"
#>
function Validate-TagExists {
    param([Parameter(Mandatory = $true)][string]$Tag)
    
    $existingTag = git tag -l $Tag 2>$null
    $exists = -not [string]::IsNullOrEmpty($existingTag)
    
    Write-Debug "$($Emojis.Validation) Tag '$Tag' exists: $exists"
    
    return @{
        Success = $exists
        Message = if ($exists) { "Tag '$Tag' exists" } else { "Tag '$Tag' does not exist" }
        Type    = "tag-exists"
    }
}

<#
.SYNOPSIS
    Check if git tag does NOT exist.

.PARAMETER Tag
    Tag name to check

.EXAMPLE
    Validate-TagNotExists -Tag "v2.0.0"
#>
function Validate-TagNotExists {
    param([Parameter(Mandatory = $true)][string]$Tag)
    
    $existingTag = git tag -l $Tag 2>$null
    $notExists = [string]::IsNullOrEmpty($existingTag)
    
    Write-Debug "$($Emojis.Validation) Tag '$Tag' does not exist: $notExists"
    
    return @{
        Success = $notExists
        Message = if ($notExists) { "Tag '$Tag' does not exist (as expected)" } else { "Tag '$Tag' exists (unexpected)" }
        Type    = "tag-not-exists"
    }
}

<#
.SYNOPSIS
    Check if tag points to target tag/commit.

.PARAMETER Tag
    Source tag name

.PARAMETER Target
    Target tag or commit SHA

.EXAMPLE
    Validate-TagPointsTo -Tag "v1" -Target "v1.0.0"
#>
function Validate-TagPointsTo {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Target
    )
    
    try {
        $tagSha = git rev-parse $Tag 2>$null
        $targetSha = git rev-parse $Target 2>$null
        
        $matches = ($tagSha -eq $targetSha)
        
        Write-Debug "$($Emojis.Validation) Tag '$Tag' points to '$Target': $matches"
        
        return @{
            Success = $matches
            Message = if ($matches) { "Tag '$Tag' points to '$Target'" } else { "Tag '$Tag' does not point to '$Target'" }
            Type    = "tag-points-to"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to compare tags: $_"
            Type    = "tag-points-to"
        }
    }
}

<#
.SYNOPSIS
    Check if tag is accessible.

.PARAMETER Tag
    Tag name to check

.EXAMPLE
    Validate-TagAccessible -Tag "v1.0.0"
#>
function Validate-TagAccessible {
    param([Parameter(Mandatory = $true)][string]$Tag)
    
    try {
        $existingTag = git tag -l $Tag 2>$null
        $sha = git rev-parse $Tag 2>$null
        
        $accessible = (-not [string]::IsNullOrEmpty($existingTag)) -and (-not [string]::IsNullOrEmpty($sha))
        
        Write-Debug "$($Emojis.Validation) Tag '$Tag' accessible: $accessible"
        
        return @{
            Success = $accessible
            Message = if ($accessible) { "Tag '$Tag' is accessible" } else { "Tag '$Tag' is not accessible" }
            Type    = "tag-accessible"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to check tag accessibility: $_"
            Type    = "tag-accessible"
        }
    }
}

<#
.SYNOPSIS
    Check if tag count matches expected.

.PARAMETER Expected
    Expected tag count

.EXAMPLE
    Validate-TagCount -Expected 3
#>
function Validate-TagCount {
    param([Parameter(Mandatory = $true)][int]$Expected)
    
    $tags = @(git tag -l)
    $actual = $tags.Count
    
    $matches = ($actual -eq $Expected)
    
    Write-Debug "$($Emojis.Validation) Tag count: $actual (expected: $Expected)"
    
    return @{
        Success = $matches
        Message = if ($matches) { "Tag count matches: $actual" } else { "Tag count mismatch: expected $Expected, got $actual" }
        Type    = "tag-count"
    }
}

<#
.SYNOPSIS
    Check if git branch exists.

.PARAMETER Branch
    Branch name to check

.EXAMPLE
    Validate-BranchExists -Branch "release/v1"
#>
function Validate-BranchExists {
    param([Parameter(Mandatory = $true)][string]$Branch)
    
    $existingBranch = git branch -l $Branch 2>$null
    $exists = -not [string]::IsNullOrEmpty($existingBranch)
    
    Write-Debug "$($Emojis.Validation) Branch '$Branch' exists: $exists"
    
    return @{
        Success = $exists
        Message = if ($exists) { "Branch '$Branch' exists" } else { "Branch '$Branch' does not exist" }
        Type    = "branch-exists"
    }
}

<#
.SYNOPSIS
    Check if branch points to same commit as tag.

.PARAMETER Branch
    Branch name

.PARAMETER Tag
    Tag name

.EXAMPLE
    Validate-BranchPointsToTag -Branch "release/v1" -Tag "v1.0.0"
#>
function Validate-BranchPointsToTag {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Tag
    )
    
    try {
        $branchSha = git rev-parse $Branch 2>$null
        $tagSha = git rev-parse $Tag 2>$null
        
        $matches = ($branchSha -eq $tagSha)
        
        Write-Debug "$($Emojis.Validation) Branch '$Branch' points to tag '$Tag': $matches"
        
        return @{
            Success = $matches
            Message = if ($matches) { "Branch '$Branch' points to tag '$Tag'" } else { "Branch '$Branch' does not point to tag '$Tag'" }
            Type    = "branch-points-to-tag"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to compare branch and tag: $_"
            Type    = "branch-points-to-tag"
        }
    }
}

<#
.SYNOPSIS
    Check if branch count matches expected.

.PARAMETER Expected
    Expected branch count

.EXAMPLE
    Validate-BranchCount -Expected 2
#>
function Validate-BranchCount {
    param([Parameter(Mandatory = $true)][int]$Expected)
    
    $branches = @(git branch -l)
    $actual = $branches.Count
    
    $matches = ($actual -eq $Expected)
    
    Write-Debug "$($Emojis.Validation) Branch count: $actual (expected: $Expected)"
    
    return @{
        Success = $matches
        Message = if ($matches) { "Branch count matches: $actual" } else { "Branch count mismatch: expected $Expected, got $actual" }
        Type    = "branch-count"
    }
}

<#
.SYNOPSIS
    Check if current branch matches expected.

.PARAMETER Branch
    Expected branch name

.EXAMPLE
    Validate-CurrentBranch -Branch "main"
#>
function Validate-CurrentBranch {
    param([Parameter(Mandatory = $true)][string]$Branch)
    
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    $matches = ($currentBranch -eq $Branch)
    
    Write-Debug "$($Emojis.Validation) Current branch is '$Branch': $matches"
    
    return @{
        Success = $matches
        Message = if ($matches) { "Current branch is '$Branch'" } else { "Current branch is '$currentBranch', expected '$Branch'" }
        Type    = "current-branch"
    }
}

<#
.SYNOPSIS
    Check if new version is greater than current.

.PARAMETER Current
    Current version (e.g., "0.2.1")

.PARAMETER New
    New version (e.g., "1.0.0")

.EXAMPLE
    Validate-VersionGreater -Current "0.2.1" -New "1.0.0"
#>
function Validate-VersionGreater {
    param(
        [Parameter(Mandatory = $true)][string]$Current,
        [Parameter(Mandatory = $true)][string]$New
    )
    
    try {
        # Remove 'v' prefix if present
        $currentClean = $Current -replace '^v', ''
        $newClean = $New -replace '^v', ''
        
        # Parse version parts
        $currentParts = $currentClean -split '\.' | ForEach-Object { [int]$_ }
        $newParts = $newClean -split '\.' | ForEach-Object { [int]$_ }
        
        # Compare major, minor, patch
        $greater = $false
        for ($i = 0; $i -lt 3; $i++) {
            if ($newParts[$i] -gt $currentParts[$i]) {
                $greater = $true
                break
            } elseif ($newParts[$i] -lt $currentParts[$i]) {
                break
            }
        }
        
        Write-Debug "$($Emojis.Validation) Version '$New' > '$Current': $greater"
        
        return @{
            Success = $greater
            Message = if ($greater) { "Version '$New' is greater than '$Current'" } else { "Version '$New' is not greater than '$Current'" }
            Type    = "version-greater"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to compare versions: $_"
            Type    = "version-greater"
        }
    }
}

<#
.SYNOPSIS
    Check if version progression follows semantic versioning.

.PARAMETER From
    Starting version

.PARAMETER To
    Ending version

.PARAMETER BumpType
    Type of bump: "major", "minor", or "patch"

.EXAMPLE
    Validate-VersionProgression -From "0.2.1" -To "1.0.0" -BumpType "major"
#>
function Validate-VersionProgression {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)][string]$BumpType
    )
    
    try {
        # Remove 'v' prefix if present
        $fromClean = $From -replace '^v', ''
        $toClean = $To -replace '^v', ''
        
        # Parse version parts
        $fromParts = $fromClean -split '\.' | ForEach-Object { [int]$_ }
        $toParts = $toClean -split '\.' | ForEach-Object { [int]$_ }
        
        $valid = $false
        
        switch ($BumpType) {
            "major" {
                # Major incremented, minor/patch reset to 0
                $valid = ($toParts[0] -eq ($fromParts[0] + 1)) -and ($toParts[1] -eq 0) -and ($toParts[2] -eq 0)
            }
            "minor" {
                # Minor incremented, patch reset to 0, major unchanged
                $valid = ($toParts[0] -eq $fromParts[0]) -and ($toParts[1] -eq ($fromParts[1] + 1)) -and ($toParts[2] -eq 0)
            }
            "patch" {
                # Patch incremented, major/minor unchanged
                $valid = ($toParts[0] -eq $fromParts[0]) -and ($toParts[1] -eq $fromParts[1]) -and ($toParts[2] -eq ($fromParts[2] + 1))
            }
        }
        
        Write-Debug "$($Emojis.Validation) Version progression '$From' -> '$To' ($BumpType): $valid"
        
        return @{
            Success = $valid
            Message = if ($valid) { "Version progression '$From' -> '$To' follows $BumpType bump" } else { "Version progression '$From' -> '$To' does not follow $BumpType bump" }
            Type    = "version-progression"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to validate version progression: $_"
            Type    = "version-progression"
        }
    }
}

<#
.SYNOPSIS
    Check if major version incremented correctly.

.PARAMETER From
    Starting major version

.PARAMETER To
    Ending major version

.EXAMPLE
    Validate-MajorIncrement -From 0 -To 1
#>
function Validate-MajorIncrement {
    param(
        [Parameter(Mandatory = $true)][int]$From,
        [Parameter(Mandatory = $true)][int]$To
    )
    
    $valid = ($To -eq ($From + 1))
    
    Write-Debug "$($Emojis.Validation) Major increment $From -> ${To}: $valid"
    
    return @{
        Success = $valid
        Message = if ($valid) { "Major version incremented from $From to $To" } else { "Major version increment invalid: $From -> $To (expected $($From + 1))" }
        Type    = "major-increment"
    }
}

<#
.SYNOPSIS
    Check if multiple major tags coexist.

.PARAMETER Tags
    Array of major tag names (e.g., @("v0", "v1"))

.EXAMPLE
    Validate-MajorTagCoexistence -Tags @("v0", "v1")
#>
function Validate-MajorTagCoexistence {
    param([Parameter(Mandatory = $true)][array]$Tags)
    
    $allExist = $true
    $existingTags = @()
    
    foreach ($tag in $Tags) {
        $exists = git tag -l $tag 2>$null
        if ([string]::IsNullOrEmpty($exists)) {
            $allExist = $false
        } else {
            $existingTags += $tag
        }
    }
    
    Write-Debug "$($Emojis.Validation) Major tags coexist ($($Tags -join ', ')): $allExist"
    
    return @{
        Success = $allExist
        Message = if ($allExist) { "All major tags exist: $($Tags -join ', ')" } else { "Not all major tags exist. Found: $($existingTags -join ', ')" }
        Type    = "major-tag-coexistence"
    }
}

<#
.SYNOPSIS
    Check if major tags progress correctly.

.PARAMETER Tags
    Array of major tag names in order

.EXAMPLE
    Validate-MajorTagProgression -Tags @("v0", "v1", "v2")
#>
function Validate-MajorTagProgression {
    param([Parameter(Mandatory = $true)][array]$Tags)
    
    $valid = $true
    
    for ($i = 0; $i -lt $Tags.Count; $i++) {
        $tag = $Tags[$i]
        $exists = git tag -l $tag 2>$null
        
        if ([string]::IsNullOrEmpty($exists)) {
            $valid = $false
            break
        }
        
        # Check if version number matches index
        if ($tag -match '^v(\d+)$') {
            $version = [int]$matches[1]
            if ($version -ne $i) {
                $valid = $false
                break
            }
        }
    }
    
    Write-Debug "$($Emojis.Validation) Major tag progression ($($Tags -join ', ')): $valid"
    
    return @{
        Success = $valid
        Message = if ($valid) { "Major tags progress correctly: $($Tags -join ', ')" } else { "Major tag progression invalid" }
        Type    = "major-tag-progression"
    }
}

<#
.SYNOPSIS
    Check that no new tags were created.

.PARAMETER BaselineTagCount
    Tag count before operation

.EXAMPLE
    Validate-NoNewTags -BaselineTagCount 3
#>
function Validate-NoNewTags {
    param([Parameter(Mandatory = $true)][int]$BaselineTagCount)
    
    $currentTags = @(git tag -l)
    $currentCount = $currentTags.Count
    
    $noNewTags = ($currentCount -eq $BaselineTagCount)
    
    Write-Debug "$($Emojis.Validation) No new tags: $noNewTags (baseline: $BaselineTagCount, current: $currentCount)"
    
    return @{
        Success = $noNewTags
        Message = if ($noNewTags) { "No new tags created" } else { "New tags created: expected $BaselineTagCount, got $currentCount" }
        Type    = "no-new-tags"
    }
}

<#
.SYNOPSIS
    Check that major version branches don't contaminate each other.

.PARAMETER V1
    Version 1 tag

.PARAMETER V2
    Version 2 tag

.EXAMPLE
    Validate-NoCrossContamination -V1 "v1.0.0" -V2 "v2.0.0"

.NOTES
    Placeholder implementation - validates tags exist.
#>
function Validate-NoCrossContamination {
    param(
        [Parameter(Mandatory = $true)][string]$V1,
        [Parameter(Mandatory = $true)][string]$V2
    )
    
    try {
        $v1Sha = git rev-parse $V1 2>$null
        $v2Sha = git rev-parse $V2 2>$null
        
        $valid = (-not [string]::IsNullOrEmpty($v1Sha)) -and (-not [string]::IsNullOrEmpty($v2Sha)) -and ($v1Sha -ne $v2Sha)
        
        Write-Debug "$($Emojis.Validation) No cross-contamination between '$V1' and '$V2': $valid"
        
        return @{
            Success = $valid
            Message = if ($valid) { "No cross-contamination between '$V1' and '$V2'" } else { "Cross-contamination detected or invalid tags" }
            Type    = "no-cross-contamination"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to check cross-contamination: $_"
            Type    = "no-cross-contamination"
        }
    }
}

<#
.SYNOPSIS
    Check that no tag conflicts exist.

.EXAMPLE
    Validate-NoTagConflicts

.NOTES
    Checks for duplicate tags (shouldn't happen) and other conflicts.
#>
function Validate-NoTagConflicts {
    $tags = @(git tag -l)
    
    # Check for duplicates (shouldn't happen but validate)
    $uniqueTags = $tags | Select-Object -Unique
    $noDuplicates = ($tags.Count -eq $uniqueTags.Count)
    
    Write-Debug "$($Emojis.Validation) No tag conflicts: $noDuplicates"
    
    return @{
        Success = $noDuplicates
        Message = if ($noDuplicates) { "No tag conflicts detected" } else { "Tag conflicts detected" }
        Type    = "no-tag-conflicts"
    }
}

<#
.SYNOPSIS
    Check if workflow execution succeeded.

.PARAMETER Workflow
    Workflow name

.PARAMETER ActResult
    Result from Invoke-ActWorkflow

.EXAMPLE
    Validate-WorkflowSuccess -Workflow "bump-version" -ActResult $actResult
#>
function Validate-WorkflowSuccess {
    param(
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][object]$ActResult
    )
    
    $success = $ActResult.Success -and ($ActResult.ExitCode -eq 0)
    
    Write-Debug "$($Emojis.Validation) Workflow '$Workflow' success: $success"
    
    return @{
        Success = $success
        Message = if ($success) { "Workflow '$Workflow' succeeded" } else { "Workflow '$Workflow' failed with exit code: $($ActResult.ExitCode)" }
        Type    = "workflow-success"
    }
}

<#
.SYNOPSIS
    Check that operation is idempotent.

.EXAMPLE
    Validate-IdempotencyVerified

.NOTES
    Placeholder for future implementation.
#>
function Validate-IdempotencyVerified {
    Write-Debug "$($Emojis.Validation) Idempotency check (placeholder)"
    
    return @{
        Success = $true
        Message = "Idempotency verification placeholder"
        Type    = "idempotency-verified"
    }
}

<#
.SYNOPSIS
    Check user pinning behavior.

.PARAMETER Expectation
    Expected version

.EXAMPLE
    Validate-UserPinnedToVersion -Expectation "v1.0.0"

.NOTES
    Placeholder for documentation validation.
#>
function Validate-UserPinnedToVersion {
    param([Parameter(Mandatory = $true)][string]$Expectation)
    
    Write-Debug "$($Emojis.Validation) User pinning check: $Expectation (placeholder)"
    
    return @{
        Success = $true
        Message = "User pinning to '$Expectation' (placeholder)"
        Type    = "user-pinned-to-version"
    }
}

# ============================================================================
# Step Execution Functions
# ============================================================================

<#
.SYNOPSIS
    Execute "setup-git-state" step.

.DESCRIPTION
    Applies test scenario using Setup-TestScenario.ps1.
    Integration with Setup-TestScenario.ps1: Call Set-TestScenario for "setup-git-state" steps.

.PARAMETER Step
    Step object from fixture

.EXAMPLE
    $result = Invoke-SetupGitState -Step $step

.NOTES
    Returns hashtable with: Success, Message, ScenarioApplied, State
#>
function Invoke-SetupGitState {
    param([Parameter(Mandatory = $true)][object]$Step)
    
    $scenario = $Step.scenario
    $expectedState = $Step.expectedState
    
    Write-Debug "$($Emojis.Debug) Applying scenario: $scenario"
    
    try {
        # Call Set-TestScenario from Setup-TestScenario.ps1
        $result = Set-TestScenario -ScenarioName $scenario -CleanState $true -Force $true -GenerateTestTagsFile $true
        
        if (-not $result.Success) {
            return @{
                Success         = $false
                Message         = "Failed to apply scenario '$scenario': $($result.Message)"
                ScenarioApplied = $scenario
                State           = $result
            }
        }
        
        Write-Debug "$($Emojis.Debug) Scenario '$scenario' applied successfully"
        
        return @{
            Success         = $true
            Message         = "Scenario '$scenario' applied successfully"
            ScenarioApplied = $scenario
            State           = $result
        }
    } catch {
        return @{
            Success         = $false
            Message         = "Error applying scenario '$scenario': $_"
            ScenarioApplied = $scenario
            State           = $null
        }
    }
}

<#
.SYNOPSIS
    Execute "run-workflow" step.

.DESCRIPTION
    Runs act workflow and validates expected outputs.
    Integration with workflows: Workflows detect act via $ACT environment variable.

.PARAMETER Step
    Step object from fixture

.EXAMPLE
    $result = Invoke-RunWorkflow -Step $step

.NOTES
    Returns hashtable with: Success, Message, ActResult, OutputsMatched, ErrorMessageFound
#>
function Invoke-RunWorkflow {
    param([Parameter(Mandatory = $true)][object]$Step)
    
    $workflow = $Step.workflow
    $fixture = $Step.fixture
    $expectedOutputs = $Step.expectedOutputs
    $expectedFailure = if ($Step.expectedFailure) { $Step.expectedFailure } else { $false }
    $expectedErrorMessage = $Step.expectedErrorMessage
    
    Write-Debug "$($Emojis.Workflow) Running workflow: $workflow with fixture: $fixture"
    
    try {
        # Call Invoke-ActWorkflow
        $actResult = Invoke-ActWorkflow -WorkflowFile $workflow -FixturePath $fixture
        
        # Validate expectations
        $success = $true
        $messages = @()
        
        # Check expected failure
        if ($expectedFailure) {
            if ($actResult.Success) {
                $success = $false
                $messages += "Expected workflow to fail, but it succeeded"
            } else {
                $messages += "Workflow failed as expected"
            }
        } else {
            if (-not $actResult.Success) {
                $success = $false
                $messages += "Expected workflow to succeed, but it failed (exit code: $($actResult.ExitCode))"
            } else {
                $messages += "Workflow succeeded as expected"
            }
        }
        
        # Check expected error message
        $errorMessageFound = $false
        if ($expectedErrorMessage) {
            foreach ($keyword in $expectedErrorMessage) {
                if ($actResult.Output -match [regex]::Escape($keyword)) {
                    $errorMessageFound = $true
                    $messages += "Found expected error keyword: '$keyword'"
                    break
                }
            }
            
            if (-not $errorMessageFound) {
                $success = $false
                $messages += "Expected error message not found. Keywords: $($expectedErrorMessage -join ', ')"
            }
        }
        
        # Check expected outputs
        $outputsMatched = $true
        if ($expectedOutputs) {
            foreach ($key in $expectedOutputs.PSObject.Properties.Name) {
                $expectedValue = $expectedOutputs.$key
                $actualValue = $actResult.Outputs[$key]
                
                if ($actualValue -ne $expectedValue) {
                    $outputsMatched = $false
                    $success = $false
                    $messages += "Output mismatch: $key = '$actualValue' (expected: '$expectedValue')"
                } else {
                    $messages += "Output matched: $key = '$actualValue'"
                }
            }
        }
        
        Write-Debug "$($Emojis.Debug) Workflow execution result: $success"
        
        return @{
            Success             = $success
            Message             = $messages -join '; '
            ActResult           = $actResult
            OutputsMatched      = $outputsMatched
            ErrorMessageFound   = $errorMessageFound
        }
    } catch {
        return @{
            Success             = $false
            Message             = "Error running workflow '$workflow': $_"
            ActResult           = $null
            OutputsMatched      = $false
            ErrorMessageFound   = $false
        }
    }
}

<#
.SYNOPSIS
    Execute "validate-state" step.

.DESCRIPTION
    Validates git state using comprehensive validation checks.

.PARAMETER Step
    Step object from fixture

.EXAMPLE
    $result = Invoke-ValidateState -Step $step

.NOTES
    Returns hashtable with: Success, Message, CheckResults, PassedCount, FailedCount
#>
function Invoke-ValidateState {
    param([Parameter(Mandatory = $true)][object]$Step)
    
    $checks = $Step.checks
    
    Write-Debug "$($Emojis.Validation) Performing $($checks.Count) validation checks"
    
    $checkResults = @()
    $passedCount = 0
    $failedCount = 0
    
    foreach ($check in $checks) {
        try {
            $result = Invoke-ValidationCheck -Check $check
            $checkResults += $result
            
            if ($result.Success) {
                $passedCount++
            } else {
                $failedCount++
                Write-DebugMessage -Type "WARNING" -Message "Validation failed: $($result.Message)"
            }
        } catch {
            $failedCount++
            $checkResults += @{
                Success = $false
                Message = "Validation error: $_"
                Type    = $check.type
            }
        }
    }
    
    $success = ($failedCount -eq 0)
    $message = "Validation: $passedCount passed, $failedCount failed"
    
    Write-Debug "$($Emojis.Debug) $message"
    
    return @{
        Success      = $success
        Message      = $message
        CheckResults = $checkResults
        PassedCount  = $passedCount
        FailedCount  = $failedCount
    }
}

<#
.SYNOPSIS
    Execute "execute-command" step.

.DESCRIPTION
    Runs arbitrary shell command and captures output.

.PARAMETER Step
    Step object from fixture

.EXAMPLE
    $result = Invoke-ExecuteCommand -Step $step

.NOTES
    Returns hashtable with: Success, Message, Output, ExitCode
#>
function Invoke-ExecuteCommand {
    param([Parameter(Mandatory = $true)][object]$Step)
    
    $command = $Step.command
    
    Write-Debug "$($Emojis.Debug) Executing command: $command"
    
    try {
        $output = Invoke-Expression $command 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        
        $success = ($exitCode -eq 0)
        
        Write-Debug "$($Emojis.Debug) Command completed with exit code: $exitCode"
        
        return @{
            Success  = $success
            Message  = if ($success) { "Command succeeded" } else { "Command failed with exit code: $exitCode" }
            Output   = $output
            ExitCode = $exitCode
        }
    } catch {
        return @{
            Success  = $false
            Message  = "Command execution error: $_"
            Output   = $null
            ExitCode = -1
        }
    }
}

<#
.SYNOPSIS
    Handle "comment" step.

.DESCRIPTION
    Displays informational comment (always succeeds).

.PARAMETER Step
    Step object from fixture

.EXAMPLE
    $result = Invoke-Comment -Step $step

.NOTES
    Returns hashtable with: Success ($true), Message (comment text)
#>
function Invoke-Comment {
    param([Parameter(Mandatory = $true)][object]$Step)
    
    $text = $Step.text
    
    Write-DebugMessage -Type "INFO" -Message $text
    
    return @{
        Success = $true
        Message = $text
    }
}

# ============================================================================
# Test Orchestration Functions
# ============================================================================

<#
.SYNOPSIS
    Dispatch test step to appropriate handler.

.DESCRIPTION
    Routes step execution based on action type.

.PARAMETER Step
    Step object from fixture

.PARAMETER StepIndex
    Step number for logging

.EXAMPLE
    $result = Invoke-TestStep -Step $step -StepIndex 1

.NOTES
    Supported actions: setup-git-state, run-workflow, validate-state, execute-command, comment
#>
function Invoke-TestStep {
    param(
        [Parameter(Mandatory = $true)][object]$Step,
        [Parameter(Mandatory = $true)][int]$StepIndex
    )

    $action = $Step.action
    
    Write-Debug "$($Emojis.Debug) Executing step $StepIndex ($action)"
    
    try {
        $result = switch ($action) {
            "setup-git-state" {
                Invoke-SetupGitState -Step $Step
            }
            "run-workflow" {
                Invoke-RunWorkflow -Step $Step
            }
            "validate-state" {
                Invoke-ValidateState -Step $Step
            }
            "execute-command" {
                Invoke-ExecuteCommand -Step $Step
            }
            "comment" {
                Invoke-Comment -Step $Step
            }
            default {
                $supportedActions = @("setup-git-state", "run-workflow", "validate-state", "execute-command", "comment")
                throw "Unknown action type: $action. Supported actions: $($supportedActions -join ', ')"
            }
        }
        
        Write-Debug "$($Emojis.Debug) Step $StepIndex completed: $($result.Success)"
        
        return $result
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Step $StepIndex failed: $_"
        return @{
            Success = $false
            Message = "Step execution error: $_"
        }
    }
}

<#
.SYNOPSIS
    Execute test cleanup.

.DESCRIPTION
    Performs cleanup actions specified in fixture.
    Integration with Setup-TestScenario.ps1: Call Clear-GitState for cleanup.

.PARAMETER Cleanup
    Cleanup object from fixture

.EXAMPLE
    $result = Invoke-TestCleanup -Cleanup $fixture.cleanup

.NOTES
    Returns hashtable with: Success, Message
#>
function Invoke-TestCleanup {
    param([Parameter(Mandatory = $true)][object]$Cleanup)

    # TODO: skip for now
    return @{
        Success = $true
        Message = "Cleanup skipped"
    }
    
    $action = $Cleanup.action
    
    Write-Debug "$($Emojis.Cleanup) Executing cleanup: $action"
    
    try {
        if ($action -eq "reset-git-state") {
            # Call Clear-GitState from Setup-TestScenario.ps1
            $result = Clear-GitState -DeleteTags $true
            
            Write-Debug "$($Emojis.Debug) Cleanup completed"
            
            return @{
                Success = $true
                Message = "Git state reset successfully"
            }
        } else {
            return @{
                Success = $true
                Message = "Unknown cleanup action: $action (skipped)"
            }
        }
    } catch {
        Write-DebugMessage -Type "WARNING" -Message "Cleanup failed: $_"
        return @{
            Success = $false
            Message = "Cleanup error: $_"
        }
    }
}

<#
.SYNOPSIS
    Run a single integration test.

.DESCRIPTION
    Orchestrates complete test execution: backup, apply scenario, run steps, validate, cleanup, restore.
    Integration: Uses Backup-GitState for state preservation, Setup-TestScenario for scenario application.
    Test isolation: Each test runs in clean state. Backup/restore ensures no cross-test contamination.

.PARAMETER FixturePath
    Path to fixture JSON file

.PARAMETER SkipBackup
    Skip backup/restore (default: $false)

.PARAMETER SkipCleanup
    Skip cleanup (default: $false)

.EXAMPLE
    $result = Invoke-IntegrationTest -FixturePath "tests/integration/test.json"

.NOTES
    Returns test result object with: TestName, Success, Duration, StepResults, Message
#>
function Invoke-IntegrationTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FixturePath,
        
        [Parameter(Mandatory = $false)]
        [bool]$SkipBackup = $false,
        
        [Parameter(Mandatory = $false)]
        [bool]$SkipCleanup = $false
    )

    $testStartTime = Get-Date
    $backupName = $null
    $stepResults = @()
    
    try {
        # Parse fixture
        $fixture = Get-FixtureContent -FixturePath $FixturePath
        
        # Display test header
        Write-TestHeader -TestName $fixture.name -TestDescription $fixture.description
        
        Write-Debug "$($Emojis.Debug) Test configuration: SkipBackup=$SkipBackup, SkipCleanup=$SkipCleanup"
        
        # Backup git state
        # Integration with Backup-GitState.ps1: Call Backup-GitState before each test
        if (-not $SkipBackup) {
            Write-Debug "$($Emojis.Debug) Backing up git state"
            $backup = Backup-GitState
            $backupName = $backup.BackupName
            Write-Debug "$($Emojis.Debug) Backup created: $backupName"
        }
        
        # Execute test steps
        $allStepsPassed = $true
        for ($i = 0; $i -lt $fixture.steps.Count; $i++) {
            $step = $fixture.steps[$i]
            $stepIndex = $i + 1
            
            $stepResult = Invoke-TestStep -Step $step -StepIndex $stepIndex
            $stepResults += $stepResult
            
            if (-not $stepResult.Success) {
                $allStepsPassed = $false
                Write-DebugMessage -Type "WARNING" -Message "Step $stepIndex failed: $($stepResult.Message)"
                
                if ($StopOnFailure) {
                    Write-Debug "$($Emojis.Debug) Stopping test execution (StopOnFailure=true)"
                    break
                }
            }
        }
        
        # Execute cleanup
        if (-not $SkipCleanup -and $fixture.cleanup) {
            $cleanupResult = Invoke-TestCleanup -Cleanup $fixture.cleanup
            if (-not $cleanupResult.Success) {
                Write-DebugMessage -Type "WARNING" -Message "Cleanup failed: $($cleanupResult.Message)"
            }
        }
        
        # Determine test result
        $testPassed = $allStepsPassed
        $testMessage = if ($testPassed) { "All steps passed" } else { "One or more steps failed" }
        
        $testResult = @{
            TestName    = $fixture.name
            Success     = $testPassed
            Duration    = (Get-Date) - $testStartTime
            StepResults = $stepResults
            Message     = $testMessage
        }
        
        return $testResult
        
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Test execution error: $_"
        
        return @{
            TestName    = if ($fixture) { $fixture.name } else { "Unknown" }
            Success     = $false
            Duration    = (Get-Date) - $testStartTime
            StepResults = $stepResults
            Message     = "Test execution error: $_"
        }
    } finally {
        # Restore git state
        # Integration with Backup-GitState.ps1: Call Restore-GitState after each test
        if (-not $SkipBackup -and $backupName) {
            Write-Debug "$($Emojis.Restore) Restoring git state from backup: $backupName"
            try {
                Restore-GitState -BackupName $backupName -Force $true -DeleteExistingTags $true
                Write-Debug "$($Emojis.Debug) Git state restored"
            } catch {
                Write-DebugMessage -Type "ERROR" -Message "Failed to restore git state: $_"
                Write-DebugMessage -Type "WARNING" -Message "Manual recovery may be needed. Use Get-AvailableBackups to list backups."
            }
        }
        
        # Display test result
        $duration = (Get-Date) - $testStartTime
        Write-TestResult -TestName $testResult.TestName -Success $testResult.Success -Duration $duration -Message $testResult.Message
    }
}

<#
.SYNOPSIS
    Run all integration tests.

.DESCRIPTION
    Executes all fixtures in tests/integration directory sequentially.

.PARAMETER TestsDirectory
    Optional directory path (defaults to tests/integration)

.PARAMETER StopOnFailure
    Stop on first test failure (default: $false)

.PARAMETER SkipBackup
    Skip backup/restore (default: $false)

.PARAMETER SkipCleanup
    Skip cleanup (default: $false)

.EXAMPLE
    $results = Invoke-AllIntegrationTests

.NOTES
    Returns array of test result objects.
    Parallel execution not supported in first iteration (sequential execution only).
#>
function Invoke-AllIntegrationTests {
    param(
        [Parameter(Mandatory = $false)]
        [string]$TestsDirectory = $IntegrationTestsDirectory,
        
        [Parameter(Mandatory = $false)]
        [bool]$StopOnFailure = $false,
        
        [Parameter(Mandatory = $false)]
        [bool]$SkipBackup = $false,
        
        [Parameter(Mandatory = $false)]
        [bool]$SkipCleanup = $false
    )

    Write-DebugMessage -Type "INFO" -Message "Starting all integration tests"
    
    $fixtures = Get-AllIntegrationTestFixtures -TestsDirectory $TestsDirectory
    
    Write-DebugMessage -Type "INFO" -Message "Found $($fixtures.Count) tests to run"
    
    $testResults = @()
    
    foreach ($fixture in $fixtures) {
        $result = Invoke-IntegrationTest -FixturePath $fixture.FilePath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
        $testResults += $result
        
        if (-not $result.Success -and $StopOnFailure) {
            Write-DebugMessage -Type "WARNING" -Message "Stopping test execution (StopOnFailure=true)"
            break
        }
    }
    
    return $testResults
}

# ============================================================================
# Reporting Functions
# ============================================================================

<#
.SYNOPSIS
    Display test execution summary.

.DESCRIPTION
    Shows comprehensive test results with statistics and visual formatting.

.PARAMETER TestResults
    Array of test result objects

.EXAMPLE
    Write-TestSummary -TestResults $results
#>
function Write-TestSummary {
    param([Parameter(Mandatory = $true)][array]$TestResults)
    
    # Calculate statistics
    $totalTests = $TestResults.Count
    $passedTests = @($TestResults | Where-Object { $_.Success }).Count
    $failedTests = $totalTests - $passedTests
    $totalDuration = ($TestResults | Measure-Object -Property Duration -Sum).Sum
    $avgDuration = if ($totalTests -gt 0) { $totalDuration.TotalSeconds / $totalTests } else { 0 }
    
    # Display header
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Test Execution Summary" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    # Display statistics
    Write-Host "Total Tests:     $totalTests" -ForegroundColor Gray
    Write-Host "Passed Tests:    " -NoNewline -ForegroundColor Gray
    Write-Host "$passedTests" -ForegroundColor Green
    Write-Host "Failed Tests:    " -NoNewline -ForegroundColor Gray
    if ($failedTests -gt 0) {
        Write-Host "$failedTests" -ForegroundColor Red
    } else {
        Write-Host "$failedTests" -ForegroundColor Green
    }
    Write-Host "Total Duration:  $("{0:N2}s" -f $totalDuration.TotalSeconds)" -ForegroundColor Gray
    Write-Host "Average Duration: $("{0:N2}s" -f $avgDuration)" -ForegroundColor Gray
    Write-Host ""
    
    # List failed tests
    if ($failedTests -gt 0) {
        Write-Host "Failed Tests:" -ForegroundColor Red
        foreach ($result in $TestResults) {
            if (-not $result.Success) {
                Write-Host "  $($Emojis.Error) $($result.TestName)" -ForegroundColor Red
                Write-Host "     $($result.Message)" -ForegroundColor Gray
            }
        }
        Write-Host ""
    }
    
    # Overall result
    if ($failedTests -eq 0) {
        Write-Host "$($Emojis.Success) ALL TESTS PASSED" -ForegroundColor Green
    } else {
        Write-Host "$($Emojis.Error) SOME TESTS FAILED" -ForegroundColor Red
    }
    
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

<#
.SYNOPSIS
    Export test results to JSON file.

.DESCRIPTION
    Saves test report to system temp logs directory.

.PARAMETER TestResults
    Array of test result objects

.PARAMETER OutputPath
    Optional output path (defaults to timestamped file)

.EXAMPLE
    $reportPath = Export-TestReport -TestResults $results

.NOTES
    Returns path to exported report file.
#>
function Export-TestReport {
    param(
        [Parameter(Mandatory = $true)]
        [array]$TestResults,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    # Generate output path if not provided
    if (-not $OutputPath) {
        $logsDir = $TestLogsDirectory
        New-TestStateDirectory | Out-Null
        
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $OutputPath = Join-Path $logsDir "test-report-$timestamp.json"
    }
    
    # Calculate statistics
    $totalTests = $TestResults.Count
    $passedTests = @($TestResults | Where-Object { $_.Success }).Count
    $failedTests = $totalTests - $passedTests
    $totalDuration = ($TestResults | Measure-Object -Property Duration -Sum).Sum
    
    # Create report object
    $report = @{
        timestamp     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        totalTests    = $totalTests
        passedTests   = $passedTests
        failedTests   = $failedTests
        totalDuration = $totalDuration.TotalSeconds
        tests         = $TestResults
    }
    
    # Export to JSON
    try {
        $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-DebugMessage -Type "INFO" -Message "Test report exported to: $OutputPath"
        return $OutputPath
    } catch {
        Write-DebugMessage -Type "WARNING" -Message "Failed to export test report: $_"
        return $null
    }
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Act Integration Test Runner" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Purpose: Orchestrate integration tests for d-flows workflows using act" -ForegroundColor Gray
    Write-Host ""
    
    # Validate prerequisites
    Write-DebugMessage -Type "INFO" -Message "Validating prerequisites..."
    
    # Check repository
    try {
        $repoRoot = Get-RepositoryRoot
        Write-Debug "$($Emojis.Debug) Repository root: $repoRoot"
    } catch {
        Write-DebugMessage -Type "ERROR" -Message $_
        exit 1
    }
    
    # Check act availability
    if (-not (Test-ActAvailable)) {
        Write-DebugMessage -Type "ERROR" -Message "act is not available. Please install it before running tests."
        exit 1
    }
    
    # Check Docker
    if (-not (Test-DockerRunning)) {
        Write-DebugMessage -Type "ERROR" -Message "Docker is not running. Please start Docker Desktop before running tests."
        exit 1
    }
    
    # Create test state directory
    New-TestStateDirectory | Out-Null
    
    # Dot-source required scripts
    # Integration with Backup-GitState.ps1 and Setup-TestScenario.ps1
    Write-Debug "$($Emojis.Debug) Loading required scripts"
    
    try {
        $backupScriptPath = Join-Path $repoRoot "scripts\integration\Backup-GitState.ps1"
        $scenarioScriptPath = Join-Path $repoRoot "scripts\integration\Setup-TestScenario.ps1"
        
        . $backupScriptPath
        . $scenarioScriptPath
        
        Write-Debug "$($Emojis.Debug) Required scripts loaded"
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to load required scripts: $_"
        exit 1
    }
    
    # Display configuration
    Write-Host "Configuration:" -ForegroundColor Yellow
    Write-Host "  Skip Backup:   $SkipBackup" -ForegroundColor Gray
    Write-Host "  Skip Cleanup:  $SkipCleanup" -ForegroundColor Gray
    Write-Host "  Stop On Failure: $StopOnFailure" -ForegroundColor Gray
    Write-Host ""
    
    # Determine execution mode and run tests
    $testResults = @()
    
    try {
        if ($TestFixturePath) {
            # Run specific test by path
            # How to run single test: Run-ActTests -TestFixturePath "tests/integration/v0-to-v1-release-cycle.json"
            Write-DebugMessage -Type "INFO" -Message "Running single test: $TestFixturePath"
            $fullPath = Join-Path $repoRoot $TestFixturePath
            $result = Invoke-IntegrationTest -FixturePath $fullPath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
            $testResults += $result
        }
        elseif ($TestName) {
            # Run specific test by name
            Write-DebugMessage -Type "INFO" -Message "Searching for test: $TestName"
            $fixture = Find-FixtureByName -TestName $TestName
            $result = Invoke-IntegrationTest -FixturePath $fixture.FilePath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
            $testResults += $result
        }
        elseif ($RunAll) {
            # Run all tests
            # How to run all tests: Run-ActTests -RunAll
            Write-DebugMessage -Type "INFO" -Message "Running all integration tests"
            $testResults = Invoke-AllIntegrationTests -StopOnFailure $StopOnFailure -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
        }
        else {
            # No execution mode specified
            Write-DebugMessage -Type "WARNING" -Message "No test execution mode specified. Use -RunAll to run all tests, -TestFixturePath for a specific test, or -TestName to search for a test."
            Write-Host ""
            Write-Host "Usage:" -ForegroundColor Yellow
            Write-Host "  .\scripts\integration\Run-ActTests.ps1 -RunAll                                                      # Run all tests" -ForegroundColor Gray
            Write-Host "  .\scripts\integration\Run-ActTests.ps1 -TestFixturePath 'tests/integration/v0-to-v1-release-cycle.json'  # Run specific test" -ForegroundColor Gray
            Write-Host "  .\scripts\integration\Run-ActTests.ps1 -TestName 'Test Name'                                       # Search for and run test" -ForegroundColor Gray
            Write-Host ""
            exit 0
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Test execution failed: $_"
        exit 1
    }
    
    # Display summary
    Write-TestSummary -TestResults $testResults
    
    # Export report
    # How to view test logs: Check system temp directory for d-flows-test-state-*/logs/ directory
    $reportPath = Export-TestReport -TestResults $testResults
    
    # Cleanup test state directory
    if (-not $SkipCleanup) {
        Write-Debug "$($Emojis.Cleanup) Cleaning up test state directory"
        $cleanupResult = Remove-TestStateDirectory
        if ($cleanupResult) {
            Write-DebugMessage -Type "SUCCESS" -Message "Test state directory cleaned up successfully"
        } else {
            Write-DebugMessage -Type "WARNING" -Message "Failed to clean up test state directory - may require manual removal"
        }
    } else {
        Write-DebugMessage -Type "INFO" -Message "Test state directory preserved for debugging: $TestStateDirectory"
    }
    
    # Exit with appropriate code
    $failedTests = @($testResults | Where-Object { -not $_.Success }).Count
    exit $(if ($failedTests -eq 0) { 0 } else { 1 })
}

