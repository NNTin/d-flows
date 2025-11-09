<#
.SYNOPSIS
    Backup and restore git state (tags and branches) for act integration testing.

.DESCRIPTION
    This script provides functions to backup and restore git repository state, including all tags
    and branches. Backups are stored with timestamp-based filenames in a system temp directory
    for later restoration. This is essential for integration testing with act, where
    tests may modify the git repository state.

    The script includes functions for:
    - Backing up tags in "tag_name commit_sha" format (compatible with bump-version.yml)
    - Backing up branches in JSON format with current branch indicator
    - Restoring tags with optional force overwrite and delete existing
    - Restoring branches with optional checkout of original branch
    - Orchestrating complete backup/restore operations
    - Listing available backups

.EXAMPLE
    # Dot-source the script to load functions
    . .\scripts\integration\Backup-GitState.ps1

    # Backup current git state
    $backup = Backup-GitState
    Write-Host "Backup created: $($backup.BackupName)"

    # ... run tests that modify git state ...

    # Restore git state
    Restore-GitState -BackupName $backup.BackupName

.EXAMPLE
    # Backup with custom name
    $backup = Backup-GitState -BackupName "before-release-test"
    
    # Restore from backup
    Restore-GitState -BackupName "before-release-test" -Force

.EXAMPLE
    # List available backups
    Get-AvailableBackups

.NOTES
    Backup Format:
    - Tags: Plain text file "tags-<name>.txt" with format "tag_name commit_sha" (one per line)
    - Branches: JSON file "branches-<name>.json" with structure containing currentBranch and branches array
    - Manifest: JSON file "manifest-<name>.json" with backup metadata

    Storage Location: System temp directory (Windows: %TEMP%, Linux: /tmp) in subdirectory d-flows-test-state-<guid>/backup/
    Each script execution generates a unique GUID for isolation. The temp directory is managed by the calling script (e.g., Run-ActTests.ps1).

    Edge Cases Handled:
    - Empty repositories (no tags/branches)
    - Detached HEAD state
    - Uncommitted changes blocking checkout
    - Invalid commit SHAs
    - Missing or corrupt backup files
    - Permission issues

    Compatibility:
    - Tag format matches .github/workflows/bump-version.yml line 58 format
    - Integrates with test-tags.txt in temp directory, mounted to /tmp/test-state in Docker containers
#>

# ============================================================================
# Global Variables and Configuration
# ============================================================================

# Generate a unique GUID for this script execution to ensure consistent temp directory naming
$script:BackupStateGuid = [guid]::NewGuid().ToString('N')

# Get temp-based backup directory path
function Get-BackupBasePath {
    $tempPath = [System.IO.Path]::GetTempPath()
    $testStateDirName = "d-flows-test-state-$($script:BackupStateGuid)"
    $backupSubDir = Join-Path $testStateDirName "backup"
    return Join-Path $tempPath $backupSubDir
}

$BackupDirectory = Get-BackupBasePath
$DebugPreference = "Continue"

# Color constants (matching style from verify-act-setup.ps1)
$Colors = @{
    Success = [System.ConsoleColor]::Green
    Warning = [System.ConsoleColor]::Yellow
    Error   = [System.ConsoleColor]::Red
    Info    = [System.ConsoleColor]::Cyan
    Debug   = [System.ConsoleColor]::DarkGray
}

$Emojis = @{
    Success = "✅"
    Warning = "⚠️"
    Error   = "❌"
    Info    = "ℹ️"
    Debug   = "🔍"
    Tag     = "🏷️"
    Branch  = "🌿"
    Backup  = "💾"
    Restore = "♻️"
}

# ============================================================================
# Helper Functions
# ============================================================================

<#
.SYNOPSIS
    Detect the git repository root directory.

.DESCRIPTION
    Walks up the directory tree from the current location until finding a .git directory.

.EXAMPLE
    $repoRoot = Get-RepositoryRoot
    Write-Host "Repository root: $repoRoot"

.NOTES
    Throws an error if not in a git repository.
