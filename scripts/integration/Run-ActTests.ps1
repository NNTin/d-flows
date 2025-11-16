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
    - Uses GitSnapshot module for git state backup/restore
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

$scriptDir = $PSScriptRoot
$integrationDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $integrationDir

# Add to PSModulePath only if not already present
$projectModules = Join-Path $root 'scripts\Modules'
$utilitiesModules = Join-Path $projectModules 'Utilities'
$testModules = Join-Path $projectModules 'Tests'

# Normalize paths (remove trailing backslashes)
$allModulePaths = @($projectModules, $utilitiesModules, $testModules) | ForEach-Object { $_.TrimEnd('\') }

# Unload any loaded module located in those folders or their subfolders
Get-Module | ForEach-Object {
    $modulePath = $_.ModuleBase.TrimEnd('\')
    foreach ($path in $allModulePaths) {
        # Add trailing backslash to ensure subfolder matches
        if ($modulePath -like "$path*") {
            Write-Host "Removing module $($_.Name) from $($_.ModuleBase)" -ForegroundColor Yellow
            try {
                Remove-Module -Name $_.Name -Force -ErrorAction Stop
            }
            catch {
                Write-Message -Type "Error" "Failed to remove module $($_.Name): $_"
            }
            break  # Module matched, no need to check other paths
        }
    }
}

# Function to prepend a path if missing
function Add-ToPSModulePath {
    param([string]$Path)
    $separator = [System.IO.Path]::PathSeparator  # ✅ Cross-platform: ; on Windows, : on Linux

    if (-not ($env:PSModulePath -split $separator | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $Path })) {
        $env:PSModulePath = "$Path$separator$env:PSModulePath"
    }
}

# Prepend both paths
Add-ToPSModulePath $utilitiesModules
Add-ToPSModulePath $projectModules
Add-ToPSModulePath $testModules

# PowerShell will auto-load them when their functions are called!
# Import-Module -Name (Join-Path $PSScriptRoot "../Modules/Utilities/MessageUtils") -ErrorAction Stop

# Import module explicitely because auto-load does not work for variables
Add-ToPSModulePath Join-Path $testModules "TestArtifacts"
Import-Module TestArtifacts -ErrorAction Stop

$ActCommand = Get-Command "act" | Select-Object -ExpandProperty Source

# ============================================================================
# Helper Functions
# ============================================================================

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
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = $TestStateDirectory
    )

    try {
        if (Test-Path $Path) {
            Write-Message -Type "Debug" "Removing test state directory: $Path"

            if ($PSCmdlet.ShouldProcess("$Path", "Remove-Item")) {
                Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            }
            Write-Message -Type "Debug" "Test state directory removed successfully"
            return $true
        }
        else {
            Write-Message -Type "Debug" "Test state directory does not exist: $Path"
            return $true
        }
    }
    catch {
        Write-Message -Type "Warning" "Failed to remove test state directory: $_"
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
        Write-Message -Type "Debug" "Converting path for Docker: $fullPath"

        # Detect if running on Windows
        $IsOnWindows = if ($PSVersionTable.PSVersion.Major -ge 6) {
            $IsWindows
        }
        else {
            [System.Environment]::OSVersion.Platform -eq "Win32NT"
        }

        if ($IsOnWindows) {
            # Handle UNC paths (network paths like \\server\share)
            if ($fullPath -match '^\\\\') {
                $dockerPath = $fullPath -replace '\\', '/' -replace '^//', '//'
                Write-Message -Type "Debug" "Converted UNC path to Docker format: $dockerPath"
                return $dockerPath
            }

            # Handle local drive paths (C:\, D:\, etc.)
            if ($fullPath -match '^([A-Z]):') {
                $driveLetter = [char]::ToLower([char]($matches[1]))
                $pathWithoutDrive = $fullPath.Substring(2)
                $dockerPath = "/$driveLetter$($pathWithoutDrive -replace '\\', '/')"
                Write-Message -Type "Debug" "Converted Windows path to Docker format: $dockerPath"
                return $dockerPath
            }

            throw "Unrecognized Windows path format: $fullPath"
        }
        else {
            # On Linux, path should already be in correct format
            Write-Message -Type "Debug" "Linux path already in Docker format: $fullPath"
            return $fullPath
        }
    }
    catch {
        Write-Message -Type "Error" "Failed to convert path to Docker format: $_"
        throw $_
    }
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

    Write-Message ""
    Write-Message "═══════════════════════════════════════════════════════════════════════"
    Write-Message -Type "Test" "$TestName"
    if ($TestDescription) {
        Write-Message -Type "Info" "   $TestDescription"
    }
    Write-Message "═══════════════════════════════════════════════════════════════════════"
    Write-Message ""

    Write-Message -Type "Debug" "Starting test: $TestName"
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

    $status = if ($Success) { "PASSED" } else { "FAILED" }

    $durationText = "{0:N2}s" -f $Duration.TotalSeconds

    Write-Message ""
    Write-Message "Test ${status}: $TestName ($durationText)"

    if ($Message) {
        Write-Message -Type "Info" "   $Message"
    }

    Write-Message ""
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

    Write-Message -Type "Debug" "Parsing fixture: $FixturePath"

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

        Write-Message -Type "Debug" "Parsed fixture: $($fixture.name) with $($fixture.steps.Count) steps"

        return $fixture
    }
    catch {
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
    Write-Message -Type "Info" "Found $($fixtures.Count) fixtures"

.NOTES
    Returns array of fixture objects with file paths.
#>
function Get-AllIntegrationTestFixtures {
    param(
        [Parameter(Mandatory = $false)]
        [string]$TestsDirectory = $IntegrationTestsDirectory
    )

    Write-Message -Type "Debug" "Scanning for fixtures in: $TestsDirectory"

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
        }
        catch {
            Write-Message -Type "Warning" "Failed to parse fixture '$($file.Name)': $_"
            continue
        }
    }

    Write-Message -Type "Debug" "Found $($fixtures.Count) valid fixtures"

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

    Write-Message -Type "Debug" "Searching for fixture with name: $TestName"

    $fixtures = Get-AllIntegrationTestFixtures -TestsDirectory $TestsDirectory

    $matchingFixture = $fixtures | Where-Object {
        $_.name -like "*$TestName*"
    } | Select-Object -First 1

    if (-not $matchingFixture) {
        throw "No fixture found matching name: $TestName"
    }

    Write-Message -Type "Debug" "Found fixture: $($matchingFixture.name)"

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
    if (Test-ActAvailable) { Write-Message -Type "Info" "act is available" }

