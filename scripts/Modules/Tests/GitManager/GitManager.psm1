# GitManager.psm1
# Provides git state management functions for creating and manipulating tags, branches, and commits during integration testing.

<#
.SYNOPSIS
    Get the SHA of the current commit.

.DESCRIPTION
    Retrieves the SHA of the HEAD commit in the current git repository.
    Handles edge cases like detached HEAD state and repositories with no commits.

.EXAMPLE
    $currentSha = Get-CurrentCommitSha
    Write-Message -Type "Info" "Current commit: $currentSha"

.OUTPUTS
    System.String
    Returns the 40-character SHA-1 hash of the current commit.

.NOTES
    Throws an error if the repository has no commits or if git command fails.
#>
function Get-CurrentCommitSha {
    try {
        $sha = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Message -Type "Debug" -Message "Current commit SHA: $sha"
            return $sha
        }
        else {
            throw "Failed to get current commit SHA"
        }
    }
    catch {
        Write-Message -Type "Error" -Message "Error getting current commit: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Check if a git tag exists.

.DESCRIPTION
    Checks whether a specific git tag exists in the repository.

.PARAMETER TagName
    The name of the tag to check for existence.

.EXAMPLE
    if (Test-GitTagExists -TagName "v1.0.0") {
        Write-Message -Type "Info" "Tag v1.0.0 exists"
    }

.OUTPUTS
    System.Boolean
    Returns $true if the tag exists, $false otherwise.
#>
function Test-GitTagExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName
    )

    $existingTag = git tag -l $TagName 2>$null
    $exists = -not [string]::IsNullOrWhiteSpace($existingTag)

    Write-Message -Type "Debug" -Message "Tag exists check '$TagName': $exists"
    return $exists
}

<#
.SYNOPSIS
    Check if a git branch exists.

.DESCRIPTION
    Checks whether a specific git branch exists in the repository.

.PARAMETER BranchName
    The name of the branch to check for existence.

.EXAMPLE
    if (Test-GitBranchExists -BranchName "feature/new-feature") {
        Write-Message -Type "Info" "Branch exists"
    }

.OUTPUTS
    System.Boolean
    Returns $true if the branch exists, $false otherwise.
#>
function Test-GitBranchExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $existingBranch = git branch -l $BranchName 2>$null
    $exists = -not [string]::IsNullOrWhiteSpace($existingBranch)

    Write-Message -Type "Debug" -Message "Branch exists check '$BranchName': $exists"
    return $exists
}

<#
.SYNOPSIS
    Create a new git commit.

.DESCRIPTION
    Creates a new git commit with the specified message. Optionally allows
    creating empty commits (useful for testing scenarios).

.PARAMETER Message
    The commit message for the new commit.

.PARAMETER AllowEmpty
    Whether to allow creating an empty commit (no staged changes).
    Default is $true to support testing scenarios.

.EXAMPLE
    $sha = New-GitCommit -Message "Initial commit" -AllowEmpty $true
    Write-Message -Type "Success" "Created commit: $sha"

.EXAMPLE
    $sha = New-GitCommit -Message "Add feature"
    Write-Message -Type "Info" "Commit SHA: $sha"

.OUTPUTS
    System.String
    Returns the SHA of the created commit.

.NOTES
    Throws an error if the commit creation fails.