#>
function Get-RepositoryRoot {
    $currentPath = Get-Location
    $searchPath = $currentPath

    while ($searchPath.Path -ne (Split-Path $searchPath.Path)) {
        Write-Debug "$($Emojis.Debug) Searching for .git in: $searchPath"
        
        $gitPath = Join-Path $searchPath.Path ".git"
        if (Test-Path $gitPath) {
            Write-Debug "$($Emojis.Debug) Found repository root: $($searchPath.Path)"
            return $searchPath.Path
        }
        
        $searchPath = Split-Path $searchPath.Path -Parent
    }

    throw "❌ Not in a git repository. Please navigate to the repository root and try again."
}

<#
.SYNOPSIS
    Create backup directory if it doesn't exist.

.DESCRIPTION
    Creates backup directory in system temp location.
    Handles cases where directory already exists (no error).

.EXAMPLE
    $backupDir = New-BackupDirectory
    Write-Host "Backup directory: $backupDir"

.NOTES
    Returns the full path to the backup directory in temp.
#>
function New-BackupDirectory {
    $fullBackupPath = Get-BackupBasePath
    
    if (-not (Test-Path $fullBackupPath)) {
        Write-Debug "$($Emojis.Debug) Creating temp backup directory: $fullBackupPath"
        New-Item -ItemType Directory -Path $fullBackupPath -Force | Out-Null
        Write-Debug "$($Emojis.Debug) Backup directory created"
    } else {
        Write-Debug "$($Emojis.Debug) Backup directory already exists: $fullBackupPath"
    }

    return $fullBackupPath
}

<#
.SYNOPSIS
    Generate a timestamp string for unique backup filenames.

.DESCRIPTION
    Creates a timestamp in format yyyyMMdd-HHmmss.

.EXAMPLE
    $timestamp = Get-BackupTimestamp
    Write-Host "Timestamp: $timestamp"
#>
function Get-BackupTimestamp {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Write-Debug "$($Emojis.Debug) Generated backup timestamp: $timestamp"
    return $timestamp
}

<#
.SYNOPSIS
    Write debug messages with consistent formatting.

.DESCRIPTION
    Wrapper function for consistent debug output with emoji prefixes and colors.

.PARAMETER Type
    Message type: INFO, SUCCESS, WARNING, ERROR

.PARAMETER Message
    The message text to display

.EXAMPLE
    Write-DebugMessage -Type "INFO" -Message "Starting backup process"
    Write-DebugMessage -Type "SUCCESS" -Message "Backup completed"
#>
function Write-DebugMessage {
    param(
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Type,
        
        [string]$Message
    )

    $emoji = switch ($Type) {
        "INFO"    { $Emojis.Info }
        "SUCCESS" { $Emojis.Success }
        "WARNING" { $Emojis.Warning }
        "ERROR"   { $Emojis.Error }
        default   { "ℹ️" }
    }

    $color = $Colors[$Type.ToLower()]
    
    Write-Host "$emoji $Message" -ForegroundColor $color
}

# ============================================================================
# Core Backup Functions
# ============================================================================

<#
.SYNOPSIS
    Backup all git tags from the repository.

.DESCRIPTION
    Retrieves all git tags and their corresponding commit SHAs, storing them
    in a plain text format compatible with bump-version.yml.

.PARAMETER BackupPath
    Optional custom backup file path. If not provided, generates using timestamp.

.PARAMETER IncludeAnnotatedInfo
    Optional flag to include annotation information (default: $false).

.EXAMPLE
    $tagsBackupPath = Backup-GitTags
    Write-Host "Tags backed up to: $tagsBackupPath"

.EXAMPLE
    $tagsBackupPath = Backup-GitTags -BackupPath "C:\repo\.test-state\backup\tags-manual.txt"

.NOTES
    Output format: "tag_name commit_sha" (one per line)
    Empty repositories result in a file with comment "# No tags found"
