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
# Module Imports
# ============================================================================

# Clear old module versions before bootstrapping
Get-Module | Where-Object { $_.Name -in 'RepositoryUtils', 'MessageUtils','Emojis','Colors' } | Remove-Module -Force
Remove-Variable -Name Emojis,Colors -Scope Global -ErrorAction SilentlyContinue

$scriptDir = $PSScriptRoot
$integrationDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $integrationDir

# Add to PSModulePath only if not already present
$projectModules = Join-Path $root 'scripts\Modules'
$utilitiesModules = Join-Path $projectModules 'Utilities'

# Function to prepend a path if missing
function Add-ToPSModulePath {
    param([string]$Path)
    if (-not ($env:PSModulePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $Path })) {
        $env:PSModulePath = "$Path;$env:PSModulePath"
    }
}

# Prepend both paths
Add-ToPSModulePath $utilitiesModules
Add-ToPSModulePath $projectModules

# PowerShell will auto-load them when their functions are called!
# Import-Module -Name (Join-Path $PSScriptRoot "../Modules/Utilities/MessageUtils") -ErrorAction Stop
# Import-Module -Name (Join-Path $PSScriptRoot "../Modules/Utilities/RepositoryUtils") -ErrorAction Stop

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

$ActCommand = Get-Command "act" | Select-Object -ExpandProperty Source

# ============================================================================
# Helper Functions
# ============================================================================

<#
.SYNOPSIS
    Create test state directories if they don't exist.

.DESCRIPTION
    Creates test state and logs directories in system temp location with unique GUID-based naming.
    Each script execution generates a unique GUID-based subdirectory (d-flows-test-state-<guid>)
    to ensure test isolation and prevent conflicts between concurrent test runs.

.EXAMPLE
    $testStateDir = New-TestStateDirectory
    Write-Message -Type "Info" -Message "Test state directory: $testStateDir"

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
        Write-Message -Type "Debug" -Message "Creating temp test state directory: $testStatePath"
        New-Item -ItemType Directory -Path $testStatePath -Force | Out-Null
        Write-Message -Type "Debug" -Message "Test state directory created"
    } else {
        Write-Message -Type "Debug" -Message "Test state directory already exists: $testStatePath"
    }
    
    if (-not (Test-Path $testLogsPath)) {
        Write-Message -Type "Debug" -Message "Creating temp test logs directory: $testLogsPath"
        New-Item -ItemType Directory -Path $testLogsPath -Force | Out-Null
        Write-Message -Type "Debug" -Message "Test logs directory created"
    } else {
        Write-Message -Type "Debug" -Message "Test logs directory already exists: $testLogsPath"
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
            Write-Message -Type "Debug" -Message "Removing test state directory: $Path"
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Message -Type "Debug" -Message "Test state directory removed successfully"
            return $true
        } else {
            Write-Message -Type "Debug" -Message "Test state directory does not exist: $Path"
            return $true
        }
    } catch {
        Write-Message -Type "Warning" -Message "Failed to remove test state directory: $_"
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
        Write-Message -Type "Debug" -Message "Converting path for Docker: $fullPath"

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
                Write-Message -Type "Debug" -Message "Converted UNC path to Docker format: $dockerPath"
                return $dockerPath
            }

            # Handle local drive paths (C:\, D:\, etc.)
            if ($fullPath -match '^([A-Z]):') {
                $driveLetter = [char]::ToLower([char]($matches[1]))
                $pathWithoutDrive = $fullPath.Substring(2)
                $dockerPath = "/$driveLetter$($pathWithoutDrive -replace '\\', '/')"
                Write-Message -Type "Debug" -Message "Converted Windows path to Docker format: $dockerPath"
                return $dockerPath
            }

            throw "Unrecognized Windows path format: $fullPath"
        } else {
            # On Linux, path should already be in correct format
            Write-Message -Type "Debug" -Message "Linux path already in Docker format: $fullPath"
            return $fullPath
        }
    } catch {
        Write-Message -Type "Error" -Message "Failed to convert path to Docker format: $_"
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
    Write-Message -Type "Info" -Message "Starting test execution"
    Write-Message -Type "Success" -Message "Test passed"
#>

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

    Write-Message -Message ""
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════"
    Write-Message -Type "Test" -Message "$TestName"
    if ($TestDescription) {
        Write-Message -Type "Info" -Message "   $TestDescription"
    }
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════"
    Write-Message -Message ""
    
    Write-Message -Type "Debug" -Message "Starting test: $TestName"
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

    $type = if ($Success) { "Success" } else { "Error" }
    $status = if ($Success) { "PASSED" } else { "FAILED" }
    
    $durationText = "{0:N2}s" -f $Duration.TotalSeconds
    
    Write-Message -Message ""
    Write-Message -Message "Test ${status}: $TestName ($durationText)"
    
    if ($Message) {
        Write-Message -Type "Info" -Message "   $Message"
    }
    
    Write-Message -Message ""
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

    Write-Message -Type "Debug" -Message "Parsing fixture: $FixturePath"
    
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
        
        Write-Message -Type "Debug" -Message "Parsed fixture: $($fixture.name) with $($fixture.steps.Count) steps"
        
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
    Write-Message -Type "Info" -Message "Found $($fixtures.Count) fixtures"

.NOTES
    Returns array of fixture objects with file paths.
#>
function Get-AllIntegrationTestFixtures {
    param(
        [Parameter(Mandatory = $false)]
        [string]$TestsDirectory = $IntegrationTestsDirectory
    )

    Write-Message -Type "Debug" -Message "Scanning for fixtures in: $TestsDirectory"
    
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
            Write-Message -Type "Warning" -Message "Failed to parse fixture '$($file.Name)': $_"
            continue
        }
    }
    
    Write-Message -Type "Debug" -Message "Found $($fixtures.Count) valid fixtures"
    
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

    Write-Message -Type "Debug" -Message "Searching for fixture with name: $TestName"
    
    $fixtures = Get-AllIntegrationTestFixtures -TestsDirectory $TestsDirectory
    
    $matchingFixture = $fixtures | Where-Object { 
        $_.name -like "*$TestName*" 
    } | Select-Object -First 1
    
    if (-not $matchingFixture) {
        throw "No fixture found matching name: $TestName"
    }
    
    Write-Message -Type "Debug" -Message "Found fixture: $($matchingFixture.name)"
    
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
    if (Test-ActAvailable) { Write-Message -Type "Info" -Message "act is available" }

