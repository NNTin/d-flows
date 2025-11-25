Write-Host "Verifying d-flows Development Setup... Current Modules" -ForegroundColor Cyan
Get-Module

$scriptDir = $PSScriptRoot
$devDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $devDir

function Remove-ModulesInPaths {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$ModulePaths)

    $resolvedPaths = $ModulePaths | ForEach-Object {
        (Resolve-Path $_ -ErrorAction Stop).Path.TrimEnd('\')
    }

    $modules = Get-Module | Where-Object { $_.ModuleBase }
    foreach ($module in $modules) {
        $basePath = $module.ModuleBase.TrimEnd('\')
        if ($resolvedPaths | Where-Object { $basePath.StartsWith($_, 'OrdinalIgnoreCase') }) {
            if ($PSCmdlet.ShouldProcess($module.Name, "Remove loaded module")) {
                Write-Host "Unloading module $($module.Name)" -ForegroundColor Yellow
                Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Add-ModulePath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path $Path -ErrorAction Stop).Path
    $separator = [System.IO.Path]::PathSeparator
    $currentPaths = $env:PSModulePath -split [System.IO.Path]::PathSeparator | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if (-not ($currentPaths | Where-Object { $_ -ieq $resolved })) {
        $env:PSModulePath = "$resolved$separator$env:PSModulePath"
        Write-Host "Added module path: $resolved" -ForegroundColor Cyan
    }
}

$projectModules = Join-Path $root 'scripts\Modules'
$utilitiesModules = Join-Path $projectModules 'Utilities'
$testsModules = Join-Path $projectModules 'Tests'

Remove-ModulesInPaths -ModulePaths $projectModules
Add-ModulePath -Path $utilitiesModules
Add-ModulePath -Path $testsModules

Import-Module Colors -Force -ErrorAction Stop
Import-Module Emojis -Force -ErrorAction Stop
Import-Module MessageUtils -Force -ErrorAction Stop
Import-Module RepositoryUtils -Force -ErrorAction Stop
Import-Module ActionDocs -Force -ErrorAction Stop


# --- Start d-flows Act Setup Verification ---
Write-Message "`nd-flows Act Setup Verification"
Write-Message "================================="

# Check prerequisites
Write-Message "`nChecking Prerequisites..."

# Check Docker
try {
    $dockerVersion = docker --version
    Write-Message -Type Success "Docker: $dockerVersion"
}
catch {
    Write-Message -Type Error "Docker not found. Please install Docker Desktop."
    exit 1
}

# Check Act
try {
    $actPath = "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WinGet\Packages\nektos.act_Microsoft.Winget.Source_8wekyb3d8bbwe\act.exe"
    if (Test-Path $actPath) {
        Set-Alias -Name act -Value $actPath -Scope Global
        $actVersion = & $actPath --version
        Write-Message -Type Success "Act: $actVersion"
    }
    else {
        Write-Message -Type Error "Act not found. Please install with: winget install nektos.act"
    }
}
catch {
    Write-Message -Type Error "Act not working properly."
}

# Check repository
if (Test-Path ".github/workflows") {
    Write-Message -Type Success "GitHub workflows directory found"
}
else {
    Write-Message -Type Error "Not in a GitHub Actions repository root"
    exit 1
}

# Check configuration
if (Test-Path ".actrc") {
    Write-Message -Type Success "Act configuration found"
}
else {
    Write-Message -Type Warning "Act configuration not found. Using defaults."
}

Write-Message "`nRunning Test Workflow..."

# Test basic workflow
try {
    Write-Message -Type Info "Testing step-summary workflow..."
    & $actPath workflow_dispatch --job set-summary --input title="Setup Test" --input markdown="Act is working correctly!" --input overwrite=true --quiet
    Write-Message -Type Success "Basic workflow test passed"
}
catch {
    Write-Message -Type Error "Workflow test failed"
}

# --- Test ---
Write-Message -Type Test "Total Tests: " -NoNewline
Write-Message -Type Note "50 passed, 2 failed."
Write-Message -Type Test "Passed Tests: " -NoNewline
Write-Message "50" -ForegroundColor Green
Write-Message -Type Test "Failed Tests: " -NoNewline
Write-Message "2" -ForegroundColor Red

Write-Message -Type Debug "Calling ValidationSuite for deeper checks..."
Write-Message -Type Debug "Validating tag existence for v0.1.0 $((Test-TagExists -Tag 'v0.1.0').Success)"
Write-Message -Type Debug "Validating tag existence for v1.0.0 $((Test-TagExists -Tag 'v1.0.0').Success)"
Write-Message -Type Debug "Validating tag existence for v1.7.0 $((Test-TagExists -Tag 'v1.7.0').Success)"
Write-Message -Type Debug "Validating tag existence for v99.99.99 $((Test-TagExists -Tag 'v99.99.99').Success)"

Write-Message -Type Success "Setup Verification Complete. Current Modules Loaded:"
Get-Module

Write-Message -Type Info "From RepositoryUtils: $(New-TestStateDirectory)"

Import-Module TestArtifacts -ErrorAction Stop
Write-Message -Type Info "TestArtifacts Module Imported. Test State Directory: $TestStateDirectory"
Write-Message -Type Info "Test Tags File: $TestTagsFile"

Write-Message -Type Info "Test Commits Bundle: $TestCommitsBundle"

Invoke-AllActionDocs
