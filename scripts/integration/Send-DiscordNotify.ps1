<#
.SYNOPSIS
    Test Discord notification workflows locally using act.

.DESCRIPTION
    This script executes Discord notification workflow tests using act (nektos/act) in Docker containers.
    It manages the complete test lifecycle including:

    - Discovering test fixtures from JSON files in tests/discord-notify/
    - Validating webhook URL configuration (from parameter or .secrets file)
    - Invoking the discord-notify workflow with act for each fixture
    - Capturing workflow output and exit codes
    - Reporting detailed test results with pass/fail status
    - Providing summary statistics for all executed tests

    Test fixtures are JSON files containing input parameters for the discord-notify workflow.
    The workflow requires a Discord webhook URL secret for execution.

.PARAMETER TestFixturePath
    Path to a specific test fixture JSON file to run (optional).
    When provided, only that single fixture is tested.
    Example: "tests/discord-notify/minimal-message.json"

.PARAMETER WebhookUrl
    Discord webhook URL to use for testing (optional).
    If provided, overrides the webhook URL from .secrets file.
    Format: https://discord.com/api/webhooks/{id}/{token}
    When not provided, script attempts to read from .secrets file.

.PARAMETER SkipCleanup
    Skip cleanup of temporary directories (for debugging).
    Default: $false. Preserves test artifacts for inspection when specified.

.EXAMPLE
    # Test all Discord notification fixtures
    .\scripts\integration\Send-DiscordNotify.ps1

.EXAMPLE
    # Test a specific fixture
    .\scripts\integration\Send-DiscordNotify.ps1 -TestFixturePath "tests/discord-notify/minimal-message.json"

.EXAMPLE
    # Test with custom webhook URL
    .\scripts\integration\Send-DiscordNotify.ps1 -WebhookUrl "https://discord.com/api/webhooks/123456/abcdef"

.EXAMPLE
    # Debug mode: preserve temporary directories
    .\scripts\integration\Send-DiscordNotify.ps1 -SkipCleanup

.NOTES
    Requirements:
    - act must be installed (Install: winget install nektos.act)
    - Docker must be running (Docker Desktop or equivalent)
    - Repository must be in a git repository
    - Discord webhook URL must be configured (via parameter or .secrets file)

    Webhook Configuration:
    - Webhook URL can be provided via -WebhookUrl parameter
    - Or read from .secrets file in repository root
    - .secrets file should contain: webhook_url=https://discord.com/api/webhooks/...
    - Template available in .secrets.template

    Test Fixtures:
    - Located in tests/discord-notify/ directory
    - JSON files with "inputs" object containing workflow parameters
    - Subdirectories like payload/ are automatically excluded from testing

    Output Format:
    - Detailed test results with pass/fail status
    - Colored output with emoji indicators
    - Summary statistics showing total, passed, and failed tests
    - Exit code 0 if all tests passed, 1 if any failed
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TestFixturePath,

    [Parameter(Mandatory = $false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup
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

# Normalize paths (remove trailing backslashes)
$allModulePaths = @($projectModules, $utilitiesModules) | ForEach-Object { $_.TrimEnd('\') }

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
                Write-Error "Failed to remove module $($_.Name): $_"
            }
            break
        }
    }
}

# Function to prepend a path if missing
function Add-ToPSModulePath {
    param([string]$Path)
    $separator = [System.IO.Path]::PathSeparator

    if (-not ($env:PSModulePath -split $separator | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $Path })) {
        $env:PSModulePath = "$Path$separator$env:PSModulePath"
    }
}

# Prepend paths
Add-ToPSModulePath $utilitiesModules
Add-ToPSModulePath $projectModules

# Import RepositoryUtils module explicitly to ensure Get-RepositoryRoot is available
Import-Module RepositoryUtils -ErrorAction Stop

# Get act command location
try {
    $ActCommand = Get-Command "act" | Select-Object -ExpandProperty Source
}
catch {
    Write-Error "❌ act command not found. Please install act: winget install nektos.act"
    exit 1
}

