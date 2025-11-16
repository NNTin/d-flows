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
    .\Update-ModuleVersions.ps1 -Version 1.3.0
    Updates all module manifests to version 1.3.0.

.NOTES
    Author: Your Name
    Date: 2025-11-16
    Version: 1.0
    Repository: (optional URL or local path)
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

# Find all module manifest files in your repo
$psd1Files = Get-ChildItem -Path . -Recurse -Filter '*.psd1' | Where-Object {
    # Exclude non-module manifests like PSScriptAnalyzerSettings.psd1
    $_.Name -notmatch 'PSScriptAnalyzerSettings'
}

foreach ($file in $psd1Files) {
    Write-Host "Updating $($file.FullName) to version $Version"

    # Read the content
    $content = Get-Content $file.FullName

    # Replace the ModuleVersion line
    $newContent = $content -replace '(?<=ModuleVersion\s*=\s*).*', "'$Version'"

    # Save the updated content
    Set-Content -Path $file.FullName -Value $newContent
}

Write-Host "All module manifests updated successfully."
