# ActionDocs.psm1
# Wraps the Python-based action documentation generator with repository-aware helpers.

function Invoke-ActionDocs {
    <#
    .SYNOPSIS
        Generates Markdown documentation for a composite GitHub Action.

    .DESCRIPTION
        Resolves the repository root, validates the action and output paths, and
        executes generate_action_docs.py with Python while emitting emoji-based logs.

    .PARAMETER ActionPath
        Path to the action.yml file (relative to the repository root by default).

    .PARAMETER OutputPath
        Destination path for the generated Markdown file (relative to the repository root by default).

    .PARAMETER PythonExecutable
        Optional override for the Python executable (defaults to python3/python).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ActionPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$PythonExecutable
    )

    $repoRoot = Get-RepositoryRoot
    Write-Message -Type Folder "Repository root detected at: $repoRoot"

    $scriptRelativePath = 'scripts/Modules/Utilities/ActionDocs/generate_action_docs.py'
    $scriptPath = Join-Path $repoRoot $scriptRelativePath
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Message -Type Error "Action docs script missing at $scriptRelativePath"
        throw "generate_action_docs.py not found at $scriptPath"
    }

    $resolvedActionPath = if ([System.IO.Path]::IsPathRooted($ActionPath)) { $ActionPath } else { Join-Path $repoRoot $ActionPath }
    if (-not (Test-Path -LiteralPath $resolvedActionPath)) {
        Write-Message -Type Error "Unable to find action file: $ActionPath"
        throw "Action file not found at $resolvedActionPath"
    }
    $resolvedActionPath = (Resolve-Path -LiteralPath $resolvedActionPath).Path

    $resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        Write-Message -Type Folder "Creating output directory: $outputDirectory"
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $pythonCandidates = @()
    if ($PythonExecutable) {
        $pythonCandidates += $PythonExecutable
    }
    $pythonCandidates += 'python3', 'python'
    $pythonCommand = $null
    foreach ($candidate in $pythonCandidates | Select-Object -Unique) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            $pythonCommand = $candidate
            break
        }
    }

    if (-not $pythonCommand) {
        Write-Message -Type Error "Python executable not found (tried: $($pythonCandidates -join ', '))"
        throw "Unable to locate python executable. Install Python 3 or specify -PythonExecutable."
    }

    $arguments = @(
        $scriptPath,
        '--action', $resolvedActionPath,
        '--output', $resolvedOutputPath
    )

    Write-Message -Type Start "Generating docs for: $resolvedActionPath"
    Write-Message -Type List "Command: $pythonCommand $($arguments -join ' ')"

    Push-Location $repoRoot
    try {
        & $pythonCommand @arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        Write-Message -Type Error "Action docs generation failed with exit code $exitCode"
        throw "Action documentation generation failed (exit code $exitCode)."
    }

    Write-Message -Type Success "Documentation generated: $resolvedOutputPath"
    return $resolvedOutputPath
}

Export-ModuleMember -Function Invoke-ActionDocs