# ============================================================================
# Helper Functions
# ============================================================================

<#
.SYNOPSIS
    Discover all Discord notification test fixtures.

.DESCRIPTION
    Scans the tests/discord-notify/ directory for JSON test fixtures.
    Returns array of fixture file paths, excluding subdirectories like payload/.
    Fixtures should be in the format: "*.json" and located in the root of tests/discord-notify/.

.PARAMETER FixturesPath
    Path to the fixtures directory. Defaults to "tests/discord-notify/"

.EXAMPLE
    $fixtures = Get-DiscordNotifyFixtures
    $fixtures | ForEach-Object { Write-Host $_ }

.NOTES
    Subdirectories within tests/discord-notify/ are automatically excluded.
    Returns array of full paths to JSON fixture files.
#>
function Get-DiscordNotifyFixtures {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$FixturesPath = "tests/discord-notify"
    )

    $fullPath = Join-Path (Get-Location) $FixturesPath

    if (-not (Test-Path $fullPath)) {
        Write-Message -Type "Error" "Fixtures directory not found: $fullPath"
        return @()
    }

    $fixtures = @(Get-ChildItem -Path $fullPath -File -Filter "*.json" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)

    Write-Message -Type "Debug" "Found $($fixtures.Count) Discord notification fixtures"

    return $fixtures
}

<#
.SYNOPSIS
    Extract Discord webhook URL from configuration.

.DESCRIPTION
    Retrieves webhook URL from:
        1. ProvidedUrl parameter
        2. .secrets file in repository root
        3. Environment variable WEBHOOK_URL
    Returns $null if no webhook URL is configured.
    Uses Write-Message for debug logging about where URL was sourced.

.PARAMETER ProvidedUrl
    Optional webhook URL provided as parameter (takes precedence over others)

.PARAMETER RepositoryRoot
    Path to repository root for locating .secrets file

.EXAMPLE
    $url = Get-WebhookUrl -RepositoryRoot "C:\repos\d-flows"

.EXAMPLE
    $url = Get-WebhookUrl -ProvidedUrl "https://discord.com/api/webhooks/..."

.NOTES
    Priority order:
    1. ProvidedUrl parameter (if not empty)
    2. .secrets file in repository root
    3. Environment variable WEBHOOK_URL
    4. Returns $null if not found

    Format expected in .secrets file:
        webhook_url=https://discord.com/api/webhooks/...
#>
function Get-WebhookUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProvidedUrl,

        [Parameter(Mandatory = $false)]
        [string]$RepositoryRoot = (Get-Location)
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedUrl)) {
        Write-Message -Type "Debug" "Using webhook URL from parameter"
        return $ProvidedUrl
    }

    $secretsPath = Join-Path $RepositoryRoot ".secrets"
    if (Test-Path $secretsPath) {
        try {
            $secretsContent = Get-Content $secretsPath -Raw
            if ($secretsContent -match 'webhook_url=(.+?)(?:`n|$)') {
                $url = $matches[1].Trim()
                if (-not [string]::IsNullOrWhiteSpace($url)) {
                    Write-Message -Type "Debug" "Using webhook URL from .secrets file"
                    return $url
                }
            }
        }
        catch {
            Write-Message -Type "Warning" "Failed to read .secrets file: $_"
        }
    }

    $envUrl = $env:WEBHOOK_URL
    if (-not [string]::IsNullOrWhiteSpace($envUrl)) {
        Write-Message -Type "Debug" "Using webhook URL from environment variable WEBHOOK_URL"
        return $envUrl
    }

    Write-Message -Type "Debug" "No webhook URL found in parameter, .secrets file, or environment variable"
    return $null
}

<#
.SYNOPSIS
    Invoke discord-notify workflow with a specific test fixture.

.DESCRIPTION
    Executes the discord-notify GitHub workflow using act with the specified fixture.
    Captures output and exit code, returning detailed result information.

    The fixture JSON file should contain an "inputs" object with workflow parameters.
    Webhook URL is provided as a secret to the workflow.