#>
function Backup-GitTags {
    param(
        [string]$BackupPath,
        [bool]$IncludeAnnotatedInfo = $false
    )

    Write-DebugMessage -Type "INFO" -Message "Starting git tags backup"
    
    try {
        Write-Debug "$($Emojis.Debug) Backing up git tags"

        # Generate backup path if not provided
        if (-not $BackupPath) {
            $backupDir = New-BackupDirectory
            $timestamp = Get-BackupTimestamp
            $BackupPath = Join-Path $backupDir "tags-$timestamp.txt"
        }

        # Get list of tags
        $tags = @(git tag -l)
        Write-Debug "$($Emojis.Debug) Found $($tags.Count) tags"

        $tagContent = @()

        if ($tags.Count -eq 0) {
            $tagContent += "# No tags found"
            Write-DebugMessage -Type "INFO" -Message "No tags found in repository"
        } else {
            foreach ($tag in $tags) {
                try {
                    # Get commit SHA for this tag
                    $sha = git rev-list -n 1 $tag
                    
                    if ($LASTEXITCODE -ne 0) {
                        Write-DebugMessage -Type "WARNING" -Message "Failed to get SHA for tag: $tag"
                        continue
                    }

                    $tagContent += "$tag $sha"
                    Write-Debug "$($Emojis.Tag) Backing up tag: $tag -> $sha"
                } catch {
                    Write-DebugMessage -Type "WARNING" -Message "Error processing tag '$tag': $_"
                    continue
                }
            }
        }

        # Write to backup file
        $tagContent | Out-File -FilePath $BackupPath -Encoding UTF8 -Force
        Write-DebugMessage -Type "INFO" -Message "Backed up $($tags.Count) tags to $BackupPath"

        return $BackupPath
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to backup git tags: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Backup all git branches from the repository.

.DESCRIPTION
    Retrieves all git branches (local and optionally remote) with their commit SHAs.
    Stores as JSON to preserve current branch indicator and branch information.

.PARAMETER BackupPath
    Optional custom backup file path. If not provided, generates using timestamp.

.PARAMETER IncludeRemote
    Whether to include remote branches (default: $true).

.EXAMPLE
    $branchesBackupPath = Backup-GitBranches
    Write-Host "Branches backed up to: $branchesBackupPath"

.EXAMPLE
    $branchesBackupPath = Backup-GitBranches -BackupPath "C:\repo\.test-state\backup\branches-manual.json" -IncludeRemote $false

.NOTES
    Output format: JSON with currentBranch indicator and branches array
    Handles detached HEAD state gracefully
#>
function Backup-GitBranches {
    param(
        [string]$BackupPath,
        [bool]$IncludeRemote = $true
    )

    Write-DebugMessage -Type "INFO" -Message "Starting git branches backup"
    
    try {
        Write-Debug "$($Emojis.Debug) Backing up git branches"

        # Generate backup path if not provided
        if (-not $BackupPath) {
            $backupDir = New-BackupDirectory
            $timestamp = Get-BackupTimestamp
            $BackupPath = Join-Path $backupDir "branches-$timestamp.json"
        }

        # Get current branch
        $currentBranchOutput = git rev-parse --abbrev-ref HEAD 2>$null
        $currentBranch = if ($LASTEXITCODE -eq 0) { $currentBranchOutput } else { "HEAD" }
        Write-Debug "$($Emojis.Debug) Current branch: $currentBranch"

        # Get list of branches
        $branchesOutput = git branch -a
        $branches = @()

        foreach ($branchLine in $branchesOutput) {
            # Remove leading '* ' for current branch
            $branchName = $branchLine.Trim()
            if ($branchName.StartsWith("* ")) {
                $branchName = $branchName.Substring(2).Trim()
            }

            # Skip empty lines
            if ([string]::IsNullOrWhiteSpace($branchName)) {
                continue
            }

            # Optionally skip remote branches
            $isRemote = $branchName.StartsWith("remotes/")
            if ($isRemote -and -not $IncludeRemote) {
                continue
            }

            # Skip symbolic refs (the ones with '->')
            if ($branchName -match "->") { 
                # Extract actual branch after '->'
                $branchName = ($branchName -split '->')[1].Trim()
            }

            try {
                # Get commit SHA for this branch
                $sha = git rev-parse $branchName 2>$null
                
                if ($LASTEXITCODE -ne 0) {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to get SHA for branch: $branchName"
                    continue
                }

                $branches += @{
                    name     = $branchName
                    sha      = $sha
                    isRemote = $isRemote
                }

                Write-Debug "$($Emojis.Branch) Backing up branch: $branchName -> $sha"
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error processing branch '$branchName': $_"
                continue
            }
        }

        # Create JSON structure
        $backupData = @{
            currentBranch = $currentBranch
            branches      = $branches
        } | ConvertTo-Json -Depth 3

        # Write to backup file
        $backupData | Out-File -FilePath $BackupPath -Encoding UTF8 -Force
        Write-DebugMessage -Type "INFO" -Message "Backed up $($branches.Count) branches to $BackupPath"

        return $BackupPath
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to backup git branches: $_"
        throw $_
    }
}

# ============================================================================
# Core Restore Functions
# ============================================================================

<#
.SYNOPSIS
    Restore git tags from a backup file.

.DESCRIPTION
    Reads a backup file and restores git tags. Supports force overwrite and
    delete existing tags options.

.PARAMETER BackupPath
    Required path to the backup file to restore from.

.PARAMETER Force
    Force overwrite existing tags (default: $false).

.PARAMETER DeleteExisting
    Delete all existing tags before restore (default: $false).

.EXAMPLE
    $result = Restore-GitTags -BackupPath "C:\repo\.test-state\backup\tags-20251106-103000.txt"

.EXAMPLE
    $result = Restore-GitTags -BackupPath "C:\repo\.test-state\backup\tags-20251106-103000.txt" -Force -DeleteExisting

.NOTES
    Backup file format: "tag_name commit_sha" (one per line)
    Comments (starting with #) are skipped
#>
function Restore-GitTags {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        
        [bool]$Force = $false,
        [bool]$DeleteExisting = $false
    )

    Write-DebugMessage -Type "INFO" -Message "Starting git tags restore from $BackupPath"
    
    try {
        # Validate backup file exists
        if (-not (Test-Path $BackupPath)) {
            throw "Backup file not found: $BackupPath"
        }

        $repoRoot = Get-RepositoryRoot
        Write-Debug "$($Emojis.Debug) Repository root: $repoRoot"

        # Delete existing tags if requested
        if ($DeleteExisting) {
            $existingTags = @(git tag -l)
            foreach ($tag in $existingTags) {
                git tag -d $tag
                Write-Debug "$($Emojis.Debug) Deleted existing tag: $tag"
            }
        }

        # Read and process backup file
        $tagLines = Get-Content -Path $BackupPath -Encoding UTF8
        $restoredCount = 0

        foreach ($line in $tagLines) {
            # Skip empty lines and comments
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                continue
            }

            # Parse "tag_name commit_sha" format
            $parts = $line -split '\s+', 2
            if ($parts.Count -ne 2) {
                Write-DebugMessage -Type "WARNING" -Message "Invalid tag line format: $line"
                continue
            }

            $tagName = $parts[0]
            $sha = $parts[1]

            try {
                # Check if tag already exists
                $existingTag = git tag -l $tagName
                if ($existingTag -and -not $Force) {
                    Write-DebugMessage -Type "WARNING" -Message "Tag already exists and Force not set: $tagName"
                    continue
                }

                # Delete existing tag if force is enabled
                if ($existingTag -and $Force) {
                    git tag -d $tagName
                    Write-Debug "$($Emojis.Debug) Deleted existing tag for force restore: $tagName"
                }

                # Create tag
                git tag $tagName $sha
                if ($LASTEXITCODE -eq 0) {
                    Write-Debug "$($Emojis.Tag) Restored tag: $tagName -> $sha"
                    $restoredCount++
                } else {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to create tag: $tagName"
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error restoring tag '$tagName': $_"
                continue
            }
        }

        Write-DebugMessage -Type "SUCCESS" -Message "Restored $restoredCount tags from $BackupPath"
        return $restoredCount
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to restore git tags: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Restore git branches from a backup file.

.DESCRIPTION
    Reads a backup JSON file and restores git branches. Optionally restores
    the original current branch via checkout.

.PARAMETER BackupPath
    Required path to the backup JSON file to restore from.

.PARAMETER RestoreCurrentBranch
    Whether to checkout the original current branch (default: $true).

.PARAMETER Force
    Force overwrite existing branches (default: $false).

.EXAMPLE
    $result = Restore-GitBranches -BackupPath "C:\repo\.test-state\backup\branches-20251106-103000.json"

.EXAMPLE
    $result = Restore-GitBranches -BackupPath "C:\repo\.test-state\backup\branches-20251106-103000.json" -Force

.NOTES
    Remote branches are skipped (should be fetched, not created locally)
    Handles detached HEAD and uncommitted changes appropriately
#>
function Restore-GitBranches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        
        [bool]$RestoreCurrentBranch = $true,
        [bool]$Force = $false
    )
    # TODO: (may be relevant once release branches exist)
    # Modify `Restore-GitBranches` function in `Backup-GitState.ps1` to delete local branches that exist in the repository but are NOT in the backup
    # Add logic after restoring branches (around line 660) to compare current branches with backed-up branches
    # Delete extra branches (except `main` and current branch) to ensure complete state restoration

    Write-DebugMessage -Type "INFO" -Message "Starting git branches restore from $BackupPath"
    
    try {
        # Validate backup file exists
        if (-not (Test-Path $BackupPath)) {
            throw "Backup file not found: $BackupPath"
        }

        $repoRoot = Get-RepositoryRoot
        Write-Debug "$($Emojis.Debug) Repository root: $repoRoot"

        # Read and parse JSON backup file
        $backupContent = Get-Content -Path $BackupPath -Encoding UTF8 | ConvertFrom-Json
        $currentBranch = $backupContent.currentBranch
        $branches = $backupContent.branches

        Write-Debug "$($Emojis.Debug) Original current branch: $currentBranch"
        Write-Debug "$($Emojis.Debug) Found $($branches.Count) branches to restore"

        # Store current branch and prepare for restoration
        $originalCurrentBranch = git rev-parse --abbrev-ref HEAD 2>$null
        $currentCommitSha = git rev-parse HEAD 2>$null
        $tempBranchName = "temp-restore-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $tempBranchCreated = $false

        # Create and checkout temporary branch to avoid "cannot delete current branch" errors
        if ($Force -and $originalCurrentBranch -ne "HEAD") {
            try {
                git checkout -b $tempBranchName $currentCommitSha 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Debug "$($Emojis.Debug) Created and checked out temporary branch: $tempBranchName"
                    $tempBranchCreated = $true
                } else {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to create temporary branch, continuing without switching"
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error creating temporary branch: $_"
            }
        }

        $restoredCount = 0

        foreach ($branch in $branches) {
            # Skip remote branches
            if ($branch.isRemote) {
                Write-Debug "$($Emojis.Debug) Skipping remote branch: $($branch.name)"
                continue
            }

            try {
                $branchName = $branch.name
                $sha = $branch.sha

                # Check if branch already exists
                $existingBranch = git branch -l $branchName
                if ($existingBranch -and -not $Force) {
                    Write-DebugMessage -Type "WARNING" -Message "Branch already exists and Force not set: $branchName"
                    continue
                }

                # Delete existing branch if force is enabled
                if ($existingBranch -and $Force) {
                    git branch -D $branchName 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Debug "$($Emojis.Debug) Deleted existing branch for force restore: $branchName"
                    }
                }

                # Create branch
                git branch $branchName $sha
                if ($LASTEXITCODE -eq 0) {
                    Write-Debug "$($Emojis.Branch) Restored branch: $branchName -> $sha"
                    $restoredCount++
                } else {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to create branch: $branchName"
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error restoring branch '$($branch.name)': $_"
                continue
            }
        }

        # Delete temporary branch if one was created
        if ($tempBranchCreated) {
            try {
                # First checkout away from the temp branch
                if ($currentBranch -and $currentBranch -ne "HEAD") {
                    git checkout $currentBranch 2>&1 | Out-Null
                }
                # Then delete the temp branch
                git branch -D $tempBranchName 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Debug "$($Emojis.Debug) Deleted temporary branch: $tempBranchName"
                } else {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to delete temporary branch: $tempBranchName"
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error deleting temporary branch: $_"
            }
        }

        # Restore original current branch if requested
        if ($RestoreCurrentBranch -and $currentBranch -and $currentBranch -ne "HEAD") {
            try {
                git checkout $currentBranch 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Debug "$($Emojis.Branch) Checked out original branch: $currentBranch"
                } else {
                    Write-DebugMessage -Type "WARNING" -Message "Failed to checkout original branch '$currentBranch'. Check for uncommitted changes."
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error checking out branch '$currentBranch': $_"
            }
        }

        Write-DebugMessage -Type "SUCCESS" -Message "Restored $restoredCount branches from $BackupPath"
        return $restoredCount
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to restore git branches: $_"
        throw $_
    }
}

# ============================================================================
# Orchestration Functions
# ============================================================================

<#
.SYNOPSIS
    Backup complete git repository state (tags and branches).

.DESCRIPTION
    Creates a complete backup of all git tags and branches with a manifest file
    for tracking and restoration.

.PARAMETER BackupName
    Optional custom name for this backup set (default: timestamp).

.PARAMETER IncludeRemoteBranches
    Whether to backup remote branches (default: $true).

.EXAMPLE
    $backup = Backup-GitState
    Write-Host "Backup created: $($backup.BackupName)"

.EXAMPLE
    $backup = Backup-GitState -BackupName "before-release-test"
    Write-Host "Backup stored at: $($backup.BackupDirectory)"

.NOTES
    Creates three files:
    - tags-<name>.txt: Plain text file with tag/SHA pairs
    - branches-<name>.json: JSON file with branch information
    - manifest-<name>.json: Metadata about the backup
#>
function Backup-GitState {
    param(
        [string]$BackupName,
        [bool]$IncludeRemoteBranches = $true
    )

    Write-DebugMessage -Type "INFO" -Message "Starting complete git state backup"
    
    try {
        $backupDir = New-BackupDirectory

        # Generate backup name if not provided
        if (-not $BackupName) {
            $BackupName = Get-BackupTimestamp
        }

        Write-Debug "$($Emojis.Backup) Backup name: $BackupName"

        # Backup tags
        $tagsBackupPath = Backup-GitTags -BackupPath (Join-Path $backupDir "tags-$BackupName.txt")
        
        # Backup branches
        $branchesBackupPath = Backup-GitBranches -BackupPath (Join-Path $backupDir "branches-$BackupName.json") -IncludeRemote $IncludeRemoteBranches

        $repoRoot = Get-RepositoryRoot

        # Create manifest file
        $manifestPath = Join-Path $backupDir "manifest-$BackupName.json"
        $manifest = @{
            timestamp        = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            backupName       = $BackupName
            tagsFile         = "tags-$BackupName.txt"
            branchesFile     = "branches-$BackupName.json"
            repositoryPath   = $repoRoot
            includeRemote    = $IncludeRemoteBranches
        } | ConvertTo-Json -Depth 3

        $manifest | Out-File -FilePath $manifestPath -Encoding UTF8 -Force
        Write-Debug "$($Emojis.Debug) Manifest created: $manifestPath"

        Write-DebugMessage -Type "SUCCESS" -Message "Git state backed up successfully to $backupDir"

        return @{
            BackupName      = $BackupName
            BackupDirectory = $backupDir
            TagsFile        = $tagsBackupPath
            BranchesFile    = $branchesBackupPath
            ManifestFile    = $manifestPath
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to backup git state: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Restore complete git repository state from backup.

.DESCRIPTION
    Restores git tags and branches from a previous backup using the manifest file
    to locate all necessary backup files.

.PARAMETER BackupName
    Required name of the backup set to restore.

.PARAMETER Force
    Force overwrite existing tags/branches (default: $false).

.PARAMETER DeleteExistingTags
    Delete all existing tags before restore (default: $false).

.EXAMPLE
    Restore-GitState -BackupName "20251106-103000"

.EXAMPLE
    Restore-GitState -BackupName "before-release-test" -Force -DeleteExistingTags

.NOTES
    Locates all backup files using the manifest file
    Returns statistics about restored tags and branches
#>
function Restore-GitState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupName,
        
        [bool]$Force = $false,
        [bool]$DeleteExistingTags = $false
    )

    Write-DebugMessage -Type "INFO" -Message "Starting complete git state restore"
    
    try {
        $backupDir = New-BackupDirectory
        
        # Locate and read manifest file
        $manifestPath = Join-Path $backupDir "manifest-$BackupName.json"
        if (-not (Test-Path $manifestPath)) {
            throw "Manifest file not found: $manifestPath"
        }

        $manifest = Get-Content -Path $manifestPath -Encoding UTF8 | ConvertFrom-Json
        Write-Debug "$($Emojis.Debug) Loaded manifest from: $manifestPath"

        # Construct paths to backup files
        $tagsPath = Join-Path $backupDir $manifest.tagsFile
        $branchesPath = Join-Path $backupDir $manifest.branchesFile

        # Restore tags
        $tagsRestored = Restore-GitTags -BackupPath $tagsPath -Force $Force -DeleteExisting $DeleteExistingTags
        
        # Restore branches
        $branchesRestored = Restore-GitBranches -BackupPath $branchesPath -RestoreCurrentBranch $true -Force $Force

        Write-DebugMessage -Type "SUCCESS" -Message "Git state restored successfully from $BackupName"

        return @{
            BackupName        = $BackupName
            TagsRestored      = $tagsRestored
            BranchesRestored  = $branchesRestored
            RestoreTimestamp  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        }
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to restore git state: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    List all available backups in the repository.

.DESCRIPTION
    Scans the backup directory for all manifest files and returns backup information.

.EXAMPLE
    $backups = Get-AvailableBackups
    foreach ($backup in $backups) {
        Write-Host "Backup: $($backup.BackupName) created at $($backup.Timestamp)"
    }

.NOTES
    Returns array of backup metadata objects
#>
function Get-AvailableBackups {
    Write-DebugMessage -Type "INFO" -Message "Listing available backups"
    
    try {
        $backupDir = New-BackupDirectory
        
        $manifestFiles = @(Get-ChildItem -Path $backupDir -Filter "manifest-*.json" -ErrorAction SilentlyContinue)
        Write-Debug "$($Emojis.Debug) Found $($manifestFiles.Count) backup manifests"

        $backups = @()
        foreach ($manifestFile in $manifestFiles) {
            try {
                $manifest = Get-Content -Path $manifestFile.FullName -Encoding UTF8 | ConvertFrom-Json
                $backups += @{
                    BackupName    = $manifest.backupName
                    Timestamp     = $manifest.timestamp
                    TagsFile      = $manifest.tagsFile
                    BranchesFile  = $manifest.branchesFile
                    ManifestFile  = $manifestFile.Name
                }
            } catch {
                Write-DebugMessage -Type "WARNING" -Message "Error reading manifest: $($manifestFile.Name)"
                continue
            }
        }

        if ($backups.Count -gt 0) {
            Write-DebugMessage -Type "SUCCESS" -Message "Found $($backups.Count) available backups"
        } else {
            Write-DebugMessage -Type "INFO" -Message "No backups found"
        }

        return $backups
    } catch {
        Write-DebugMessage -Type "ERROR" -Message "Failed to list available backups: $_"
        throw $_
    }
}

# ============================================================================
# Main Script Execution Block
# ============================================================================

# Check if script is being dot-sourced or executed directly
if ($MyInvocation.InvocationName -ne ".") {
    # Script is being executed directly
    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host "  Git State Backup/Restore Script" -ForegroundColor Cyan
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This script provides functions for backing up and restoring git repository state." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Available Functions:" -ForegroundColor Yellow
    Write-Host "  Backup-GitState                   - Backup all tags and branches" -ForegroundColor Cyan
    Write-Host "  Restore-GitState [-BackupName]    - Restore tags and branches from backup" -ForegroundColor Cyan
    Write-Host "  Get-AvailableBackups              - List all available backups" -ForegroundColor Cyan
    Write-Host "  Backup-GitTags                    - Backup tags only" -ForegroundColor Cyan
    Write-Host "  Backup-GitBranches                - Backup branches only" -ForegroundColor Cyan
    Write-Host "  Restore-GitTags [-BackupPath]     - Restore tags only" -ForegroundColor Cyan
    Write-Host "  Restore-GitBranches [-BackupPath] - Restore branches only" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage Examples:" -ForegroundColor Yellow
    Write-Host "  # Dot-source to load functions:" -ForegroundColor Gray
    Write-Host "  . .\scripts\integration\Backup-GitState.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Backup current state:" -ForegroundColor Gray
    Write-Host "  \$backup = Backup-GitState" -ForegroundColor White
    Write-Host ""
    Write-Host "  # List available backups:" -ForegroundColor Gray
    Write-Host "  Get-AvailableBackups" -ForegroundColor White
    Write-Host ""
    Write-Host "  # Restore from backup:" -ForegroundColor Gray
    Write-Host "  Restore-GitState -BackupName \$backup.BackupName" -ForegroundColor White
    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host ""
}
