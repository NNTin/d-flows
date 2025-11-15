# GitSnapshot.psm1
# Provides functions for backing up and restoring git repository state including tags, branches, and commits for integration testing.

# ============================================================================
# Helper Functions
# ============================================================================

<#
.SYNOPSIS
    Create backup directory if it doesn't exist.

.DESCRIPTION
    Creates backup directory in system temp location.
    Handles cases where directory already exists (no error).

.EXAMPLE
    $backupDir = New-BackupDirectory
    Write-Message -Type "Info" "Backup directory: $backupDir"

.NOTES
    Returns the full path to the backup directory in temp.
#>
function New-BackupDirectory {
    $fullBackupPath = Get-BackupBasePath

    if (-not (Test-Path $fullBackupPath)) {
        Write-Message -Type "Debug" "Creating temp backup directory: $fullBackupPath"
        New-Item -ItemType Directory -Path $fullBackupPath -Force | Out-Null
        Write-Message -Type "Debug" "Backup directory created"
    }
    else {
        Write-Message -Type "Debug" "Backup directory already exists: $fullBackupPath"
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
    Write-Message -Type "Debug" "Timestamp: $timestamp"
#>
function Get-BackupTimestamp {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Write-Message -Type "Debug" "Generated backup timestamp: $timestamp"
    return $timestamp
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
    Write-Message -Type "Backup" "Tags backed up to: $tagsBackupPath"

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

    Write-Message -Type "Info" "Starting git tags backup"

    try {
        Write-Message -Type "Debug" "Backing up git tags"

        # Generate backup path if not provided
        if (-not $BackupPath) {
            $backupDir = New-BackupDirectory
            $timestamp = Get-BackupTimestamp
            $BackupPath = Join-Path $backupDir "tags-$timestamp.txt"
        }

        # Get list of tags
        $tags = @(git tag -l)
        Write-Message -Type "Debug" "Found $($tags.Count) tags"

        $tagContent = @()

        if ($tags.Count -eq 0) {
            $tagContent += "# No tags found"
            Write-Message -Type "Info" "No tags found in repository"
        }
        else {
            foreach ($tag in $tags) {
                try {
                    # Get commit SHA for this tag
                    $sha = git rev-list -n 1 $tag

                    if ($LASTEXITCODE -ne 0) {
                        Write-Message -Type "Warning" "Failed to get SHA for tag: $tag"
                        continue
                    }

                    $tagContent += "$tag $sha"
                    Write-Message -Type "Tag" "Backing up tag: $tag -> $sha"
                }
                catch {
                    Write-Message -Type "Warning" "Error processing tag '$tag': $_"
                    continue
                }
            }
        }

        # Write to backup file
        $tagContent | Out-File -FilePath $BackupPath -Encoding UTF8 -Force
        Write-Message -Type "Info" "Backed up $($tags.Count) tags to $BackupPath"

        return $BackupPath
    }
    catch {
        Write-Message -Type "Error" "Failed to backup git tags: $_"
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
    Write-Message -Type "Backup" "Branches backed up to: $branchesBackupPath"

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

    Write-Message -Type "Info" "Starting git branches backup"

    try {
        Write-Message -Type "Debug" "Backing up git branches"

        # Generate backup path if not provided
        if (-not $BackupPath) {
            $backupDir = New-BackupDirectory
            $timestamp = Get-BackupTimestamp
            $BackupPath = Join-Path $backupDir "branches-$timestamp.json"
        }

        # Get current branch
        $currentBranchOutput = git rev-parse --abbrev-ref HEAD 2>$null
        $currentBranch = if ($LASTEXITCODE -eq 0) { $currentBranchOutput } else { "HEAD" }
        Write-Message -Type "Debug" "Current branch: $currentBranch"

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
                    Write-Message -Type "Warning" "Failed to get SHA for branch: $branchName"
                    continue
                }

                $branches += @{
                    name     = $branchName
                    sha      = $sha
                    isRemote = $isRemote
                }

                Write-Message -Type "Branch" "Backing up branch: $branchName -> $sha"
            }
            catch {
                Write-Message -Type "Warning" "Error processing branch '$branchName': $_"
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
        Write-Message -Type "Info" "Backed up $($branches.Count) branches to $BackupPath"

        return $BackupPath
    }
    catch {
        Write-Message -Type "Error" "Failed to backup git branches: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Backup git commits to a bundle file.

.DESCRIPTION
    Creates a git bundle containing all commits referenced by tags and branches.
    This ensures commit objects are preserved during backup/restore operations.

.PARAMETER BackupPath
    Optional path where bundle should be saved.
    Defaults to commits-<timestamp>.bundle in backup directory.

.EXAMPLE
    Backup-GitCommits -BackupPath "C:\temp\commits-backup.bundle"

.NOTES
    The bundle includes all refs (tags and branches) and their complete commit history.
    Empty repositories (no refs) will skip bundle creation gracefully.
#>
function Backup-GitCommits {
    param([string]$BackupPath)

    Write-Message -Type "Backup" "Starting git commits backup"

    try {
        # Generate backup path if not provided
        if (-not $BackupPath) {
            $backupDir = New-BackupDirectory
            $timestamp = Get-BackupTimestamp
            $BackupPath = Join-Path $backupDir "commits-$timestamp.bundle"
        }

        # Collect all refs (tags and branches) to bundle
        $tags = @(git tag -l 2>$null)
        $branches = @(git branch -l 2>$null | ForEach-Object { $_.TrimStart('*').Trim() })

        # Filter out detached HEAD state
        $branches = $branches | Where-Object { $_ -notmatch '^\(HEAD' -and $_ }

        $allRefs = @()
        $allRefs += $tags
        $allRefs += $branches

        # Handle empty repository (no refs to bundle)
        if ($allRefs.Count -eq 0) {
            Write-Message -Type "Warning" "No refs found to bundle (empty repository or no tags/branches)"
            # Create an empty file to maintain backup structure
            "" | Out-File -FilePath $BackupPath -Encoding UTF8 -Force
            return $BackupPath
        }

        Write-Message -Type "Debug" "Bundling $($allRefs.Count) refs ($($tags.Count) tags, $($branches.Count) branches)"

        # Create git bundle with explicit ref list
        $bundleArgs = @('bundle', 'create', $BackupPath) + $allRefs

        $gitOutput = & git @bundleArgs 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            # If failed, write the captured output to the console
            $gitOutput | ForEach-Object { Write-Message -Type "Error" $_ }
            throw "Git bundle create failed with exit code: $exitCode"
        }

        Write-Message -Type "Info" "Backed up $($allRefs.Count) refs to bundle: $BackupPath"
        return $BackupPath
    }
    catch {
        Write-Message -Type "Error" "Failed to backup git commits: $_"
        throw $_
    }
}

# ============================================================================
# Core Restore Functions
# ============================================================================

<#
.SYNOPSIS
    Restore git commits from a bundle file.

.DESCRIPTION
    Unbundles commits from a git bundle file, restoring commit objects to the repository.
    This must be done before restoring tags to ensure all commit SHAs exist.

.PARAMETER BackupPath
    Required path to the bundle file to restore from.

.EXAMPLE
    Restore-GitCommits -BackupPath "C:\temp\commits-backup.bundle"

.NOTES
    Bundle verification is performed but failures are logged as warnings rather than errors
    to maintain backward compatibility with repositories that may have partial history.
    Missing bundle files are handled gracefully for backward compatibility with old backups.
#>
function Restore-GitCommits {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    Write-Message -Type "Restore" "Starting git commits restore from bundle"

    try {
        # Validate bundle file exists
        if (-not (Test-Path $BackupPath)) {
            Write-Message -Type "Warning" "Bundle file not found: $BackupPath (skipping for backward compatibility)"
            return 0
        }

        # Check if file is empty (created for empty repositories)
        $fileInfo = Get-Item $BackupPath
        if ($fileInfo.Length -eq 0) {
            Write-Message -Type "Info" "Bundle file is empty (no commits to restore)"
            return 0
        }

        # Verify bundle is valid (optional, log warning if fails)
        Write-Message -Type "Debug" "Verifying bundle integrity"
        $verifyResult = git bundle verify $BackupPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Message -Type "Warning" "Bundle verification failed, attempting unbundle anyway: $verifyResult"
        }

        # Unbundle commits to restore commit objects
        Write-Message -Type "Debug" "Unbundling commits from: $BackupPath"
        $unbundleOutput = git bundle unbundle $BackupPath 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Git bundle unbundle failed with exit code: $LASTEXITCODE. Output: $unbundleOutput"
        }

        # Count refs from unbundle output
        $refCount = ($unbundleOutput | Where-Object { $_ -match '^\s*[a-f0-9]{40}\s' }).Count

        Write-Message -Type "Success" "Restored commits from bundle: $refCount refs unbundled"
        return $refCount
    }
    catch {
        Write-Message -Type "Error" "Failed to restore git commits: $_"
        throw $_
    }
}

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

    Write-Message -Type "Info" "Starting git tags restore from $BackupPath"

    try {
        # Validate backup file exists
        if (-not (Test-Path $BackupPath)) {
            throw "Backup file not found: $BackupPath"
        }

        $repoRoot = Get-RepositoryRoot
        Write-Message -Type "Debug" "Repository root: $repoRoot"

        # Delete existing tags if requested
        if ($DeleteExisting) {
            $existingTags = @(git tag -l)
            foreach ($tag in $existingTags) {
                git tag -d $tag
                Write-Message -Type "Debug" "Deleted existing tag: $tag"
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
                Write-Message -Type "Warning" "Invalid tag line format: $line"
                continue
            }

            $tagName = $parts[0]
            $sha = $parts[1]

            try {
                # Check if tag already exists
                $existingTag = git tag -l $tagName
                if ($existingTag -and -not $Force) {
                    Write-Message -Type "Warning" "Tag already exists and Force not set: $tagName"
                    continue
                }

                # Delete existing tag if force is enabled
                if ($existingTag -and $Force) {
                    git tag -d $tagName
                    Write-Message -Type "Debug" "Deleted existing tag for force restore: $tagName"
                }

                # Create tag
                git tag $tagName $sha
                if ($LASTEXITCODE -eq 0) {
                    Write-Message -Type "Tag" "Restored tag: $tagName -> $sha"
                    $restoredCount++
                }
                else {
                    Write-Message -Type "Warning" "Failed to create tag: $tagName"
                }
            }
            catch {
                Write-Message -Type "Warning" "Error restoring tag '$tagName': $_"
                continue
            }
        }

        Write-Message -Type "Success" "Restored $restoredCount tags from $BackupPath"
        return $restoredCount
    }
    catch {
        Write-Message -Type "Error" "Failed to restore git tags: $_"
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

    Write-Message -Type "Info" "Starting git branches restore from $BackupPath"

    try {
        # Validate backup file exists
        if (-not (Test-Path $BackupPath)) {
            throw "Backup file not found: $BackupPath"
        }

        $repoRoot = Get-RepositoryRoot
        Write-Message -Type "Debug" "Repository root: $repoRoot"

        # Read and parse JSON backup file
        $backupContent = Get-Content -Path $BackupPath -Encoding UTF8 | ConvertFrom-Json
        $currentBranch = $backupContent.currentBranch
        $branches = $backupContent.branches

        Write-Message -Type "Debug" "Original current branch: $currentBranch"
        Write-Message -Type "Debug" "Found $($branches.Count) branches to restore"

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
                    Write-Message -Type "Debug" "Created and checked out temporary branch: $tempBranchName"
                    $tempBranchCreated = $true
                }
                else {
                    Write-Message -Type "Warning" "Failed to create temporary branch, continuing without switching"
                }
            }
            catch {
                Write-Message -Type "Warning" "Error creating temporary branch: $_"
            }
        }

        $restoredCount = 0

        foreach ($branch in $branches) {
            # Skip remote branches
            if ($branch.isRemote) {
                Write-Message -Type "Debug" "Skipping remote branch: $($branch.name)"
                continue
            }

            # Skip pull request branches
            if ($branch.name -like 'pull/*') {
                Write-Message -Type "Debug" "Skipping pull request branch: $($branch.name)"
                continue
            }

            try {
                $branchName = $branch.name
                $sha = $branch.sha

                # Check if branch already exists
                $existingBranch = git branch -l $branchName
                if ($existingBranch -and -not $Force) {
                    Write-Message -Type "Warning" "Branch already exists and Force not set: $branchName"
                    continue
                }

                # Delete existing branch if force is enabled
                if ($existingBranch -and $Force) {
                    git branch -D $branchName 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Message -Type "Debug" "Deleted existing branch for force restore: $branchName"
                    }
                }

                # Create branch
                git branch $branchName $sha
                if ($LASTEXITCODE -eq 0) {
                    Write-Message -Type "Branch" "Restored branch: $branchName -> $sha"
                    $restoredCount++
                }
                else {
                    Write-Message -Type "Warning" "Failed to create branch: $branchName"
                }
            }
            catch {
                Write-Message -Type "Warning" "Error restoring branch '$($branch.name)': $_"
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
                    Write-Message -Type "Debug" "Deleted temporary branch: $tempBranchName"
                }
                else {
                    Write-Message -Type "Warning" "Failed to delete temporary branch: $tempBranchName"
                }
            }
            catch {
                Write-Message -Type "Warning" "Error deleting temporary branch: $_"
            }
        }

        # Restore original current branch if requested
        if ($RestoreCurrentBranch -and $currentBranch -and $currentBranch -ne "HEAD") {
            try {
                git checkout $currentBranch 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Message -Type "Branch" "Checked out original branch: $currentBranch"
                }
                else {
                    Write-Message -Type "Warning" "Failed to checkout original branch '$currentBranch'. Check for uncommitted changes."
                }
            }
            catch {
                Write-Message -Type "Warning" "Error checking out branch '$currentBranch': $_"
            }
        }

        Write-Message -Type "Success" "Restored $restoredCount branches from $BackupPath"
        return $restoredCount
    }
    catch {
        Write-Message -Type "Error" "Failed to restore git branches: $_"
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
    Write-Message -Type "Success" "Backup created: $($backup.BackupName)"

.EXAMPLE
    $backup = Backup-GitState -BackupName "before-release-test"
    Write-Message -Type "Info" "Backup stored at: $($backup.BackupDirectory)"

.NOTES
    Creates four files:
    - tags-<name>.txt: Plain text file with tag/SHA pairs
    - branches-<name>.json: JSON file with branch information
    - commits-<name>.bundle: Git bundle with all commit objects
    - manifest-<name>.json: Metadata about the backup (now includes productionTags array listing all tags present at backup time)
#>
function Backup-GitState {
    param(
        [string]$BackupName,
        [bool]$IncludeRemoteBranches = $true
    )

    Write-Message -Type "Info" "Starting complete git state backup"

    try {
        $backupDir = New-BackupDirectory

        # Generate backup name if not provided
        if (-not $BackupName) {
            $BackupName = Get-BackupTimestamp
        }

        Write-Message -Type "Backup" "Backup name: $BackupName"

        # Backup tags
        $tagsBackupPath = Backup-GitTags -BackupPath (Join-Path $backupDir "tags-$BackupName.txt")

        # Capture production tag names at backup time
        $productionTagNames = @()
        try {
            $tagOutput = git tag -l 2>&1
            if ($LASTEXITCODE -eq 0 -and $tagOutput) {
                $productionTagNames = @($tagOutput | Where-Object { $_ -match '\S' })
            }
            Write-Message -Type "Debug" "Captured $($productionTagNames.Count) production tags"
        }
        catch {
            Write-Message -Type "Debug" "No tags found or error capturing production tags: $_"
        }

        # Backup branches
        $branchesBackupPath = Backup-GitBranches -BackupPath (Join-Path $backupDir "branches-$BackupName.json") -IncludeRemote $IncludeRemoteBranches

        # Backup commits
        $commitsBackupPath = Backup-GitCommits -BackupPath (Join-Path $backupDir "commits-$BackupName.bundle")

        $repoRoot = Get-RepositoryRoot

        # Create manifest file
        $manifestPath = Join-Path $backupDir "manifest-$BackupName.json"
        $manifest = @{
            timestamp      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            backupName     = $BackupName
            tagsFile       = "tags-$BackupName.txt"
            branchesFile   = "branches-$BackupName.json"
            commitsFile    = "commits-$BackupName.bundle"
            repositoryPath = $repoRoot
            includeRemote  = $IncludeRemoteBranches
            productionTags = $productionTagNames
        } | ConvertTo-Json -Depth 3

        $manifest | Out-File -FilePath $manifestPath -Encoding UTF8 -Force
        Write-Message -Type "Debug" "Manifest created: $manifestPath"

        Write-Message -Type "Success" "Git state backed up successfully to $backupDir"

        return @{
            BackupName      = $BackupName
            BackupDirectory = $backupDir
            TagsFile        = $tagsBackupPath
            BranchesFile    = $branchesBackupPath
            CommitsFile     = $commitsBackupPath
            ManifestFile    = $manifestPath
        }
    }
    catch {
        Write-Message -Type "Error" "Failed to backup git state: $_"
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
    Restores commits first (if present) to ensure commit objects exist before tags are created
    Deletes all current tags before restoration when DeleteExistingTags is true
    Maintains backward compatibility with old backups that don't have productionTags field
    Returns statistics about restored commits, tags and branches
#>
function Restore-GitState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupName,

        [bool]$Force = $false,
        [bool]$DeleteExistingTags = $false
    )

    Write-Message -Type "Info" "Starting complete git state restore"

    try {
        $backupDir = New-BackupDirectory

        # Locate and read manifest file
        $manifestPath = Join-Path $backupDir "manifest-$BackupName.json"
        if (-not (Test-Path $manifestPath)) {
            throw "Manifest file not found: $manifestPath"
        }

        $manifest = Get-Content -Path $manifestPath -Encoding UTF8 | ConvertFrom-Json
        Write-Message -Type "Debug" "Loaded manifest from: $manifestPath"

        # Extract production tags list from manifest (for backward compatibility)
        $productionTagNames = @()
        if ($manifest.PSObject.Properties.Name -contains 'productionTags') {
            $productionTagNames = @($manifest.productionTags)
            Write-Message -Type "Debug" "Found $($productionTagNames.Count) production tags in manifest"
        }
        else {
            Write-Message -Type "Debug" "No production tags field in manifest (backward compatibility with old backups)"
        }

        # Construct paths to backup files
        $tagsPath = Join-Path $backupDir $manifest.tagsFile
        $branchesPath = Join-Path $backupDir $manifest.branchesFile

        # Restore commits first (if present) to ensure commit objects exist
        $commitsRestored = 0
        if ($manifest.PSObject.Properties.Name -contains 'commitsFile') {
            $commitsPath = Join-Path $backupDir $manifest.commitsFile
            $commitsRestored = Restore-GitCommits -BackupPath $commitsPath
        }
        else {
            Write-Message -Type "Debug" "No commits file in manifest (backward compatibility with old backups)"
        }

        # Handle tag deletion before restoration
        $deleteExistingForRestore = $DeleteExistingTags
        if ($DeleteExistingTags) {
            # Delete ALL current tags before restoration
            try {
                $currentTagsOutput = git tag -l 2>&1
                if ($LASTEXITCODE -eq 0 -and $currentTagsOutput) {
                    $currentTags = @($currentTagsOutput | Where-Object { $_ -match '\S' })

                    # Delete all current tags
                    foreach ($tag in $currentTags) {
                        git tag -d $tag 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Message -Type "Debug" "Deleted tag: $tag"
                        }
                    }

                    # We've handled deletion, don't delete again in Restore-GitTags
                    $deleteExistingForRestore = $false
                    Write-Message -Type "Debug" "Deleted $($currentTags.Count) tags before restoration"
                }
            }
            catch {
                Write-Message -Type "Debug" "Error during tag deletion: $_"
                # Fall back to original behavior
                $deleteExistingForRestore = $DeleteExistingTags
            }
        }

        # Restore tags (now commit SHAs should exist)
        $tagsRestored = Restore-GitTags -BackupPath $tagsPath -Force $Force -DeleteExisting $deleteExistingForRestore

        # Restore branches
        $branchesRestored = Restore-GitBranches -BackupPath $branchesPath -RestoreCurrentBranch $true -Force $Force

        Write-Message -Type "Success" "Git state restored successfully from $BackupName"

        return @{
            BackupName       = $BackupName
            CommitsRestored  = $commitsRestored
            TagsRestored     = $tagsRestored
            BranchesRestored = $branchesRestored
            RestoreTimestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        }
    }
    catch {
        Write-Message -Type "Error" "Failed to restore git state: $_"
        throw $_
    }
}