.PARAMETER FixturePath
    Full path to the JSON fixture file

.PARAMETER WebhookUrl
    Discord webhook URL to provide as secret (may be $null for no-webhook tests)

.EXAMPLE
    $result = Invoke-DiscordNotifyTest -FixturePath "tests/discord-notify/minimal-message.json" -WebhookUrl "https://discord.com/api/webhooks/..."
    if ($result.Success) { Write-Host "Test passed" }

.NOTES
    Returns hashtable with keys:
    - Success (boolean): $true if exit code is 0
    - ExitCode (int): Exit code from act execution
    - Output (string): Complete stdout/stderr output from act
    - FixtureName (string): Base name of fixture file

    Workflow is invoked via act with:
    - Event: workflow_dispatch
    - Workflow file: tests/local-workflows/discord-notify-act.yml
    - Job: send-notification
    - Environment: ACT=true (for workflow detection)
    - Fixture: Provided via -e parameter
    - Secret: webhook_url (if provided)
#>
function Invoke-DiscordNotifyTest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FixturePath,

        [Parameter(Mandatory = $false)]
        [string]$WebhookUrl
    )

    $fixtureName = Split-Path -Leaf $FixturePath

    # Build act command arguments
    $actArgs = @(
        "workflow_dispatch",
        "-W", "tests/local-workflows/discord-notify-act.yml",
        "-e", $FixturePath,
        "--job", "send-notification",
        "--env", "ACT=true"
    )

    # Add webhook URL as secret if provided
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        $actArgs += "--secret"
        $actArgs += "webhook_url=$WebhookUrl"
    }

    Write-Message -Type "Debug" "ActCommand: $ActCommand"
    Write-Message -Type "Debug" "ActArgs: $actArgs"

    # Execute act and capture output
    $startTime = Get-Date

    try {
        $output = & $ActCommand @actArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $endTime = Get-Date
        $duration = $endTime - $startTime

        Write-Message -Type "Debug" "Execution completed in $($duration.TotalSeconds) seconds with exit code: $exitCode"

        return @{
            Success     = ($exitCode -eq 0)
            ExitCode    = $exitCode
            Output      = $output
            FixtureName = $fixtureName
            Duration    = $duration
        }
    }
    catch {
        Write-Message -Type "Error" "Act execution failed: $_"
        return @{
            Success     = $false
            ExitCode    = -1
            Output      = $_.Exception.Message
            FixtureName = $fixtureName
            Duration    = $null
        }
    }
}

<#
.SYNOPSIS
    Execute all Discord notification test fixtures.

.DESCRIPTION
    Discovers all fixtures using Get-DiscordNotifyFixtures, obtains webhook URL,
    and iterates through each fixture executing tests with Invoke-DiscordNotifyTest.

    For each fixture, displays test header and result status.
    Collects all results and returns array for summary reporting.

.PARAMETER WebhookUrl
    Optional webhook URL to override .secrets file configuration

.EXAMPLE
    $results = Invoke-AllDiscordNotifyTests
    $results | ForEach-Object { Write-Host "$($_.FixtureName): $($_.ExitCode)" }

.NOTES
    Returns array of hashtables from Invoke-DiscordNotifyTest.
    Each fixture is tested independently (failures don't stop subsequent tests).
    Displays "INFO" message before each test and "Success" or "Error" after.
#>
function Invoke-AllDiscordNotifyTests {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$WebhookUrl
    )

    $fixtures = Get-DiscordNotifyFixtures

    if ($fixtures.Count -eq 0) {
        Write-Message -Type "Warning" "No test fixtures found in tests/discord-notify/"
        return @()
    }

    $webhookUrl = Get-WebhookUrl -ProvidedUrl $WebhookUrl
    $results = @()

    foreach ($fixture in $fixtures) {
        $fixtureName = Split-Path -Leaf $fixture
        Write-Message -Type "Info" "Testing fixture: $fixtureName"

        $result = Invoke-DiscordNotifyTest -FixturePath $fixture -WebhookUrl $webhookUrl
        $results += $result

        if ($result.Success) {
            Write-Message -Type "Success" "Fixture passed: $fixtureName"
        }
        else {
            Write-Message -Type "Error" "Fixture failed: $fixtureName (exit code: $($result.ExitCode))"
        }
    }

    return $results
}

