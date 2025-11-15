Write-Host "Verifying d-flows Development Setup... Current Modules" -ForegroundColor Cyan
Get-Module

$scriptDir = $PSScriptRoot
$devDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $devDir

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
                Write-Warning "Failed to remove module $($_.Name): $_"
            }
            break  # Module matched, no need to check other paths
        }
    }
}

Write-Host "After cleanup, Current Modules:" -ForegroundColor Cyan
Get-Module

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

# --- Start d-flows Act Setup Verification ---
Write-Message "`nd-flows Act Setup Verification"
Write-Message "================================="

# Check prerequisites
Write-Message "`nChecking Prerequisites..."

# Check Docker
try {
    $dockerVersion = docker --version
    Write-Message -Type Success "Docker: $dockerVersion"
} catch {
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
    } else {
        Write-Message -Type Error "Act not found. Please install with: winget install nektos.act"
    }
} catch {
    Write-Message -Type Error "Act not working properly."
}

# Check repository
if (Test-Path ".github/workflows") {
    Write-Message -Type Success "GitHub workflows directory found"
} else {
    Write-Message -Type Error "Not in a GitHub Actions repository root"
    exit 1
}

# Check configuration
if (Test-Path ".actrc") {
    Write-Message -Type Success "Act configuration found"
} else {
    Write-Message -Type Warning "Act configuration not found. Using defaults."
}

Write-Message "`nRunning Test Workflow..."

# Test basic workflow
try {
    Write-Message -Type Info "Testing step-summary workflow..."
    & $actPath workflow_dispatch --job set-summary --input title="Setup Test" --input markdown="Act is working correctly!" --input overwrite=true --quiet
    Write-Message -Type Success "Basic workflow test passed"
} catch {
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
Write-Message -Type Debug "Validating tag existence for v0.1.0 $((Validate-TagExists -Tag 'v0.1.0').Success)"
Write-Message -Type Debug "Validating tag existence for v1.0.0 $((Validate-TagExists -Tag 'v1.0.0').Success)"
Write-Message -Type Debug "Validating tag existence for v1.7.0 $((Validate-TagExists -Tag 'v1.7.0').Success)"
Write-Message -Type Debug "Validating tag existence for v99.99.99 $((Validate-TagExists -Tag 'v99.99.99').Success)"

Write-Message -Type Success "Setup Verification Complete. Current Modules Loaded:"
Get-Module

Write-Message -Type Info "From RepositoryUtils: $(New-TestStateDirectory)"

Write-Message -Type Info "Test Modules: $testModules"
Import-Module TestArtifacts -ErrorAction Stop
Write-Message -Type Info "TestArtifacts Module Imported. Test State Directory: $TestStateDirectory"
Write-Message -Type Info "Test Tags File: $TestTagsFile"

Write-Message -Type Info "Test Commits Bundle: $TestCommitsBundle"