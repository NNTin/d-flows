<#
.SYNOPSIS
    Updates the ModuleVersion in all PowerShell module manifests (.psd1) within the repository.

.DESCRIPTION
    This script searches recursively for all module manifest files (.psd1) in the repository
    and updates their ModuleVersion field to the version supplied via the -Version parameter.
    Files like PSScriptAnalyzerSettings.psd1 are ignored.

.PARAMETER Version
    The module version to set in all manifests. Must be supplied when running the script.

.EXAMPLE
    .\scripts\utils\Update-ModuleVersions.ps1 -Version 1.3.0
    Updates all module manifests to version 1.3.0.

.NOTES
    Author: Tin Nguyen
    Repository: https://github.com/nntin/d-flows
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

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

# Find all module manifest files in your repo
$psd1Files = Get-ChildItem -Path $root -Recurse -Filter '*.psd1' | Where-Object {
    # Exclude non-module manifests like PSScriptAnalyzerSettings.psd1
    $_.Name -notmatch 'PSScriptAnalyzerSettings'
}

foreach ($file in $psd1Files) {
    Write-Message -Type "Info" "Updating $($file.FullName) to version $Version"

    # Read the content
    $content = Get-Content $file.FullName

    # Replace the ModuleVersion line
    $newContent = $content -replace '(?<=ModuleVersion\s*=\s*).*', "'$Version'"

    # Save the updated content
    Set-Content -Path $file.FullName -Value $newContent
}

Write-Message -Type "Success" "All module manifests updated successfully."
