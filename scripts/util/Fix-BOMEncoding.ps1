<#
.SYNOPSIS
    Fixes missing BOM encoding for PowerShell files.

.DESCRIPTION
    Recursively searches for all .ps1, .psm1, and .psd1 files and ensures they are saved
    with UTF-8 BOM encoding to satisfy PowerShell ScriptAnalyzer's PSUseBOMForUnicodeEncodedFile rule.

.EXAMPLE
    .\Fix-BOMEncoding.ps1
#>

$scriptDir = $PSScriptRoot
$utilDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $utilDir

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

# Get all PowerShell files recursively
$files = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1, *.psd1

foreach ($file in $files) {
    try {
        Write-Message -Type "Info" "Processing $($file.FullName)..."

        # Read the file content
        $content = Get-Content -Path $file.FullName -Raw

        # Save it back as UTF8 with BOM
        [System.IO.File]::WriteAllText($file.FullName, $content, [System.Text.Encoding]::UTF8)
    }
    catch {
        Write-Message -Type "Warning" "Failed to process $($file.FullName): $_"
    }
}

Write-Message -Type "Success" "All files processed. BOM encoding applied where necessary."
