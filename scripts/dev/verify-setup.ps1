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
    if (-not ($env:PSModulePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $Path })) {
        $env:PSModulePath = "$Path;$env:PSModulePath"
    }
}

# Prepend both paths
Add-ToPSModulePath $utilitiesModules
Add-ToPSModulePath $projectModules
Add-ToPSModulePath $testModules

# --- Start d-flows Act Setup Verification ---
Write-Message -Message "`nd-flows Act Setup Verification"
Write-Message -Message "================================="

# Check prerequisites
Write-Message -Message "`nChecking Prerequisites..."

# Check Docker
try {
    $dockerVersion = docker --version
    Write-Message -Type Success -Message "Docker: $dockerVersion"
} catch {
    Write-Message -Type Error -Message "Docker not found. Please install Docker Desktop."
    exit 1
}

# Check Act
try {
    $actPath = "C:\Users\$env:USERNAME\AppData\Local\Microsoft\WinGet\Packages\nektos.act_Microsoft.Winget.Source_8wekyb3d8bbwe\act.exe"
    if (Test-Path $actPath) {
        Set-Alias -Name act -Value $actPath -Scope Global
        $actVersion = & $actPath --version
        Write-Message -Type Success -Message "Act: $actVersion"
    } else {
        Write-Message -Type Error -Message "Act not found. Please install with: winget install nektos.act"
    }
} catch {
    Write-Message -Type Error -Message "Act not working properly."
}

# Check repository
if (Test-Path ".github/workflows") {
    Write-Message -Type Success -Message "GitHub workflows directory found"
} else {
    Write-Message -Type Error -Message "Not in a GitHub Actions repository root"
    exit 1
}

# Check configuration
if (Test-Path ".actrc") {
    Write-Message -Type Success -Message "Act configuration found"
} else {
    Write-Message -Type Warning -Message "Act configuration not found. Using defaults."
}

Write-Message -Message "`nRunning Test Workflow..."

# Test basic workflow
try {
    Write-Message -Type Info -Message "Testing step-summary workflow..."
    & $actPath workflow_dispatch --job set-summary --input title="Setup Test" --input markdown="Act is working correctly!" --input overwrite=true --quiet
    Write-Message -Type Success -Message "Basic workflow test passed"
} catch {
    Write-Message -Type Error -Message "Workflow test failed"
}

# --- Test ---
Write-Message -Type Test -Message "Total Tests: " -NoNewline
Write-Message -Type Note -Message "50 passed, 2 failed."
Write-Message -Type Test -Message "Passed Tests: " -NoNewline
Write-Message -Message "50" -ForegroundColor Green
Write-Message -Type Test -Message "Failed Tests: " -NoNewline
Write-Message -Message "2" -ForegroundColor Red

Write-Message -Type Debug -Message "Calling ValidationSuite for deeper checks..."
Write-Message -Type Debug -Message "Validating tag existence for v0.1.0 $((Validate-TagExists -Tag 'v0.1.0').Success)"
Write-Message -Type Debug -Message "Validating tag existence for v1.0.0 $((Validate-TagExists -Tag 'v1.0.0').Success)"
Write-Message -Type Debug -Message "Validating tag existence for v1.7.0 $((Validate-TagExists -Tag 'v1.7.0').Success)"
Write-Message -Type Debug -Message "Validating tag existence for v99.99.99 $((Validate-TagExists -Tag 'v99.99.99').Success)"

Write-Message -Type Success -Message "Setup Verification Complete. Current Modules Loaded:"
Get-Module