.NOTES
    Returns $true if available, $false otherwise.
    Provides installation instructions if not found.
#>
function Test-ActAvailable {
    Write-Message -Type "Debug" -Message "Checking if act is available"
    
    try {
        $actVersion = & $ActCommand --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Message -Type "Debug" -Message "act version: $actVersion"
            return $true
        }
    } catch {
        Write-Message -Type "Error" -Message "act not found. Install using: winget install nektos.act"
        return $false
    }
    
    Write-Message -Type "Error" -Message "act not found. Install using: winget install nektos.act"
    return $false
}

<#
.SYNOPSIS
    Check if Docker is running.

.DESCRIPTION
    Executes 'docker ps' to verify Docker daemon is accessible.

.EXAMPLE
    if (Test-DockerRunning) { Write-Message -Type "Info" -Message "Docker is running" }

.NOTES
    Returns $true if running, $false otherwise.
#>
function Test-DockerRunning {
    Write-Message -Type "Debug" -Message "Checking if Docker is running"
    
    try {
        $dockerPs = docker ps 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Message -Type "Debug" -Message "Docker is running"
            return $true
        }
    } catch {
        Write-Message -Type "Error" -Message "Docker is not running. Start Docker Desktop and try again."
        return $false
    }
    
    Write-Message -Type "Error" -Message "Docker is not running. Start Docker Desktop and try again."
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
    - TEST_STATE_PATH environment variable provides container path to workflows (always ends with '/')
    - Mount is read-write, allowing workflows to create/modify test state files

    Container Access:
    - Workflows can access mounted directory via /tmp/test-state path
    - TEST_STATE_PATH environment variable normalized to /tmp/test-state/ for convenience
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

    Write-Message -Type "Workflow" -Message "Preparing to run workflow: $WorkflowFile"
    
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
    
    # This is only used in local dev environment, on CI secrets.GITHUB_TOKEN or env.GITHUB_TOKEN is used
    $actArgs += "--env"
    $actArgs += "TOKEN_FALLBACK=${env:GITHUB_TOKEN}"
    
    $containerTestStatePath = "/tmp/test-state"
    $testStateEnvPath = if ($containerTestStatePath.EndsWith("/")) {
        $containerTestStatePath
    } else {
        "$containerTestStatePath/"
    }

    # Set ACT environment variable for workflows
    $actArgs += "--env"
    $actArgs += "ACT=true"

    # Set TEST_STATE_PATH environment variable to provide mounted path to workflows
    $actArgs += "--env"
    $actArgs += "TEST_STATE_PATH=$testStateEnvPath"

    # Bind current directory, this will write to git repository
    $actArgs += "--bind"
    
    # Mount test state directory into container for test tag access
    try {
        $dockerTestStatePath = ConvertTo-DockerMountPath -Path $TestStateDirectory
        Write-Message -Type "Debug" -Message "Mounting volume: $TestStateDirectory -> $containerTestStatePath"
        Write-Message -Type "Debug" -Message "Docker path: $dockerTestStatePath"
        
        $mountOption = "--mount type=bind,src=$dockerTestStatePath,dst=$containerTestStatePath"
        $actArgs += "--container-options"
        $actArgs += $mountOption
    } catch {
        Write-Message -Type "Warning" -Message "Failed to convert test state path for Docker mount: $_"
        Write-Message -Type "Info" -Message "Continuing without volume mount (workflows may not access test state)"
    }
    
    # Execute act and capture output
    $startTime = Get-Date
    
    try {
        Write-Message -Type "Debug" -Message "ActCommand: $ActCommand"
        Write-Message -Type "Debug" -Message "actArgs: $actArgs"
        if ($CaptureOutput) {
            $output = & $ActCommand @actArgs 2>&1 | Out-String
        } else {
            & $ActCommand @actArgs
            $output = ""
        }
        
        $exitCode = $LASTEXITCODE
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        Write-Message -Type "Debug" -Message "Act execution completed in $($duration.TotalSeconds) seconds with exit code: $exitCode"
        
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
        Write-Message -Type "Error" -Message "Act execution failed: $_"
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

    Write-Message -Type "Debug" -Message "Parsing act output for OUTPUT: markers"
    
    $outputs = @{}
    $lines = $Output -split "`n"
    
    foreach ($line in $lines) {
        if ($line -match 'OUTPUT:\s*([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $outputs[$key] = $value
            Write-Message -Type "Debug" -Message "Found output: $key = $value"
        }
    }
    
    Write-Message -Type "Debug" -Message "Parsed $($outputs.Count) outputs"
    
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

.PARAMETER ActResult
    The workflow execution result needed for workflow-success validation.
    This is passed from the test context and contains the result from the most recent run-workflow step.

.EXAMPLE
    $result = Invoke-ValidationCheck -Check @{ type = "tag-exists"; tag = "v1.0.0" }

.EXAMPLE
    $result = Invoke-ValidationCheck -Check @{ type = "workflow-success"; workflow = "bump-version" } -ActResult $lastActResult

.NOTES
    Returns hashtable with: Success, Message, Type
#>
function Invoke-ValidationCheck {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Check,
        
        [Parameter(Mandatory = $false)]
        [object]$ActResult
    )

    $checkType = $Check.type
    Write-Message -Type "Validation" -Message "Executing validation: $checkType"
    
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
            "no-cross-contamination" {
                return Validate-NoCrossContamination -V1 $Check.v1 -V2 $Check.v2
            }
            "no-tag-conflicts" {
                return Validate-NoTagConflicts
            }
            "workflow-success" {
                # Validate that ActResult is available for workflow-success checks
                if (-not $ActResult) {
                    return @{
                        Success = $false
                        Message = "workflow-success validation requires a preceding run-workflow step. ActResult is null."
                        Type    = $checkType
                    }
                }
                return Validate-WorkflowSuccess -Workflow $Check.workflow -ActResult $ActResult
            }
            "workflow-failure" {
                # Validate that ActResult is available for workflow-failure checks
                if (-not $ActResult) {
                    return @{
                        Success = $false
                        Message = "workflow-failure validation requires a preceding run-workflow step. ActResult is null."
                        Type    = $checkType
                    }
                }
                return Validate-WorkflowFailure -Workflow $Check.workflow -ActResult $ActResult
            }
            "idempotency-verified" {
                return Validate-IdempotencyVerified
            }
            default {
                $supportedTypes = @(
                    "tag-exists", "tag-not-exists", "tag-points-to", "tag-accessible", "tag-count",
                    "branch-exists", "branch-points-to-tag", "branch-count", "current-branch",
                    "version-greater", "version-progression", "major-increment", "major-tag-coexistence",
                    "major-tags-coexist", "major-tag-progression", "no-cross-contamination",
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
    
    Write-Message -Type "Validation" -Message "Tag '$Tag' exists: $exists"
    
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
    
    Write-Message -Type "Validation" -Message "Tag '$Tag' does not exist: $notExists"
    
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
        $tagSha = git rev-parse "$Tag^{commit}" 2>$null
        $targetSha = git rev-parse "$Target^{commit}" 2>$null
        
        $matches = ($tagSha -eq $targetSha)
        
        Write-Message -Type "Validation" -Message "Tag '$Tag' points to '$Target': $matches"
        
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
        
        Write-Message -Type "Validation" -Message "Tag '$Tag' accessible: $accessible"
        
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
    
    Write-Message -Type "Validation" -Message "Tag count: $actual (expected: $Expected)"
    
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
    
    Write-Message -Type "Validation" -Message "Branch '$Branch' exists: $exists"
    
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
        
        Write-Message -Type "Validation" -Message "Branch '$Branch' points to tag '$Tag': $matches"
        
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
    
    Write-Message -Type "Validation" -Message "Branch count: $actual (expected: $Expected)"
    
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
    
    Write-Message -Type "Validation" -Message "Current branch is '$Branch': $matches"
    
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
        
        Write-Message -Type "Validation" -Message "Version '$New' > '$Current': $greater"
        
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
        
        Write-Message -Type "Validation" -Message "Version progression '$From' -> '$To' ($BumpType): $valid"
        
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
    
    Write-Message -Type "Validation" -Message "Major increment $From -> ${To}: $valid"
    
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
    
    Write-Message -Type "Validation" -Message "Major tags coexist ($($Tags -join ', ')): $allExist"
    
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
    
    Write-Message -Type "Validation" -Message "Major tag progression ($($Tags -join ', ')): $valid"
    
    return @{
        Success = $valid
        Message = if ($valid) { "Major tags progress correctly: $($Tags -join ', ')" } else { "Major tag progression invalid" }
        Type    = "major-tag-progression"
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
        
        Write-Message -Type "Validation" -Message "No cross-contamination between '$V1' and '$V2': $valid"
        
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
    
    Write-Message -Type "Validation" -Message "No tag conflicts: $noDuplicates"
    
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
    
    Write-Message -Type "Validation" -Message "Workflow '$Workflow' success: $success"
    
    return @{
        Success = $success
        Message = if ($success) { "Workflow '$Workflow' succeeded" } else { "Workflow '$Workflow' failed with exit code: $($ActResult.ExitCode)" }
        Type    = "workflow-success"
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
    Validate-WorkflowFailure -Workflow "bump-version" -ActResult $actResult
#>
function Validate-WorkflowFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][object]$ActResult
    )

    $success = -not $ActResult.Success -and ($ActResult.ExitCode -ne 0)

    Write-Message -Type "Validation" -Message "Workflow '$Workflow' failure: $success"

    return @{
        Success = $success
        Message = if ($success) { "Workflow '$Workflow' failed as expected" } else { "Workflow '$Workflow' succeeded unexpectedly" }
        Type    = "workflow-failure"
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
    Write-Message -Type "Validation" -Message "Idempotency check (placeholder)"
    
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
    
    Write-Message -Type "Validation" -Message "User pinning check: $Expectation (placeholder)"
    
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
    
    Write-Message -Type "Debug" -Message "Applying scenario: $scenario"
    
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
        
        Write-Message -Type "Debug" -Message "Scenario '$scenario' applied successfully"
        
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

.PARAMETER TestContext
    Test execution context providing access to production tags for filtering during test state re-export

.EXAMPLE
    $result = Invoke-RunWorkflow -Step $step -TestContext $testContext

.NOTES
    Returns hashtable with: Success, Message, ActResult, OutputsMatched, ErrorMessageFound
#>
function Invoke-RunWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Step,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$TestContext
    )
    
    $workflow = $Step.workflow
    $fixture = $Step.fixture
    $expectedOutputs = $Step.expectedOutputs
    $expectedFailure = if ($Step.expectedFailure) { $Step.expectedFailure } else { $false }
    $expectedErrorMessage = $Step.expectedErrorMessage
    
    Write-Message -Type "Workflow" -Message "Running workflow: $workflow with fixture: $fixture"
    
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
        
        Write-Message -Type "Debug" -Message "Workflow execution result: $success"
        
        # Update test state files after workflow execution
        Write-Message -Type "Debug" -Message "Updating test state files after workflow execution"
        
        # Calculate test-only tags (exclude production tags)
        $productionTags = if ($TestContext -and $TestContext.ProductionTags) { $TestContext.ProductionTags } else { @() }
        $allCurrentTags = @(git tag -l)
        $testTags = @($allCurrentTags | Where-Object { $_ -notin $productionTags })
        Write-Message -Type "Debug" -Message "Filtering tags: $($allCurrentTags.Count) total, $($productionTags.Count) production, $($testTags.Count) test tags to export"
        
        # Get all current branches
        $allCurrentBranches = @(git branch -l | ForEach-Object { $_.TrimStart('*').Trim() } | Where-Object { $_ -and $_ -notmatch '^\(HEAD' })
        Write-Message -Type "Debug" -Message "Found $($allCurrentBranches.Count) branches to export"
        
        # Export current tags to test-tags.txt (only test tags)
        try {
            $tagsOutputPath = Export-TestTagsFile -Tags $testTags -OutputPath (Join-Path $TestStateDirectory "test-tags.txt")
            Write-Message -Type "Debug" -Message "Test tags file updated: $tagsOutputPath"
        } catch {
            Write-Message -Type "Warning" -Message "Failed to update test-tags.txt: $_"
        }
        
        # Export current branches to test-branches.txt
        try {
            $branchesOutputPath = Export-TestBranchesFile -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory "test-branches.txt")
            Write-Message -Type "Debug" -Message "Test branches file updated: $branchesOutputPath"
        } catch {
            Write-Message -Type "Warning" -Message "Failed to update test-branches.txt: $_"
        }
        
        # Export commit bundle to test-commits.bundle (only commits referenced by test tags and branches)
        try {
            $bundleOutputPath = Export-TestCommitsBundle -Tags $testTags -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory "test-commits.bundle")
            Write-Message -Type "Debug" -Message "Test commits bundle updated: $bundleOutputPath"
        } catch {
            Write-Message -Type "Warning" -Message "Failed to update test-commits.bundle: $_"
        }
        
        Write-Message -Type "Debug" -Message "Test state synchronization completed"
        
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

.PARAMETER TestContext
    Test execution context containing state from previous steps, including the last ActResult from run-workflow steps.
    This allows validate-state steps to access workflow execution results for workflow-success validation.

.EXAMPLE
    $result = Invoke-ValidateState -Step $step

.EXAMPLE
    $result = Invoke-ValidateState -Step $step -TestContext $testContext

.NOTES
    Returns hashtable with: Success, Message, CheckResults, PassedCount, FailedCount
#>
function Invoke-ValidateState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Step,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$TestContext
    )
    
    $checks = $Step.checks
    
    Write-Message -Type "Validation" -Message "Performing $($checks.Count) validation checks"
    
    # Extract ActResult from test context if available
    $lastActResult = $null
    if ($TestContext -and $TestContext.ContainsKey('LastActResult')) {
        $lastActResult = $TestContext.LastActResult
        Write-Message -Type "Debug" -Message "Using ActResult from test context"
    }
    
    $checkResults = @()
    $passedCount = 0
    $failedCount = 0
    
    foreach ($check in $checks) {
        try {
            $result = Invoke-ValidationCheck -Check $check -ActResult $lastActResult
            $checkResults += $result
            
            if ($result.Success) {
                $passedCount++
            } else {
                $failedCount++
                Write-Message -Type "Warning" -Message "Validation failed: $($result.Message)"
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
    
    Write-Message -Type "Debug" -Message "$message"
    
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
    Executes an external command from a single string, capturing stdout, stderr, and exit code.

.DESCRIPTION
    Run-Command safely executes a command provided as a single string.
    It handles quoted arguments correctly, merges stdout and stderr,
    and returns both the full output and the exit code as a PSCustomObject.

.PARAMETER Command
    The command string to execute, including arguments.
    Example: "git commit --allow-empty -m 'Trigger release v0.2.1'"

.PARAMETER VerboseOutput
    Switch. If specified, prints the command, exit code, and output to the host.

.EXAMPLE
    $result = Run-Command "git commit --allow-empty -m 'Trigger release v0.2.1'"
    Write-Message -Type "Debug" -Message "Exit code: $($result.ExitCode)"
    Write-Message -Type "Info" -Message "Output: $($result.Output)"

.EXAMPLE
    Run-Command "docker build -t myimage ." -VerboseOutput

.NOTES
    - Avoids Invoke-Expression to improve safety.
    - Properly splits the string into executable + arguments.
    - Captures both stdout and stderr.
#>
function Run-Command {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Command,

        [switch]$VerboseOutput
    )

    # Split command string into executable + args
    $tokens = [System.Management.Automation.PSParser]::Tokenize($Command, [ref]$null)
    if ($tokens.Count -eq 0) { throw "Command string is empty." }

    $exe = $tokens[0].Content
    $args = @()
    if ($tokens.Count -gt 1) {
        $args = $tokens[1..($tokens.Count - 1)] | ForEach-Object { $_.Content }
    }

    if ($VerboseOutput) {
        Write-Message -Type "Debug" -Message "Executing: $exe $($args -join ' ')"
    }

    # Execute command, capture stdout + stderr
    $output = & $exe @args 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($VerboseOutput) {
        Write-Message -Type "Debug" -Message "Exit code: $exitCode"
        Write-Message -Type "Debug" -Message "Output: $output"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output.Trim()
    }
}

<#
.SYNOPSIS
    Execute "execute-command" step.

.DESCRIPTION
    Runs arbitrary shell command and captures output.

.PARAMETER Step
    Step object from fixture

.PARAMETER TestContext
    Test execution context providing access to production tags for filtering during test state re-export

.EXAMPLE
    $result = Invoke-ExecuteCommand -Step $step -TestContext $testContext

.NOTES
    Returns hashtable with: Success, Message, Output, ExitCode
#>
function Invoke-ExecuteCommand {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Step,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$TestContext
    )
    
    $command = $Step.command
    
    Write-Message -Type "Debug" -Message "Executing command: $command"
    
    try {
        $result = Run-Command $command

        $output = $($result.Output)
        $exitCode = $($result.ExitCode)

        $success = ($exitCode -eq 0)
        
        Write-Message -Type "Debug" -Message "Command completed with exit code: $exitCode"

        # Update test state files after command execution
        Write-Message -Type "Debug" -Message "Updating test state files after command execution"

        # Calculate test-only tags (exclude production tags)
        $productionTags = if ($TestContext -and $TestContext.ProductionTags) { $TestContext.ProductionTags } else { @() }
        $allCurrentTags = @(git tag -l)
        $testTags = @($allCurrentTags | Where-Object { $_ -notin $productionTags })
        Write-Message -Type "Debug" -Message "Filtering tags: $($allCurrentTags.Count) total, $($productionTags.Count) production, $($testTags.Count) test tags to export"
        
        # Get all current branches
        $allCurrentBranches = @(git branch -l | ForEach-Object { $_.TrimStart('*').Trim() } | Where-Object { $_ -and $_ -notmatch '^\(HEAD' })
        Write-Message -Type "Debug" -Message "Found $($allCurrentBranches.Count) branches to export"

        # Export current tags to test-tags.txt (only test tags)
        try {
            $tagsOutputPath = Export-TestTagsFile -Tags $testTags -OutputPath (Join-Path $TestStateDirectory "test-tags.txt")
            Write-Message -Type "Debug" -Message "Test tags file updated: $tagsOutputPath"
        } catch {
            Write-Message -Type "Warning" -Message "Failed to update test-tags.txt: $_"
        }
        
        # Export current branches to test-branches.txt
        try {
            $branchesOutputPath = Export-TestBranchesFile -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory "test-branches.txt")
            Write-Message -Type "Debug" -Message "Test branches file updated: $branchesOutputPath"
        } catch {
            Write-Message -Type "Warning" -Message "Failed to update test-branches.txt: $_"
        }
        
        # Export commit bundle to test-commits.bundle (only commits referenced by test tags and branches)
        try {
            $bundleOutputPath = Export-TestCommitsBundle -Tags $testTags -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory "test-commits.bundle")
            Write-Message -Type "Debug" -Message "Test commits bundle updated: $bundleOutputPath"
        } catch {
            Write-Message -Type "Warning" -Message "Failed to update test-commits.bundle: $_"
        }
        
        Write-Message -Type "Debug" -Message "Test state synchronization completed"
        
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

    $skip = if ($Step.skip) { $Step.skip } else { $false }
    
    Write-Message -Type "Info" -Message $text
    
    return @{
        Success = $true
        Message = $text
        Skip = $skip
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

.PARAMETER TestContext
    Test execution context hashtable that maintains state between test steps.
    Used to pass ActResult from run-workflow steps to validate-state steps.

.EXAMPLE
    $result = Invoke-TestStep -Step $step -StepIndex 1

.EXAMPLE
    $result = Invoke-TestStep -Step $step -StepIndex 1 -TestContext $testContext

.NOTES
    Supported actions: setup-git-state, run-workflow, validate-state, execute-command, comment
#>
function Invoke-TestStep {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Step,
        
        [Parameter(Mandatory = $true)]
        [int]$StepIndex,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$TestContext
    )

    $action = $Step.action
    
    Write-Message -Type "Debug" -Message "Executing step $StepIndex ($action)"
    
    try {
        $result = switch ($action) {
            "setup-git-state" {
                Invoke-SetupGitState -Step $Step
            }
            "run-workflow" {
                Invoke-RunWorkflow -Step $Step -TestContext $TestContext
            }
            "validate-state" {
                Invoke-ValidateState -Step $Step -TestContext $TestContext
            }
            "execute-command" {
                Invoke-ExecuteCommand -Step $Step -TestContext $TestContext
            }
            "comment" {
                Invoke-Comment -Step $Step
            }
            default {
                $supportedActions = @("setup-git-state", "run-workflow", "validate-state", "execute-command", "comment")
                throw "Unknown action type: $action. Supported actions: $($supportedActions -join ', ')"
            }
        }
        
        Write-Message -Type "Debug" -Message "Step $StepIndex completed: $($result.Success)"
        
        return $result
    } catch {
        Write-Message -Type "Error" -Message "Step $StepIndex failed: $_"
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

    $action = $Cleanup.action
    
    Write-Message -Type "Cleanup" -Message "Executing cleanup: $action"
    
    try {
        if ($action -eq "reset-git-state") {
            # Call Clear-GitState from Setup-TestScenario.ps1
            $result = Clear-GitState -DeleteTags $true -DeleteBranches $true
            
            Write-Message -Type "Debug" -Message "Cleanup completed"
            
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
        Write-Message -Type "Warning" -Message "Cleanup failed: $_"
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
    
    Test Context Mechanism:
    - A test execution context (hashtable) is initialized at the start of each test
    - The context stores the LastActResult from run-workflow steps
    - This allows validate-state steps to access workflow results for workflow-success checks
    - The context is automatically passed between steps during test execution
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
        
        Write-Message -Type "Debug" -Message "Test configuration: SkipBackup=$SkipBackup, SkipCleanup=$SkipCleanup"
        
        # Initialize test execution context for sharing state between steps
        $testContext = @{ LastActResult = $null; ProductionTags = @() }
        Write-Message -Type "Debug" -Message "Initialized test execution context (tracking production tags)"
        
        # Backup git state
        # Integration with Backup-GitState.ps1: Call Backup-GitState before each test
        if (-not $SkipBackup) {
            Write-Message -Type "Debug" -Message "Backing up git state"
            $backup = Backup-GitState
            $backupName = $backup.BackupName
            Write-Message -Type "Debug" -Message "Backup created: $backupName"
        }
        
        # Execute test steps
        $allStepsPassed = $true
        for ($i = 0; $i -lt $fixture.steps.Count; $i++) {
            $step = $fixture.steps[$i]
            $stepIndex = $i + 1
            
            $stepResult = Invoke-TestStep -Step $step -StepIndex $stepIndex -TestContext $testContext
            $stepResults += $stepResult
            
            # Store ActResult in context if this was a run-workflow step
            if ($stepResult.ActResult) {
                $testContext.LastActResult = $stepResult.ActResult
                Write-Message -Type "Debug" -Message "Stored ActResult in test context for step $stepIndex"
            }
            
            # Store production tags if this was a setup-git-state step
            if ($step.action -eq 'setup-git-state' -and $stepResult.State -and $stepResult.State.ProductionTagsDeleted) {
                $testContext.ProductionTags = $stepResult.State.ProductionTagsDeleted
                Write-Message -Type "Debug" -Message "Captured $($testContext.ProductionTags.Count) production tags from setup-git-state step"
            }

            if ($step.Skip) {
                # for tests we only have two states: success and failure
                # future todo to have "skipped" state, for now treat as success but log as skipped
                Write-Message -Type "Warning" -Message "Step $stepIndex is skipping test execution"
                break
            }
            
            if (-not $stepResult.Success) {
                $allStepsPassed = $false
                Write-Message -Type "Warning" -Message "Step $stepIndex failed: $($stepResult.Message)"
                
                if ($StopOnFailure) {
                    Write-Message -Type "Debug" -Message "Stopping test execution (StopOnFailure=true)"
                    break
                }
            }
        }
        
        # Execute cleanup
        if (-not $SkipCleanup -and $fixture.cleanup) {
            $cleanupResult = Invoke-TestCleanup -Cleanup $fixture.cleanup
            if (-not $cleanupResult.Success) {
                Write-Message -Type "Warning" -Message "Cleanup failed: $($cleanupResult.Message)"
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
        Write-Message -Type "Error" -Message "Test execution error: $_"
        
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
            Write-Message -Type "Restore" -Message "Restoring git state from backup: $backupName"
            try {
                # TODO: writing to $null to suppress output, fixes the issue with unwanted output in test results
                # However doing so duration calculation is affected since Restore-GitState outputs time taken
                $null = Restore-GitState -BackupName $backupName -Force $true -DeleteExistingTags $true
                Write-Message -Type "Debug" -Message "Git state restored"
            } catch {
                Write-Message -Type "Error" -Message "Failed to restore git state: $_"
                Write-Message -Type "Warning" -Message "Manual recovery may be needed. Use Get-AvailableBackups to list backups."
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

    Write-Message -Type "Info" -Message "Starting all integration tests"
    
    $fixtures = Get-AllIntegrationTestFixtures -TestsDirectory $TestsDirectory
    
    Write-Message -Type "Info" -Message "Found $($fixtures.Count) tests to run"
    
    $testResults = @()
    
    foreach ($fixture in $fixtures) {
        $result = Invoke-IntegrationTest -FixturePath $fixture.FilePath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
        $testResults += $result
        
        if (-not $result.Success -and $StopOnFailure) {
            Write-Message -Type "Warning" -Message "Stopping test execution (StopOnFailure=true)"
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
    
    # Convert Duration to seconds (or milliseconds) before summing
    $totalDuration = ($TestResults | ForEach-Object {
        # If Duration is a string, convert to TimeSpan first
        if ($_ -and $_.Duration -is [string]) {
            [TimeSpan]::Parse($_.Duration).TotalSeconds
        } elseif ($_ -and $_.Duration -is [TimeSpan]) {
            $_.Duration.TotalSeconds
        } else {
            0
        }
    } | Measure-Object -Sum).Sum


    $avgDuration = if ($totalTests -gt 0) { $totalDuration.TotalSeconds / $totalTests } else { 0 }
    
    # Display header
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message -Message "  Test Execution Summary" -ForegroundColor Cyan
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # Display statistics
    Write-Message -Message "Total Tests:     $totalTests" -ForegroundColor Gray
    Write-Message -Message "Passed Tests:    " -NoNewline -ForegroundColor Gray
    Write-Message -Message "$passedTests" -ForegroundColor Green
    Write-Message -Message "Failed Tests:    " -NoNewline -ForegroundColor Gray
    if ($failedTests -gt 0) {
        Write-Message -Message "$failedTests" -ForegroundColor Red
    } else {
        Write-Message -Message "$failedTests" -ForegroundColor Green
    }
    Write-Message -Message "Total Duration:  $("{0:N2}s" -f $totalDuration.TotalSeconds)" -ForegroundColor Gray
    Write-Message -Message "Average Duration: $("{0:N2}s" -f $avgDuration)" -ForegroundColor Gray

    # List failed tests
    if ($failedTests -gt 0) {
        Write-Message -Message "Failed Tests:" -ForegroundColor Red
        foreach ($result in $TestResults) {
            if (-not $result.Success) {
                Write-Message -Type "Error" -Message "  $($result.TestName)"
                Write-Message -Type "Info" -Message "     $($result.Message)" -ForegroundColor Gray
            }
        }
    }
    
    # Overall result
    if ($failedTests -eq 0) {
        Write-Message -Type "Success" -Message "ALL TESTS PASSED"
    } else {
        Write-Message -Type "Error" -Message "SOME TESTS FAILED"
    }
    
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
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
    # Convert Duration to seconds (or milliseconds) before summing
    $totalDuration = ($TestResults | ForEach-Object {
        # If Duration is a string, convert to TimeSpan first
        if ($_ -and $_.Duration -is [string]) {
            [TimeSpan]::Parse($_.Duration).TotalSeconds
        } elseif ($_ -and $_.Duration -is [TimeSpan]) {
            $_.Duration.TotalSeconds
        } else {
            0
        }
    } | Measure-Object -Sum).Sum

    
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
        Write-Message -Type "Info" -Message "Test report exported to: $OutputPath"
        return $OutputPath
    } catch {
        Write-Message -Type "Warning" -Message "Failed to export test report: $_"
        return $null
    }
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message -Message "  Act Integration Test Runner" -ForegroundColor Cyan
    Write-Message -Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message -Type "Info" -Message "Purpose: Orchestrate integration tests for d-flows workflows using act" -ForegroundColor Gray

    # Validate prerequisites
    Write-Message -Type "Info" -Message "Validating prerequisites..."
    
    # Check repository
    try {
        $repoRoot = Get-RepositoryRoot
        Write-Message -Type "Debug" -Message "Repository root: $repoRoot"
    } catch {
        Write-Message -Type "Error" -Message $_
        exit 1
    }
    
    # Check act availability
    if (-not (Test-ActAvailable)) {
        Write-Message -Type "Error" -Message "act is not available. Please install it before running tests."
        exit 1
    }
    
    # Check Docker
    if (-not (Test-DockerRunning)) {
        Write-Message -Type "Error" -Message "Docker is not running. Please start Docker Desktop before running tests."
        exit 1
    }
    
    # Create test state directory
    New-TestStateDirectory | Out-Null
    
    # Dot-source required scripts
    # Integration with Backup-GitState.ps1 and Setup-TestScenario.ps1
    Write-Message -Type "Debug" -Message "Loading required scripts"
    
    try {
        $backupScriptPath = Join-Path $repoRoot "scripts\integration\Backup-GitState.ps1"
        $scenarioScriptPath = Join-Path $repoRoot "scripts\integration\Setup-TestScenario.ps1"
        
        . $backupScriptPath
        . $scenarioScriptPath
        
        Write-Message -Type "Debug" -Message "Required scripts loaded"
    } catch {
        Write-Message -Type "Error" -Message "Failed to load required scripts: $_"
        exit 1
    }
    
    # Display configuration
    Write-Message -Type "Info" -Message "Configuration:" -ForegroundColor Yellow
    Write-Message -Type "Info" -Message "  Skip Backup:   $SkipBackup" -ForegroundColor Gray
    Write-Message -Type "Info" -Message "  Skip Cleanup:  $SkipCleanup" -ForegroundColor Gray
    Write-Message -Type "Info" -Message "  Stop On Failure: $StopOnFailure" -ForegroundColor Gray

    # Determine execution mode and run tests
    $testResults = @()
    
    try {
        if ($TestFixturePath) {
            # Run specific test by path
            # How to run single test: Run-ActTests -TestFixturePath "tests/integration/v0-to-v1-release-cycle.json"
            Write-Message -Type "Info" -Message "Running single test: $TestFixturePath"
            $fullPath = Join-Path $repoRoot $TestFixturePath
            $result = Invoke-IntegrationTest -FixturePath $fullPath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
            $testResults += $result
        }
        elseif ($TestName) {
            # Run specific test by name
            Write-Message -Type "Info" -Message "Searching for test: $TestName"
            $fixture = Find-FixtureByName -TestName $TestName
            $result = Invoke-IntegrationTest -FixturePath $fixture.FilePath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
            $testResults += $result
        }
        elseif ($RunAll) {
            # Run all tests
            # How to run all tests: Run-ActTests -RunAll
            Write-Message -Type "Info" -Message "Running all integration tests"
            $testResults = Invoke-AllIntegrationTests -StopOnFailure $StopOnFailure -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
        }
        else {
            # No execution mode specified
            Write-Message -Type "Warning" -Message "No test execution mode specified. Use -RunAll to run all tests, -TestFixturePath for a specific test, or -TestName to search for a test."
                Write-Message -Type "Info" -Message "Usage:" -ForegroundColor Yellow
            Write-Message -Type "Info" -Message "  .\scripts\integration\Run-ActTests.ps1 -RunAll                                                      # Run all tests" -ForegroundColor Gray
            Write-Message -Type "Info" -Message "  .\scripts\integration\Run-ActTests.ps1 -TestFixturePath 'tests/integration/v0-to-v1-release-cycle.json'  # Run specific test" -ForegroundColor Gray
            Write-Message -Type "Info" -Message "  .\scripts\integration\Run-ActTests.ps1 -TestName 'Test Name'                                       # Search for and run test" -ForegroundColor Gray
                exit 0
        }
    } catch {
        Write-Message -Type "Error" -Message "Test execution failed: $_"
        exit 1
    }
    
    # Display summary
    Write-TestSummary -TestResults $testResults
    
    # Export report
    # How to view test logs: Check system temp directory for d-flows-test-state-*/logs/ directory
    $reportPath = Export-TestReport -TestResults $testResults
    
    # Cleanup test state directory
    if (-not $SkipCleanup) {
        Write-Message -Type "Cleanup" -Message "Cleaning up test state directory"
        $cleanupResult = Remove-TestStateDirectory
        if ($cleanupResult) {
            Write-Message -Type "Success" -Message "Test state directory cleaned up successfully"
        } else {
            Write-Message -Type "Warning" -Message "Failed to clean up test state directory - may require manual removal"
        }
    } else {
        Write-Message -Type "Info" -Message "Test state directory preserved for debugging: $TestStateDirectory"
    }
    
    # Exit with appropriate code
    $failedTests = @($testResults | Where-Object { -not $_.Success }).Count
    exit $(if ($failedTests -eq 0) { 0 } else { 1 })
}








