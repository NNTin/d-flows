# RepositoryUtils.psm1

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
        Write-Message -Type "Debug" -Message "Searching for .git in: $Path"

        $gitPath = Join-Path $Path ".git"
        if (Test-Path $gitPath) {
            Write-Message -Type "Debug" -Message "Found repository root: $Path"
            return $Path
        }
        
        $Path = Split-Path $Path -Parent
    }

    throw "❌ Not in a git repository. Please navigate to the repository root and try again."
}
