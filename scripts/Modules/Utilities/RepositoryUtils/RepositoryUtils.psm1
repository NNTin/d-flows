# RepositoryUtils.psm1

# Module-scoped variable
$script:TestStateGuid = [guid]::NewGuid().ToString('N')

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
    $testStateDirName = "d-flows-test-state-$($script:TestStateGuid)"
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
    $testStateDirName = "d-flows-test-state-$($script:TestStateGuid)"
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


<#
.SYNOPSIS
    Create test state directories if they don't exist.

.DESCRIPTION
    Creates test state and logs directories in system temp location with unique GUID-based naming.
    Each script execution generates a unique GUID-based subdirectory (d-flows-test-state-<guid>)
    to ensure test isolation and prevent conflicts between concurrent test runs.

.EXAMPLE
    $testStateDir = New-TestStateDirectory
    Write-Message -Type "Info" "Test state directory: $testStateDir"

.NOTES
    Returns the full path to the test state directory in temp.

    Directory is automatically cleaned up at script end unless -SkipCleanup is specified.

    Cross-platform temp path resolution:
    - Windows: Uses %TEMP% environment variable
    - Linux: Uses /tmp directory
    - Resolved via [System.IO.Path]::GetTempPath()
#>

function New-TestStateDirectory {
    $testStatePath = Get-TestStateBasePath
    $testLogsPath = Join-Path (Get-TestStateBasePath) "logs"

    if (-not (Test-Path $testStatePath)) {
        Write-Message -Type "Debug" "Creating temp test state directory: $testStatePath"
        New-Item -ItemType Directory -Path $testStatePath -Force | Out-Null
        Write-Message -Type "Debug" "Test state directory created"
    }
    else {
        Write-Message -Type "Debug" "Test state directory already exists: $testStatePath"
    }

    if (-not (Test-Path $testLogsPath)) {
        Write-Message -Type "Debug" "Creating temp test logs directory: $testLogsPath"
        New-Item -ItemType Directory -Path $testLogsPath -Force | Out-Null
        Write-Message -Type "Debug" "Test logs directory created"
    }
    else {
        Write-Message -Type "Debug" "Test logs directory already exists: $testLogsPath"
    }

    return $testStatePath
}