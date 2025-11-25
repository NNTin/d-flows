<#!
.SYNOPSIS
    Generates Markdown documentation for every composite action.

.DESCRIPTION
    Imports the d-flows utility modules, runs Invoke-AllActionDocs, and reports
    the paths that were refreshed. Intended for CI enforcement to keep
    docs/actions/*.md in sync with the associated action.yml files.

.PARAMETER ActionsRoot
    Root directory that contains action folders.

.PARAMETER DocsRoot
    Root directory that holds generated Markdown files.

.PARAMETER PythonExecutable
    Optional explicit Python path passed through to Invoke-AllActionDocs.
#>

[CmdletBinding()]
param(
    [string]$ActionsRoot = "actions",
    [string]$DocsRoot = "docs/actions",
    [string]$PythonExecutable
)

$scriptDir = $PSScriptRoot
$integrationDir = Split-Path -Parent $scriptDir
$root = Split-Path -Parent $integrationDir

function Remove-ModulesInPaths {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$ModulePaths)

    $resolvedPaths = $ModulePaths | ForEach-Object {
        (Resolve-Path $_ -ErrorAction Stop).Path.TrimEnd('\\')
    }

    $modules = Get-Module | Where-Object { $_.ModuleBase }
    foreach ($module in $modules) {
        $basePath = $module.ModuleBase.TrimEnd('\\')
        if ($resolvedPaths | Where-Object { $basePath.StartsWith($_, 'OrdinalIgnoreCase') }) {
            if ($PSCmdlet.ShouldProcess($module.Name, 'Remove loaded module')) {
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

Write-Message -Type Header "Generating Action Documentation"
Write-Message -Type Info "Actions root: $ActionsRoot"
Write-Message -Type Info "Docs root: $DocsRoot"

$generatedDocs = Invoke-AllActionDocs -ActionsRoot $ActionsRoot -DocsRoot $DocsRoot -PythonExecutable $PythonExecutable

if (-not $generatedDocs -or $generatedDocs.Count -eq 0) {
    Write-Message -Type Warning 'Invoke-AllActionDocs did not report any generated files.'
} else {
    Write-Message -Type Success "Generated/updated $($generatedDocs.Count) documentation file(s)."
    foreach ($doc in $generatedDocs) {
        Write-Message -Type List $doc
    }
}

Write-Message -Type Success 'Action documentation generation completed.'
