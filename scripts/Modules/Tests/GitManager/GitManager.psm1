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
    Write-Message -Type "Debug" "Getting current commit SHA"
    
    $sha = git rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Message -Type "Error" "Failed to get current commit SHA. Repository may have no commits."
        throw "Failed to get current commit SHA"
    }
    
    Write-Message -Type "Debug" "Current commit SHA: $sha"
    return $sha
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
    
    Write-Message -Type "Debug" "Checking if tag exists: $TagName"
    $existingTag = git tag -l $TagName
    return [bool]$existingTag
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
    
    Write-Message -Type "Debug" "Checking if branch exists: $BranchName"
    $existingBranch = git branch -l $BranchName
    return [bool]$existingBranch
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [bool]$AllowEmpty = $true
    )
    
    Write-Message -Type "Debug" "Creating commit with message: $Message"
    
    try {
        $commitArgs = @('commit', '-m', $Message)
        if ($AllowEmpty) {
            $commitArgs += '--allow-empty'
        }
        
        & git @commitArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Git commit failed with exit code: $LASTEXITCODE"
        }
        
        $sha = Get-CurrentCommitSha
        Write-Message -Type "Tag" "Created commit: $Message -> $sha"
        
        return $sha
    } catch {
        Write-Message -Type "Error" "Failed to create commit: $_"
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,
        
        [Parameter(Mandatory = $false)]
        [string]$CommitSha,
        
        [Parameter(Mandatory = $false)]
        [bool]$Force = $false
    )
    
    try {
        # Default to HEAD if no commit specified
        if (-not $CommitSha) {
            $CommitSha = Get-CurrentCommitSha
        }
        
        Write-Message -Type "Debug" "Creating tag: $TagName at $CommitSha"
        
        # Check if tag already exists
        $tagExists = Test-GitTagExists -TagName $TagName
        
        if ($tagExists -and -not $Force) {
            Write-Message -Type "Warning" "Tag already exists: $TagName (use -Force to overwrite)"
            return $false
        }
        
        if ($tagExists -and $Force) {
            Write-Message -Type "Debug" "Deleting existing tag: $TagName"
            git tag -d $TagName | Out-Null
        }
        
        # Create the tag
        git tag $TagName $CommitSha
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create tag: $TagName"
        }
        
        Write-Message -Type "Tag" "Created tag: $TagName -> $CommitSha"
        return $true
    } catch {
        Write-Message -Type "Error" "Error creating tag '$TagName': $_"
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,
        
        [Parameter(Mandatory = $false)]
        [string]$CommitSha,
        
        [Parameter(Mandatory = $false)]
        [bool]$Force = $false
    )
    
    try {
        # Default to HEAD if no commit specified
        if (-not $CommitSha) {
            $CommitSha = Get-CurrentCommitSha
        }
        
        Write-Message -Type "Debug" "Creating branch: $BranchName at $CommitSha"
        
        # Check if branch already exists
        $branchExists = Test-GitBranchExists -BranchName $BranchName
        
        if ($branchExists -and -not $Force) {
            Write-Message -Type "Warning" "Branch already exists: $BranchName (use -Force to overwrite)"
            return $false
        }
        
        if ($branchExists -and $Force) {
            # Get current branch to avoid deleting it
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            
            if ($currentBranch -eq $BranchName) {
                Write-Message -Type "Warning" "Cannot delete current branch: $BranchName"
                return $false
            }
            
            Write-Message -Type "Debug" "Deleting existing branch: $BranchName"
            git branch -D $BranchName | Out-Null
        }
        
        # Create the branch
        git branch $BranchName $CommitSha
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create branch: $BranchName"
        }
        
        Write-Message -Type "Branch" "Created branch: $BranchName -> $CommitSha"
        return $true
    } catch {
        Write-Message -Type "Error" "Error creating branch '$BranchName': $_"
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )
    
    try {
        Write-Message -Type "Debug" "Checking out branch: $BranchName"
        
        git checkout $BranchName 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Message -Type "Error" "Failed to checkout branch: $BranchName"
            throw "Failed to checkout branch: $BranchName"
        }
        
        Write-Message -Type "Branch" "Checked out branch: $BranchName"
        return $true
    } catch {
        Write-Message -Type "Error" "Error checking out branch '$BranchName': $_"
        throw $_
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
        [Parameter(Mandatory = $false)]
        [bool]$DeleteTags = $true,
        
        [Parameter(Mandatory = $false)]
        [bool]$DeleteBranches = $false
    )
    
    try {
        $tagsDeleted = 0
        $deletedTagNames = @()
        $branchesDeleted = 0
        
        # Delete all tags if requested
        if ($DeleteTags) {
            Write-Message -Type "Warning" "Deleting all git tags"
            
            $tags = @(git tag -l)
            $deletedTagNames = $tags
            
            foreach ($tag in $tags) {
                git tag -d $tag | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $tagsDeleted++
                    Write-Message -Type "Debug" "Deleted tag: $tag"
                }
            }
            
            Write-Message -Type "Info" "Deleted $tagsDeleted tags"
        }
        
        # Delete all branches except current and main if requested
        if ($DeleteBranches) {
            Write-Message -Type "Warning" "Deleting all git branches (except current and main)"
            
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            $branches = @(git branch --format='%(refname:short)')
            
            foreach ($branch in $branches) {
                # Skip current branch and main
                if ($branch -eq $currentBranch -or $branch -eq "main") {
                    Write-Message -Type "Debug" "Skipping branch: $branch (protected)"
                    continue
                }
                
                git branch -D $branch | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $branchesDeleted++
                    Write-Message -Type "Debug" "Deleted branch: $branch"
                }
            }
            
            Write-Message -Type "Info" "Deleted $branchesDeleted branches"
        }
        
        return @{
            TagsDeleted      = $tagsDeleted
            DeletedTagNames  = $deletedTagNames
            BranchesDeleted  = $branchesDeleted
        }
    } catch {
        Write-Message -Type "Error" "Failed to clear git state: $_"
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
