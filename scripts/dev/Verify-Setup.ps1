Write-Host "Verifying d-flows Development Setup... Current Modules" -ForegroundColor Cyan
Get-Module

$scriptDir = $PSScriptRoot
$devDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $devDir

function Get-ModuleDirectoriesRecursively {
    param([string]$Root)

    Get-ChildItem -Path $Root -Recurse -Directory | ForEach-Object {
        $hasManifest = Get-ChildItem -Path $_.FullName -Filter '*.psd1' -File -ErrorAction Ignore
        $hasModule = Get-ChildItem -Path $_.FullName -Filter '*.psm1' -File -ErrorAction Ignore

        if ($hasManifest -or $hasModule) {
            $_.FullName
        }
    }
}


function Unload-ModulesInPaths {
    param([string[]]$ModulePaths)

    $normalized = $ModulePaths | ForEach-Object {
        (Resolve-Path $_).Path.TrimEnd('\')
    }

    foreach ($m in Get-Module) {
        if (-not $m.ModuleBase) { continue }

        $base = $m.ModuleBase.TrimEnd('\')

        if ($normalized | Where-Object { $base.StartsWith($_, 'OrdinalIgnoreCase') }) {
            Write-Host "Unloading module $($m.Name)" -ForegroundColor Yellow
            Remove-Module -Name $m.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

function Load-ModulesRecursively {
    param([string[]]$Roots)

    foreach ($root in $Roots) {
        $dirs = Get-ModuleDirectoriesRecursively -Root $root |
        Sort-Object { $_.Split('\').Count }

        foreach ($d in $dirs) {
            $moduleName = Split-Path $d -Leaf
            Write-Host "Importing module: $moduleName" -ForegroundColor Green
            Import-Module $d -Force -ErrorAction Continue
        }
    }
}


$projectModules = Join-Path $root 'scripts\Modules'

Unload-ModulesInPaths -ModulePaths $projectModules
Load-ModulesRecursively -ModulePaths $projectModules


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

Invoke-ActionDocs -ActionPath .\actions\discord-notify\action.yml -OutputPath .\docs\actions\discord-notify.md