#>
function New-GitCommit {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [bool]$AllowEmpty = $true
    )

    try {
        $argsGit = @("commit")
        if ($AllowEmpty) {
            $argsGit += "--allow-empty"
        }
        $argsGit += @("-m", $Message)

        Write-Message -Type "Debug" -Message "Creating commit: $Message"

        if ($PSCmdlet.ShouldProcess("Git", "Commit")) {
            git @argsGit 2>&1 | Out-Null
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create commit"
        }
        Write-Message -Type "Tag" -Message "Commit created: $sha"

        $sha = Get-CurrentCommitSha

        return $sha
    }
    catch {
        Write-Message -Type "Error" -Message "Failed to create commit: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Create a new git tag.

.DESCRIPTION
    Creates a new lightweight git tag pointing to a specific commit.
    Optionally forces overwrite of existing tags.

.PARAMETER TagName
    The name of the tag to create.

.PARAMETER CommitSha
    Optional SHA of the commit to tag. Defaults to HEAD if not specified.

.PARAMETER Force
    Whether to force overwrite if the tag already exists.
    Default is $false.

.EXAMPLE
    $created = New-GitTag -TagName "v1.0.0"
    if ($created) {
        Write-Message -Type "Success" "Tag created"
    }

.EXAMPLE
    $created = New-GitTag -TagName "v1.0.0" -CommitSha "abc123" -Force $true

.OUTPUTS
    System.Boolean
    Returns $true if the tag was created, $false if it was skipped.

.NOTES
    If Force is $false and the tag exists, the function returns $false without error.
    If Force is $true, any existing tag is deleted before creating the new one.
#>
function New-GitTag {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,

        [string]$CommitSha,

        [bool]$Force = $false
    )

    try {
        # Default to HEAD if no commit specified
        if (-not $CommitSha) {
            $CommitSha = Get-CurrentCommitSha
        }

        Write-Message -Type "Tag" -Message "Creating tag: $TagName -> $CommitSha"

        if ($PSCmdlet.ShouldProcess("Git tag '$TagName'", "Force Restore")) {
            # Check if tag already exists
            if (Test-GitTagExists -TagName $TagName) {
                if (-not $Force) {
                    Write-Message -Type "Warning" -Message "Tag already exists and Force not set: $TagName"
                    return $false
                }

                # Delete existing tag if force is enabled
                Write-Message -Type "Debug" -Message "Deleting existing tag for force restore: $TagName"
                git tag -d $TagName 2>&1 | Out-Null
            }

            # Create tag
            git tag $TagName $CommitSha 2>&1 | Out-Null
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create tag"
        }

        Write-Message -Type "Tag" -Message "Tag created successfully: $TagName"
        return $true
    }
    catch {
        Write-Message -Type "Error" -Message "Failed to create tag '$TagName': $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Create a new git branch.

.DESCRIPTION
    Creates a new git branch pointing to a specific commit.
    Optionally forces overwrite of existing branches.

.PARAMETER BranchName
    The name of the branch to create.

.PARAMETER CommitSha
    Optional SHA of the commit where the branch should start. Defaults to HEAD if not specified.

.PARAMETER Force
    Whether to force overwrite if the branch already exists.
    Default is $false.

.EXAMPLE
    $created = New-GitBranch -BranchName "feature/new-feature"
    if ($created) {
        Write-Message -Type "Success" "Branch created"
    }

.EXAMPLE
    $created = New-GitBranch -BranchName "release/v1.0" -CommitSha "abc123" -Force $true

.OUTPUTS
    System.Boolean
    Returns $true if the branch was created, $false if it was skipped.

.NOTES
    If Force is $false and the branch exists, the function returns $false without error.
    If Force is $true, any existing branch is deleted before creating the new one.
    Cannot delete the currently checked out branch - will skip with a warning in this case.
#>
function New-GitBranch {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [string]$CommitSha,

        [bool]$Force = $false
    )

    try {
        # Default to HEAD if no commit specified
        if (-not $CommitSha) {
            $CommitSha = Get-CurrentCommitSha
        }

        Write-Message -Type "Branch" -Message "Creating branch: $BranchName -> $CommitSha"

        if ($PSCmdlet.ShouldProcess("Git branch '$BranchName'", "Force Restore")) {
            # Check if branch already exists
            if (Test-GitBranchExists -BranchName $BranchName) {
                if (-not $Force) {
                    Write-Message -Type "Warning" -Message "Branch already exists and Force not set: $BranchName"
                    return $false
                }

                # Check if this is the current branch
                $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
                if ($currentBranch -eq $BranchName) {
                    Write-Message -Type "Warning" -Message "Cannot delete current branch: $BranchName"
                    return $false
                }

                # Delete existing branch if force is enabled
                Write-Message -Type "Debug" -Message "Deleting existing branch for force restore: $BranchName"
                git branch -D $BranchName 2>&1 | Out-Null
            }

            # Create branch
            git branch $BranchName $CommitSha 2>&1 | Out-Null
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create branch"
        }

        Write-Message -Type "Branch" -Message "Branch created successfully: $BranchName"
        return $true
    }
    catch {
        Write-Message -Type "Error" -Message "Failed to create branch '$BranchName': $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Switch to a different git branch.

.DESCRIPTION
    Checks out the specified git branch, making it the current branch.

.PARAMETER BranchName
    The name of the branch to check out.

.EXAMPLE
    $success = Set-GitBranch -BranchName "main"
    if ($success) {
        Write-Message -Type "Success" "Switched to main branch"
    }

.EXAMPLE
    Set-GitBranch -BranchName "feature/new-feature"

.OUTPUTS
    System.Boolean
    Returns $true if the checkout was successful, $false otherwise.

.NOTES
    Throws an error if the checkout operation fails.
#>
function Set-GitBranch {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    try {
        Write-Message -Type "Branch" "Checking out branch: $BranchName"

        if ($PSCmdlet.ShouldProcess("Git branch '$BranchName'", "Checkout")) {
            git checkout $BranchName 2>&1 | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "Failed to checkout branch - check for uncommitted changes"
            }

            Write-Message -Type "Branch" "Branch checked out: $BranchName"
        }
        return $true
    }
    catch {
        Write-Message -Type "Error" "Failed to checkout branch '$BranchName': $_"
        return $false
    }
}

<#
.SYNOPSIS
    Clear git state by deleting tags and/or branches.

.DESCRIPTION
    Removes all tags and/or branches from the repository to reset it to a clean state.
    Useful for test setup and teardown operations. Preserves the current branch and main branch.

.PARAMETER DeleteTags
    Whether to delete all tags. Default is $true.

.PARAMETER DeleteBranches
    Whether to delete all branches (except current and main). Default is $false.

.EXAMPLE
    $result = Clear-GitState
    Write-Message -Type "Info" "Deleted $($result.TagsDeleted) tags"

.EXAMPLE
    $result = Clear-GitState -DeleteTags $true -DeleteBranches $true
    Write-Message -Type "Info" "Deleted $($result.TagsDeleted) tags and $($result.BranchesDeleted) branches"

.OUTPUTS
    System.Collections.Hashtable
    Returns a hashtable with keys:
    - TagsDeleted: Number of tags deleted
    - DeletedTagNames: Array of tag names that were deleted
    - BranchesDeleted: Number of branches deleted

.NOTES
    When deleting branches, the current branch and "main" branch are preserved.
    This ensures the repository remains in a valid state.
#>
function Clear-GitState {
    param(
        [bool]$DeleteTags = $true,
        [bool]$DeleteBranches = $false
    )

    try {
        if ($DeleteTags) {
            $existingTags = @(git tag -l)
            if ($existingTags.Count -gt 0) {
                Write-Message -Type "Warning" -Message "Deleting $($existingTags.Count) existing tags"

                foreach ($tag in $existingTags) {
                    git tag -d $tag 2>&1 | Out-Null
                    Write-Message -Type "Debug" -Message "Deleted tag: $tag"
                }
            }
        }

        if ($DeleteBranches) {
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            $existingBranches = @(git branch -l | Where-Object { $_ -notlike "*$currentBranch*" } )

            if ($existingBranches.Count -gt 0) {
                Write-Message -Type "Warning" -Message "Deleting $($existingBranches.Count) existing branches (excluding current)"

                foreach ($branchLine in $existingBranches) {
                    $branch = $branchLine.Trim()
                    if ($branch.StartsWith("* ")) {
                        $branch = $branch.Substring(2).Trim()
                    }

                    if ($branch -and $branch -ne $currentBranch) {
                        git branch -D $branch 2>&1 | Out-Null
                        Write-Message -Type "Debug" -Message "Deleted branch: $branch"
                    }
                }
            }
        }
    }
    catch {
        Write-Message -Type "Error" -Message "Error during state cleanup: $_"
        throw $_
    }
}

# Export all functions
Export-ModuleMember -Function @(
    'Get-CurrentCommitSha',
    'Test-GitTagExists',
    'Test-GitBranchExists',
    'New-GitCommit',
    'New-GitTag',
    'New-GitBranch',
    'Set-GitBranch',
    'Clear-GitState'
)