# ============================================================================
# Utility Functions
# ============================================================================

<#
.SYNOPSIS
    List all available backups in the repository.

.DESCRIPTION
    Scans the backup directory for all manifest files and returns backup information.

.EXAMPLE
    $backups = Get-AvailableBackups
    foreach ($backup in $backups) {
        Write-Message -Type "Info" "Backup: $($backup.BackupName) created at $($backup.Timestamp)"
    }

.NOTES
    Returns array of backup metadata objects
#>
function Get-AvailableBackups {
    Write-Message -Type "Info" "Listing available backups"

    try {
        $backupDir = New-BackupDirectory

        $manifestFiles = @(Get-ChildItem -Path $backupDir -Filter "manifest-*.json" -ErrorAction SilentlyContinue)
        Write-Message -Type "Debug" "Found $($manifestFiles.Count) backup manifests"

        $backups = @()
        foreach ($manifestFile in $manifestFiles) {
            try {
                $manifest = Get-Content -Path $manifestFile.FullName -Encoding UTF8 | ConvertFrom-Json

                # Build backup metadata object
                $backupInfo = @{
                    BackupName   = $manifest.backupName
                    Timestamp    = $manifest.timestamp
                    TagsFile     = $manifest.tagsFile
                    BranchesFile = $manifest.branchesFile
                    ManifestFile = $manifestFile.Name
                }

                # Add commitsFile if present (backward compatibility with old backups)
                if ($manifest.PSObject.Properties.Name -contains 'commitsFile') {
                    $backupInfo.CommitsFile = $manifest.commitsFile
                }

                $backups += $backupInfo
            }
            catch {
                Write-Message -Type "Warning" "Error reading manifest: $($manifestFile.Name)"
                continue
            }
        }

        if ($backups.Count -gt 0) {
            Write-Message -Type "Success" "Found $($backups.Count) available backups"
        }
        else {
            Write-Message -Type "Info" "No backups found"
        }

        return $backups
    }
    catch {
        Write-Message -Type "Error" "Failed to list available backups: $_"
        throw $_
    }
}

# ============================================================================
# Module Exports
# ============================================================================

Export-ModuleMember -Function @(
    'Backup-GitTags',
    'Backup-GitBranches',
    'Backup-GitCommits',
    'Backup-GitState',
    'Restore-GitTags',
    'Restore-GitBranches',
    'Restore-GitCommits',
    'Restore-GitState',
    'Get-AvailableBackups'
)
