# RepositoryUtils.psm1

# Module-scoped variable
$module:TestStateGuid = [guid]::NewGuid().ToString('N')

function Get-TestStateBasePath {
    <#
    .SYNOPSIS
    Returns the temporary test state base path unique to this module import.

    .DESCRIPTION
    Generates a temporary directory path using the module-scoped GUID. Useful for isolating test state between module imports.

    .EXAMPLE
    Get-TestStateBasePath
    #>
    $tempPath = [System.IO.Path]::GetTempPath()
    $testStateDirName = "d-flows-test-state-$($module:TestStateGuid)"
    return Join-Path $tempPath $testStateDirName
}

function Get-BackupBasePath {
    <#
    .SYNOPSIS
    Returns the backup subdirectory under the module's test state directory.

    .DESCRIPTION
    Builds a path for backup data under the module-scoped test state directory.

    .EXAMPLE
    Get-BackupBasePath
    #>
    $tempPath = [System.IO.Path]::GetTempPath()
    $testStateDirName = "d-flows-test-state-$($module:TestStateGuid)"
    $backupSubDir = Join-Path $testStateDirName "backup"
    return Join-Path $tempPath $backupSubDir
}

function Get-RepositoryRoot {
    <#
    .SYNOPSIS
    Gets the root directory of a Git repository.

    .DESCRIPTION
    This function searches for the root directory of a Git repository by traversing upwards from the specified directory until it finds the `.git` folder. If no Git repository is found, it returns `$null`.

    .PARAMETER Path
    The directory to start the search from. If not provided, it defaults to the current working directory.

    .EXAMPLE
    Get-RepositoryRoot
    Returns the root of the current Git repository starting from the current directory.

    .EXAMPLE
    Get-RepositoryRoot -Path "C:\Projects\MyRepo"
    Returns the root of the Git repository starting from the "C:\Projects\MyRepo" directory.

    .NOTES
        Throws an error if not in a git repository.
    #>
    param (
        [string]$Path = (Get-Location)
    )

    while ($Path -ne (Split-Path $Path)) {
        Write-Message -Type "Debug" "Searching for .git in: $Path"

        $gitPath = Join-Path $Path ".git"
        if (Test-Path $gitPath) {
            Write-Message -Type "Debug" "Found repository root: $Path"
            return $Path
        }
        
        $Path = Split-Path $Path -Parent
    }

    throw "❌ Not in a git repository. Please navigate to the repository root and try again."
}