.NOTES
    Returns $true if available, $false otherwise.
    Provides installation instructions if not found.
#>
function Test-ActAvailable {
    Write-Message -Type "Debug" "Checking if act is available"

    try {
        $actVersion = & $ActCommand --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Message -Type "Debug" "act version: $actVersion"
            return $true
        }
    }
    catch {
        Write-Message -Type "Error" "act not found. Install using: winget install nektos.act"
        return $false
    }

    Write-Message -Type "Error" "act not found. Install using: winget install nektos.act"
    return $false
}

<#
.SYNOPSIS
    Check if Docker is running.

.DESCRIPTION
    Executes 'docker ps' to verify Docker daemon is accessible.

.EXAMPLE
    if (Test-DockerRunning) { Write-Message -Type "Info" "Docker is running" }

.NOTES
    Returns $true if running, $false otherwise.
#>
function Test-DockerRunning {
    Write-Message -Type "Debug" "Checking if Docker is running"

    try {
        $dockerPs = docker ps 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Message -Type "Debug" "Docker is running"
            Write-Message -Type "Debug" "$dockerPs"
            return $true
        }
    }
    catch {
        Write-Message -Type "Error" "Docker is not running. Start Docker Desktop and try again."
        return $false
    }

    Write-Message -Type "Error" "Docker is not running. Start Docker Desktop and try again."
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

    Write-Message -Type "Workflow" "Preparing to run workflow: $WorkflowFile"

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

    $actArgs += "--env"
    $actArgs += "TOKEN_FALLBACK=${env:ACT_GITHUB_TOKEN}"

    $containerTestStatePath = "/tmp/test-state"
    $testStateEnvPath = if ($containerTestStatePath.EndsWith("/")) {
        $containerTestStatePath
    }
    else {
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
        Write-Message -Type "Debug" "Mounting volume: $TestStateDirectory -> $containerTestStatePath"
        Write-Message -Type "Debug" "Docker path: $dockerTestStatePath"

        $mountOption = "--mount type=bind,src=$dockerTestStatePath,dst=$containerTestStatePath"

        # Detect if running on Linux
        $isOnLinux = $IsLinux -or ($env:OS -ne "Windows_NT")

        if ($isOnLinux) {
            try {
                $hostUid = & id -u
                $hostGid = & id -g
                Write-Message -Type "Debug" "Running on Linux. Setting container user: $($hostUid):$($hostGid)"
                $mountOption += " --user $($hostUid):$($hostGid)"
            }
            catch {
                Write-Message -Type "Warning" "Failed to determine host UID/GID. Container may run as root."
            }
        }
        else {
            Write-Message -Type "Debug" "Running on Windows. Skipping --user option."
        }

        $actArgs += "--container-options"
        $actArgs += $mountOption
    }
    catch {
        Write-Message -Type "Warning" "Failed to convert test state path for Docker mount: $_"
        Write-Message -Type "Info" "Continuing without volume mount (workflows may not access test state)"
    }

    # Execute act and capture output
    $startTime = Get-Date

    try {
        Write-Message -Type "Debug" "ActCommand: $ActCommand"
        Write-Message -Type "Debug" "actArgs: $actArgs"
        if ($CaptureOutput) {
            $output = & $ActCommand @actArgs 2>&1 | Out-String
        }
        else {
            & $ActCommand @actArgs
            $output = ""
        }

        $exitCode = $LASTEXITCODE
        $endTime = Get-Date
        $duration = $endTime - $startTime

        Write-Message -Type "Debug" "Act execution completed in $($duration.TotalSeconds) seconds with exit code: $exitCode"

        # Parse outputs from workflow
        $outputs = Parse-ActOutput -Output $output

        return @{
            Success  = ($exitCode -eq 0)
            ExitCode = $exitCode
            Output   = $output
            Outputs  = $outputs
            Duration = $duration
        }
    }
    catch {
        Write-Message -Type "Error" "Act execution failed: $_"
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

    Write-Message -Type "Debug" "Parsing act output for OUTPUT: markers"

    $outputs = @{}
    $lines = $Output -split "`n"

    foreach ($line in $lines) {
        if ($line -match 'OUTPUT:\s*([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $outputs[$key] = $value
            Write-Message -Type "Debug" "Found output: $key = $value"
        }
    }

    Write-Message -Type "Debug" "Parsed $($outputs.Count) outputs"

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
    Write-Message -Type "Validation" "Executing validation: $checkType"

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
                    "version-greater", "version-progression", "major-increment",
                    "major-tags-coexist", "major-tag-progression", "no-cross-contamination",
                    "no-tag-conflicts", "workflow-success", "workflow-failure", "idempotency-verified"
                )
                throw "Unknown validation type: $checkType. Supported types: $($supportedTypes -join ', ')"
            }
        }
    }
    catch {
        return @{
            Success = $false
            Message = "Validation error: $_"
            Type    = $checkType
        }
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
    Integration with Setup-TestScenario.ps1: Call Invoke-TestScenario for "setup-git-state" steps.

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

    Write-Message -Type "Debug" "Applying scenario: $scenario"

    try {
        # Call Invoke-TestScenario from Setup-TestScenario.ps1
        $result = Invoke-TestScenario -ScenarioName $scenario -CleanState $true -Force $true -GenerateTestTagsFile $true

        if (-not $result.Success) {
            return @{
                Success         = $false
                Message         = "Failed to apply scenario '$scenario': $($result.Message)"
                ScenarioApplied = $scenario
                State           = $result
            }
        }

        Write-Message -Type "Debug" "Scenario '$scenario' applied successfully"

        return @{
            Success         = $true
            Message         = "Scenario '$scenario' applied successfully"
            ScenarioApplied = $scenario
            State           = $result
        }
    }
    catch {
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

    Write-Message -Type "Workflow" "Running workflow: $workflow with fixture: $fixture"

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
            }
            else {
                $messages += "Workflow failed as expected"
            }
        }
        else {
            if (-not $actResult.Success) {
                $success = $false
                $messages += "Expected workflow to succeed, but it failed (exit code: $($actResult.ExitCode))"
            }
            else {
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
                }
                else {
                    $messages += "Output matched: $key = '$actualValue'"
                }
            }
        }

        Write-Message -Type "Debug" "Workflow execution result: $success"

        # Update test state files after workflow execution
        Write-Message -Type "Debug" "Updating test state files after workflow execution"

        # Calculate test-only tags (exclude production tags)
        $productionTags = if ($TestContext -and $TestContext.ProductionTags) { $TestContext.ProductionTags } else { @() }
        $allCurrentTags = @(git tag -l)
        $testTags = @($allCurrentTags | Where-Object { $_ -notin $productionTags })
        Write-Message -Type "Debug" "Filtering tags: $($allCurrentTags.Count) total, $($productionTags.Count) production, $($testTags.Count) test tags to export"

        # Get all current branches
        $allCurrentBranches = @(git branch -l | ForEach-Object { $_.TrimStart('*').Trim() } | Where-Object { $_ -and $_ -notmatch '^\(HEAD' })
        Write-Message -Type "Debug" "Found $($allCurrentBranches.Count) branches to export"

        # Export current tags to test-tags.txt (only test tags)
        try {
            $tagsOutputPath = Export-TestTagsFile -Tags $testTags -OutputPath (Join-Path $TestStateDirectory "test-tags.txt")
            Write-Message -Type "Debug" "Test tags file updated: $tagsOutputPath"
        }
        catch {
            Write-Message -Type "Warning" "Failed to update test-tags.txt: $_"
        }

        # Export current branches to test-branches.txt
        try {
            $branchesOutputPath = Export-TestBranchesFile -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory "test-branches.txt")
            Write-Message -Type "Debug" "Test branches file updated: $branchesOutputPath"
        }
        catch {
            Write-Message -Type "Warning" "Failed to update test-branches.txt: $_"
        }

        # Export commit bundle to test-commits.bundle (only commits referenced by test tags and branches)
        try {
            $bundleOutputPath = Export-TestCommitsBundle -Tags $testTags -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory $TestCommitsBundle)
            Write-Message -Type "Debug" "Test commits bundle updated: $bundleOutputPath"
        }
        catch {
            Write-Message -Type "Warning" "Failed to update test-commits.bundle: $_"
        }

        Write-Message -Type "Debug" "Test state synchronization completed"

        return @{
            Success           = $success
            Message           = $messages -join '; '
            ActResult         = $actResult
            OutputsMatched    = $outputsMatched
            ErrorMessageFound = $errorMessageFound
        }
    }
    catch {
        return @{
            Success           = $false
            Message           = "Error running workflow '$workflow': $_"
            ActResult         = $null
            OutputsMatched    = $false
            ErrorMessageFound = $false
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

    Write-Message -Type "Validation" "Performing $($checks.Count) validation checks"

    # Extract ActResult from test context if available
    $lastActResult = $null
    if ($TestContext -and $TestContext.ContainsKey('LastActResult')) {
        $lastActResult = $TestContext.LastActResult
        Write-Message -Type "Debug" "Using ActResult from test context"
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
            }
            else {
                $failedCount++
                Write-Message -Type "Warning" "Validation failed: $($result.Message)"
            }
        }
        catch {
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

    Write-Message -Type "Debug" "$message"

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
    Write-Message -Type "Debug" "Exit code: $($result.ExitCode)"
    Write-Message -Type "Info" "Output: $($result.Output)"

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
    $argsCommand = @()
    if ($tokens.Count -gt 1) {
        $argsCommand = $tokens[1..($tokens.Count - 1)] | ForEach-Object { $_.Content }
    }

    if ($VerboseOutput) {
        Write-Message -Type "Debug" "Executing: $exe $($argsCommand -join ' ')"
    }

    # Execute command, capture stdout + stderr
    $output = & $exe @argsCommand 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($VerboseOutput) {
        Write-Message -Type "Debug" "Exit code: $exitCode"
        Write-Message -Type "Debug" "Output: $output"
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

    # Make .git writable on Linux/macOS, skip on Windows
    if (-not $IsWindows) {
        Write-Message -Type Debug "Detected non-Windows OS. Setting write permissions for .git directory..."
        chmod -R u+w .git
    }
    else {
        Write-Message -Type Debug "Windows OS detected. Skipping chmod."
    }

    Write-Message -Type "Debug" "Executing command: $command"

    try {
        $result = Run-Command $command -VerboseOutput

        $output = $($result.Output)
        $exitCode = $($result.ExitCode)

        $success = ($exitCode -eq 0)

        Write-Message -Type "Debug" "Command completed with exit code: $exitCode"

        # Update test state files after command execution
        Write-Message -Type "Debug" "Updating test state files after command execution"

        # Calculate test-only tags (exclude production tags)
        $productionTags = if ($TestContext -and $TestContext.ProductionTags) { $TestContext.ProductionTags } else { @() }
        $allCurrentTags = @(git tag -l)
        $testTags = @($allCurrentTags | Where-Object { $_ -notin $productionTags })
        Write-Message -Type "Debug" "Filtering tags: $($allCurrentTags.Count) total, $($productionTags.Count) production, $($testTags.Count) test tags to export"

        # Get all current branches
        $allCurrentBranches = @(git branch -l | ForEach-Object { $_.TrimStart('*').Trim() } | Where-Object { $_ -and $_ -notmatch '^\(HEAD' })
        Write-Message -Type "Debug" "Found $($allCurrentBranches.Count) branches to export"

        # Export current tags to test-tags.txt (only test tags)
        try {
            $tagsOutputPath = Export-TestTagsFile -Tags $testTags -OutputPath (Join-Path $TestStateDirectory "test-tags.txt")
            Write-Message -Type "Debug" "Test tags file updated: $tagsOutputPath"
        }
        catch {
            Write-Message -Type "Warning" "Failed to update test-tags.txt: $_"
        }

        # Export current branches to test-branches.txt
        try {
            $branchesOutputPath = Export-TestBranchesFile -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory "test-branches.txt")
            Write-Message -Type "Debug" "Test branches file updated: $branchesOutputPath"
        }
        catch {
            Write-Message -Type "Warning" "Failed to update test-branches.txt: $_"
        }

        # Export commit bundle to test-commits.bundle (only commits referenced by test tags and branches)
        try {
            $bundleOutputPath = Export-TestCommitsBundle -Tags $testTags -Branches $allCurrentBranches -OutputPath (Join-Path $TestStateDirectory $TestCommitsBundle)
            Write-Message -Type "Debug" "Test commits bundle updated: $bundleOutputPath"
        }
        catch {
            Write-Message -Type "Warning" "Failed to update test-commits.bundle: $_"
        }

        Write-Message -Type "Debug" "Test state synchronization completed"

        return @{
            Success  = $success
            Message  = if ($success) { "Command succeeded" } else { "Command failed with exit code: $exitCode" }
            Output   = $output
            ExitCode = $exitCode
        }
    }
    catch {
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

    Write-Message -Type "Info" $text

    return @{
        Success = $true
        Message = $text
        Skip    = $skip
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

    Write-Message -Type "Debug" "Executing step $StepIndex ($action)"

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

        Write-Message -Type "Debug" "Step $StepIndex completed: $($result.Success)"

        return $result
    }
    catch {
        Write-Message -Type "Error" "Step $StepIndex failed: $_"
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

    Write-Message -Type "Cleanup" "Executing cleanup: $action"

    try {
        if ($action -eq "reset-git-state") {
            # Call Clear-GitState from Setup-TestScenario.ps1
            Clear-GitState -DeleteTags $true -DeleteBranches $true

            Write-Message -Type "Debug" "Cleanup completed"

            return @{
                Success = $true
                Message = "Git state reset successfully"
            }
        }
        else {
            return @{
                Success = $true
                Message = "Unknown cleanup action: $action (skipped)"
            }
        }
    }
    catch {
        Write-Message -Type "Warning" "Cleanup failed: $_"
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
    Integration: Uses GitSnapshot module for state preservation, Setup-TestScenario for scenario application.
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

        Write-Message -Type "Debug" "Test configuration: SkipBackup=$SkipBackup, SkipCleanup=$SkipCleanup"

        # Initialize test execution context for sharing state between steps
        $testContext = @{ LastActResult = $null; ProductionTags = @() }
        Write-Message -Type "Debug" "Initialized test execution context (tracking production tags)"

        # Backup git state
        # Integration with GitSnapshot module: Call Backup-GitState before each test
        if (-not $SkipBackup) {
            Write-Message -Type "Debug" "Backing up git state"
            $backup = Backup-GitState
            $backupName = $backup.BackupName
            Write-Message -Type "Debug" "Backup created: $backupName"
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
                Write-Message -Type "Debug" "Stored ActResult in test context for step $stepIndex"
            }

            # Store production tags if this was a setup-git-state step
            if ($step.action -eq 'setup-git-state' -and $stepResult.State -and $stepResult.State.ProductionTagsDeleted) {
                $testContext.ProductionTags = $stepResult.State.ProductionTagsDeleted
                Write-Message -Type "Debug" "Captured $($testContext.ProductionTags.Count) production tags from setup-git-state step"
            }

            if ($step.Skip) {
                # for tests we only have two states: success and failure
                # future todo to have "skipped" state, for now treat as success but log as skipped
                Write-Message -Type "Warning" "Step $stepIndex is skipping test execution"
                break
            }

            if (-not $stepResult.Success) {
                $allStepsPassed = $false
                Write-Message -Type "Warning" "Step $stepIndex failed: $($stepResult.Message)"

                if ($StopOnFailure) {
                    Write-Message -Type "Debug" "Stopping test execution (StopOnFailure=true)"
                    break
                }
            }
        }

        # Execute cleanup
        if (-not $SkipCleanup -and $fixture.cleanup) {
            $cleanupResult = Invoke-TestCleanup -Cleanup $fixture.cleanup
            if (-not $cleanupResult.Success) {
                Write-Message -Type "Warning" "Cleanup failed: $($cleanupResult.Message)"
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

    }
    catch {
        Write-Message -Type "Error" "Test execution error: $_"

        return @{
            TestName    = if ($fixture) { $fixture.name } else { "Unknown" }
            Success     = $false
            Duration    = (Get-Date) - $testStartTime
            StepResults = $stepResults
            Message     = "Test execution error: $_"
        }
    }
    finally {
        # Restore git state
        # Integration with GitSnapshot module: Call Restore-GitState after each test
        if (-not $SkipBackup -and $backupName) {
            Write-Message -Type "Restore" "Restoring git state from backup: $backupName"
            try {
                # TODO: writing to $null to suppress output, fixes the issue with unwanted output in test results
                # However doing so duration calculation is affected since Restore-GitState outputs time taken
                $null = Restore-GitState -BackupName $backupName -Force $true -DeleteExistingTags $true
                Write-Message -Type "Debug" "Git state restored"
            }
            catch {
                Write-Message -Type "Error" "Failed to restore git state: $_"
                Write-Message -Type "Warning" "Manual recovery may be needed. Use Get-AvailableBackups to list backups."
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

    Write-Message -Type "Info" "Starting all integration tests"

    $fixtures = Get-AllIntegrationTestFixtures -TestsDirectory $TestsDirectory

    Write-Message -Type "Info" "Found $($fixtures.Count) tests to run"

    $testResults = @()

    foreach ($fixture in $fixtures) {
        $result = Invoke-IntegrationTest -FixturePath $fixture.FilePath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
        $testResults += $result

        if (-not $result.Success -and $StopOnFailure) {
            Write-Message -Type "Warning" "Stopping test execution (StopOnFailure=true)"
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
            }
            elseif ($_ -and $_.Duration -is [TimeSpan]) {
                $_.Duration.TotalSeconds
            }
            else {
                0
            }
        } | Measure-Object -Sum).Sum


    $avgDuration = if ($totalTests -gt 0) { $totalDuration / $totalTests } else { 0 }

    # Display header
    Write-Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message "  Test Execution Summary" -ForegroundColor Cyan
    Write-Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # Display statistics
    Write-Message "Total Tests:     $totalTests" -ForegroundColor Gray
    Write-Message "Passed Tests:    " -NoNewline -ForegroundColor Gray
    Write-Message "$passedTests" -ForegroundColor Green
    Write-Message "Failed Tests:    " -NoNewline -ForegroundColor Gray
    if ($failedTests -gt 0) {
        Write-Message "$failedTests" -ForegroundColor Red
    }
    else {
        Write-Message "$failedTests" -ForegroundColor Green
    }
    Write-Message "Total Duration:  $("{0:N2}s" -f $totalDuration)" -ForegroundColor Gray
    Write-Message "Average Duration: $("{0:N2}s" -f $avgDuration)" -ForegroundColor Gray

    # List failed tests
    if ($failedTests -gt 0) {
        Write-Message "Failed Tests:" -ForegroundColor Red
        foreach ($result in $TestResults) {
            if (-not $result.Success) {
                Write-Message -Type "Error" "  $($result.TestName)"
                Write-Message -Type "Info" "     $($result.Message)" -ForegroundColor Gray
            }
        }
    }

    # Overall result
    if ($failedTests -eq 0) {
        Write-Message -Type "Success" "ALL TESTS PASSED"
    }
    else {
        Write-Message -Type "Error" "SOME TESTS FAILED"
    }

    Write-Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message "  Act Integration Test Runner" -ForegroundColor Cyan
    Write-Message "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Message -Type "Info" "Purpose: Orchestrate integration tests for d-flows workflows using act" -ForegroundColor Gray

    # Validate prerequisites
    Write-Message -Type "Info" "Validating prerequisites..."

    # Check repository
    try {
        $repoRoot = Get-RepositoryRoot
        Write-Message -Type "Debug" "Repository root: $repoRoot"
    }
    catch {
        Write-Message -Type "Error" $_
        exit 1
    }

    # Check act availability
    if (-not (Test-ActAvailable)) {
        Write-Message -Type "Error" "act is not available. Please install it before running tests."
        exit 1
    }

    # Check Docker
    if (-not (Test-DockerRunning)) {
        Write-Message -Type "Error" "Docker is not running. Please start Docker Desktop before running tests."
        exit 1
    }

    # Create test state directory
    New-TestStateDirectory | Out-Null

    # Dot-source required scripts
    # Integration with GitSnapshot module and Setup-TestScenario.ps1
    Write-Message -Type "Debug" "Loading required scripts"

    try {
        $scenarioScriptPath = Join-Path $repoRoot "scripts\integration\Setup-TestScenario.ps1"

        . $scenarioScriptPath

        Write-Message -Type "Debug" "Required scripts loaded"
    }
    catch {
        Write-Message -Type "Error" "Failed to load required scripts: $_"
        exit 1
    }

    # Display configuration
    Write-Message -Type "Info" "Configuration:" -ForegroundColor Yellow
    Write-Message -Type "Info" "  Skip Backup:   $SkipBackup" -ForegroundColor Gray
    Write-Message -Type "Info" "  Skip Cleanup:  $SkipCleanup" -ForegroundColor Gray
    Write-Message -Type "Info" "  Stop On Failure: $StopOnFailure" -ForegroundColor Gray

    # Determine execution mode and run tests
    $testResults = @()

    try {
        if ($TestFixturePath) {
            # Run specific test by path
            # How to run single test: Run-ActTests -TestFixturePath "tests/integration/v0-to-v1-release-cycle.json"
            Write-Message -Type "Info" "Running single test: $TestFixturePath"
            $fullPath = Join-Path $repoRoot $TestFixturePath
            $result = Invoke-IntegrationTest -FixturePath $fullPath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
            $testResults += $result
        }
        elseif ($TestName) {
            # Run specific test by name
            Write-Message -Type "Info" "Searching for test: $TestName"
            $fixture = Find-FixtureByName -TestName $TestName
            $result = Invoke-IntegrationTest -FixturePath $fixture.FilePath -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
            $testResults += $result
        }
        elseif ($RunAll) {
            # Run all tests
            # How to run all tests: Run-ActTests -RunAll
            Write-Message -Type "Info" "Running all integration tests"
            $testResults = Invoke-AllIntegrationTests -StopOnFailure $StopOnFailure -SkipBackup $SkipBackup -SkipCleanup $SkipCleanup
        }
        else {
            # No execution mode specified
            Write-Message -Type "Warning" "No test execution mode specified. Use -RunAll to run all tests, -TestFixturePath for a specific test, or -TestName to search for a test."
            Write-Message -Type "Info" "Usage:" -ForegroundColor Yellow
            Write-Message -Type "Info" "  .\scripts\integration\Run-ActTests.ps1 -RunAll                                                      # Run all tests" -ForegroundColor Gray
            Write-Message -Type "Info" "  .\scripts\integration\Run-ActTests.ps1 -TestFixturePath 'tests/integration/v0-to-v1-release-cycle.json'  # Run specific test" -ForegroundColor Gray
            Write-Message -Type "Info" "  .\scripts\integration\Run-ActTests.ps1 -TestName 'Test Name'                                       # Search for and run test" -ForegroundColor Gray
            exit 0
        }
    }
    catch {
        Write-Message -Type "Error" "Test execution failed: $_"
        exit 1
    }

    # Display summary
    Write-TestSummary -TestResults $testResults

    # Write test statistics to GITHUB_OUTPUT for downstream jobs
    if ($env:GITHUB_OUTPUT) {
        try {
            Write-Message -Type "Info" -Message "Writing test statistics to GITHUB_OUTPUT"

            # Calculate statistics from test results
            $totalTests = $testResults.Count
            $passedTests = @($testResults | Where-Object { $_.Success }).Count
            $failedTests = $totalTests - $passedTests

            # Convert Duration to seconds before summing
            $totalDuration = ($testResults | ForEach-Object {
                    # If Duration is a string, convert to TimeSpan first
                    if ($_ -and $_.Duration -is [string]) {
                        [TimeSpan]::Parse($_.Duration).TotalSeconds
                    }
                    elseif ($_ -and $_.Duration -is [TimeSpan]) {
                        $_.Duration.TotalSeconds
                    }
                    else {
                        0
                    }
                } | Measure-Object -Sum).Sum

            # Calculate average duration (fix bug: $totalDuration is already in seconds, not TimeSpan)
            $avgDuration = if ($totalTests -gt 0) { $totalDuration / $totalTests } else { 0 }

            # Write statistics to GITHUB_OUTPUT
            "total_tests=$totalTests" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
            "passed_tests=$passedTests" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
            "failed_tests=$failedTests" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
            "total_duration=$("{0:N2}" -f $totalDuration)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
            "average_duration=$("{0:N2}" -f $avgDuration)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

            Write-Message -Type "Success" -Message "Test statistics written to GITHUB_OUTPUT"
        }
        catch {
            Write-Message -Type "Warning" -Message "Failed to write to GITHUB_OUTPUT: $_"
        }
    }
    else {
        Write-Message -Type "Debug" "GITHUB_OUTPUT not set; skipping writing test statistics to GitHub Actions output"
    }

    # Export report
    # How to view test logs: Check system temp directory for d-flows-test-state-*/logs/ directory
    Export-TestReport -TestResults $testResults

    # Cleanup test state directory
    if (-not $SkipCleanup) {
        Write-Message -Type "Cleanup" "Cleaning up test state directory"
        $cleanupResult = Remove-TestStateDirectory
        if ($cleanupResult) {
            Write-Message -Type "Success" "Test state directory cleaned up successfully"
        }
        else {
            Write-Message -Type "Warning" "Failed to clean up test state directory - may require manual removal"
        }
    }
    else {
        Write-Message -Type "Info" "Test state directory preserved for debugging: $TestStateDirectory"
    }

    # Exit with appropriate code
    $failedTests = @($testResults | Where-Object { -not $_.Success }).Count
    exit $(if ($failedTests -eq 0) { 0 } else { 1 })
}