<#
.SYNOPSIS
    Generate and display test summary report.

.DESCRIPTION
    Accepts array of test results, calculates pass/fail statistics,
    and displays formatted summary with detailed information about failures.

    Summary includes:
    - Total number of tests
    - Number of passed tests
    - Number of failed tests
    - Overall pass rate percentage
    - List of failed fixtures with exit codes

.PARAMETER TestResults
    Array of hashtables from Invoke-DiscordNotifyTest or Invoke-AllDiscordNotifyTests

.EXAMPLE
    $results = Invoke-AllDiscordNotifyTests
    $allPassed = Write-TestSummary -TestResults $results
    exit $(if ($allPassed) { 0 } else { 1 })

.NOTES
    Returns $true if all tests passed (100% pass rate), $false otherwise.
    Displays summary using Write-Message with "Info", "Success", or "Error" types.
    Failed fixtures are listed with their exit codes for troubleshooting.
#>
function Write-TestSummary {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable[]]$TestResults
    )

    if ($null -eq $TestResults -or $TestResults.Count -eq 0) {
        Write-Message -Type "Warning" "No test results to summarize"
        return $true
    }

    $totalTests = $TestResults.Count
    $passedTests = @($TestResults | Where-Object { $_.Success }).Count
    $failedTests = $totalTests - $passedTests
    $passRate = [math]::Round(($passedTests / $totalTests) * 100, 2)

    Write-Message -Type "Info" "═"
    Write-Message -Type "Info" "Test Summary"
    Write-Message -Type "Info" "═"
    Write-Message -Type "Info" "Total Tests:  $totalTests"
    Write-Message -Type "Info" "Passed Tests: $passedTests"
    Write-Message -Type "Info" "Failed Tests: $failedTests"
    Write-Message -Type "Info" "Pass Rate:    $passRate%"
    Write-Message -Type "Info" "═"

    if ($failedTests -gt 0) {
        Write-Message -Type "Error" "Failed tests:"
        $TestResults | Where-Object { -not $_.Success } | ForEach-Object {
            Write-Message -Type "Error" "  - $($_.FixtureName) (exit code: $($_.ExitCode))"
        }
        return $false
    }

    return $true
}

# ============================================================================
# Main Execution
# ============================================================================

# Ensure we're running in the repository root
try {
    $repoRoot = Get-RepositoryRoot
    Set-Location $repoRoot
    Write-Message -Type "Debug" "Repository root: $repoRoot"
}
catch {
    Write-Message -Type "Error" "Failed to determine repository root: $_"
    exit 1
}

# Display script header
Write-Message -Type "Info" "Discord Notification Workflow Test"
Write-Message -Type "Info" "═"

# Single fixture test
if (-not [string]::IsNullOrWhiteSpace($TestFixturePath)) {
    if (-not (Test-Path $TestFixturePath)) {
        Write-Message -Type "Error" "Test fixture not found: $TestFixturePath"
        exit 1
    }

    Write-Message -Type "Info" "Testing single fixture: $TestFixturePath"
    $webhookUrl = Get-WebhookUrl -ProvidedUrl $WebhookUrl
    $result = Invoke-DiscordNotifyTest -FixturePath $TestFixturePath -WebhookUrl $webhookUrl

    if ($result.Success) {
        Write-Message -Type "Success" "Test passed!"
        exit 0
    }
    else {
        Write-Message -Type "Error" "Test failed with exit code: $($result.ExitCode)"
        Write-Message -Type "Debug" "Output: $($result.Output)"
        exit 1
    }
}

# All fixtures test
$testResults = Invoke-AllDiscordNotifyTests -WebhookUrl $WebhookUrl
$allPassed = Write-TestSummary -TestResults $testResults

exit $(if ($allPassed) { 0 } else { 1 })
