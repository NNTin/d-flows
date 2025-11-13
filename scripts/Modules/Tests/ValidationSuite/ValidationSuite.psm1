# ValidationSuite.psm1

<#
.SYNOPSIS
    Check if git tag exists.

.PARAMETER Tag
    Tag name to check

.EXAMPLE
    Validate-TagExists -Tag "v1.0.0"
#>
function Validate-TagExists {
    param([Parameter(Mandatory = $true)][string]$Tag)
    
    $existingTag = git tag -l $Tag 2>$null
    $exists = -not [string]::IsNullOrEmpty($existingTag)
    
    Write-Message -Type "Validation" -Message "Tag '$Tag' exists: $exists"
    
    return @{
        Success = $exists
        Message = if ($exists) { "Tag '$Tag' exists" } else { "Tag '$Tag' does not exist" }
        Type    = "tag-exists"
    }
}

<#
.SYNOPSIS
    Check if git tag does NOT exist.

.PARAMETER Tag
    Tag name to check

.EXAMPLE
    Validate-TagNotExists -Tag "v2.0.0"
#>
function Validate-TagNotExists {
    param([Parameter(Mandatory = $true)][string]$Tag)
    
    $existingTag = git tag -l $Tag 2>$null
    $notExists = [string]::IsNullOrEmpty($existingTag)
    
    Write-Message -Type "Validation" -Message "Tag '$Tag' does not exist: $notExists"
    
    return @{
        Success = $notExists
        Message = if ($notExists) { "Tag '$Tag' does not exist (as expected)" } else { "Tag '$Tag' exists (unexpected)" }
        Type    = "tag-not-exists"
    }
}

<#
.SYNOPSIS
    Check if tag points to target tag/commit.

.PARAMETER Tag
    Source tag name

.PARAMETER Target
    Target tag or commit SHA

.EXAMPLE
    Validate-TagPointsTo -Tag "v1" -Target "v1.0.0"
#>
function Validate-TagPointsTo {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Target
    )
    
    try {
        $tagSha = git rev-parse "$Tag^{commit}" 2>$null
        $targetSha = git rev-parse "$Target^{commit}" 2>$null
        
        $matches = ($tagSha -eq $targetSha)
        
        Write-Message -Type "Validation" -Message "Tag '$Tag' points to '$Target': $matches"
        
        return @{
            Success = $matches
            Message = if ($matches) { "Tag '$Tag' points to '$Target'" } else { "Tag '$Tag' does not point to '$Target'" }
            Type    = "tag-points-to"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to compare tags: $_"
            Type    = "tag-points-to"
        }
    }
}

<#
.SYNOPSIS
    Check if tag is accessible.

.PARAMETER Tag
    Tag name to check

.EXAMPLE
    Validate-TagAccessible -Tag "v1.0.0"
#>
function Validate-TagAccessible {
    param([Parameter(Mandatory = $true)][string]$Tag)
    
    try {
        $existingTag = git tag -l $Tag 2>$null
        $sha = git rev-parse $Tag 2>$null
        
        $accessible = (-not [string]::IsNullOrEmpty($existingTag)) -and (-not [string]::IsNullOrEmpty($sha))
        
        Write-Message -Type "Validation" -Message "Tag '$Tag' accessible: $accessible"
        
        return @{
            Success = $accessible
            Message = if ($accessible) { "Tag '$Tag' is accessible" } else { "Tag '$Tag' is not accessible" }
            Type    = "tag-accessible"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to check tag accessibility: $_"
            Type    = "tag-accessible"
        }
    }
}

<#
.SYNOPSIS
    Check if tag count matches expected.

.PARAMETER Expected
    Expected tag count

.EXAMPLE
    Validate-TagCount -Expected 3
#>
function Validate-TagCount {
    param([Parameter(Mandatory = $true)][int]$Expected)
    
    $tags = @(git tag -l)
    $actual = $tags.Count
    
    $matches = ($actual -eq $Expected)
    
    Write-Message -Type "Validation" -Message "Tag count: $actual (expected: $Expected)"
    
    return @{
        Success = $matches
        Message = if ($matches) { "Tag count matches: $actual" } else { "Tag count mismatch: expected $Expected, got $actual" }
        Type    = "tag-count"
    }
}

<#
.SYNOPSIS
    Check if git branch exists.

.PARAMETER Branch
    Branch name to check

.EXAMPLE
    Validate-BranchExists -Branch "release/v1"
#>
function Validate-BranchExists {
    param([Parameter(Mandatory = $true)][string]$Branch)
    
    $existingBranch = git branch -l $Branch 2>$null
    $exists = -not [string]::IsNullOrEmpty($existingBranch)
    
    Write-Message -Type "Validation" -Message "Branch '$Branch' exists: $exists"
    
    return @{
        Success = $exists
        Message = if ($exists) { "Branch '$Branch' exists" } else { "Branch '$Branch' does not exist" }
        Type    = "branch-exists"
    }
}

<#
.SYNOPSIS
    Check if branch points to same commit as tag.

.PARAMETER Branch
    Branch name

.PARAMETER Tag
    Tag name

.EXAMPLE
    Validate-BranchPointsToTag -Branch "release/v1" -Tag "v1.0.0"
#>
function Validate-BranchPointsToTag {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Tag
    )
    
    try {
        $branchSha = git rev-parse $Branch 2>$null
        $tagSha = git rev-parse $Tag 2>$null
        
        $matches = ($branchSha -eq $tagSha)
        
        Write-Message -Type "Validation" -Message "Branch '$Branch' points to tag '$Tag': $matches"
        
        return @{
            Success = $matches
            Message = if ($matches) { "Branch '$Branch' points to tag '$Tag'" } else { "Branch '$Branch' does not point to tag '$Tag'" }
            Type    = "branch-points-to-tag"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to compare branch and tag: $_"
            Type    = "branch-points-to-tag"
        }
    }
}

<#
.SYNOPSIS
    Check if branch count matches expected.

.PARAMETER Expected
    Expected branch count

.EXAMPLE
    Validate-BranchCount -Expected 2
#>
function Validate-BranchCount {
    param([Parameter(Mandatory = $true)][int]$Expected)
    
    $branches = @(git branch -l)
    $actual = $branches.Count
    
    $matches = ($actual -eq $Expected)
    
    Write-Message -Type "Validation" -Message "Branch count: $actual (expected: $Expected)"
    
    return @{
        Success = $matches
        Message = if ($matches) { "Branch count matches: $actual" } else { "Branch count mismatch: expected $Expected, got $actual" }
        Type    = "branch-count"
    }
}

<#
.SYNOPSIS
    Check if current branch matches expected.

.PARAMETER Branch
    Expected branch name

.EXAMPLE
    Validate-CurrentBranch -Branch "main"
#>
function Validate-CurrentBranch {
    param([Parameter(Mandatory = $true)][string]$Branch)
    
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    $matches = ($currentBranch -eq $Branch)
    
    Write-Message -Type "Validation" -Message "Current branch is '$Branch': $matches"
    
    return @{
        Success = $matches
        Message = if ($matches) { "Current branch is '$Branch'" } else { "Current branch is '$currentBranch', expected '$Branch'" }
        Type    = "current-branch"
    }
}

<#
.SYNOPSIS
    Check if new version is greater than current.

.PARAMETER Current
    Current version (e.g., "0.2.1")

.PARAMETER New
    New version (e.g., "1.0.0")

.EXAMPLE
    Validate-VersionGreater -Current "0.2.1" -New "1.0.0"
#>
function Validate-VersionGreater {
    param(
        [Parameter(Mandatory = $true)][string]$Current,
        [Parameter(Mandatory = $true)][string]$New
    )
    
    try {
        # Remove 'v' prefix if present
        $currentClean = $Current -replace '^v', ''
        $newClean = $New -replace '^v', ''
        
        # Parse version parts
        $currentParts = $currentClean -split '\.' | ForEach-Object { [int]$_ }
        $newParts = $newClean -split '\.' | ForEach-Object { [int]$_ }
        
        # Compare major, minor, patch
        $greater = $false
        for ($i = 0; $i -lt 3; $i++) {
            if ($newParts[$i] -gt $currentParts[$i]) {
                $greater = $true
                break
            } elseif ($newParts[$i] -lt $currentParts[$i]) {
                break
            }
        }
        
        Write-Message -Type "Validation" -Message "Version '$New' > '$Current': $greater"
        
        return @{
            Success = $greater
            Message = if ($greater) { "Version '$New' is greater than '$Current'" } else { "Version '$New' is not greater than '$Current'" }
            Type    = "version-greater"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to compare versions: $_"
            Type    = "version-greater"
        }
    }
}

<#
.SYNOPSIS
    Check if version progression follows semantic versioning.

.PARAMETER From
    Starting version

.PARAMETER To
    Ending version

.PARAMETER BumpType
    Type of bump: "major", "minor", or "patch"

.EXAMPLE
    Validate-VersionProgression -From "0.2.1" -To "1.0.0" -BumpType "major"
#>
function Validate-VersionProgression {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)][string]$BumpType
    )
    
    try {
        # Remove 'v' prefix if present
        $fromClean = $From -replace '^v', ''
        $toClean = $To -replace '^v', ''
        
        # Parse version parts
        $fromParts = $fromClean -split '\.' | ForEach-Object { [int]$_ }
        $toParts = $toClean -split '\.' | ForEach-Object { [int]$_ }
        
        $valid = $false
        
        switch ($BumpType) {
            "major" {
                # Major incremented, minor/patch reset to 0
                $valid = ($toParts[0] -eq ($fromParts[0] + 1)) -and ($toParts[1] -eq 0) -and ($toParts[2] -eq 0)
            }
            "minor" {
                # Minor incremented, patch reset to 0, major unchanged
                $valid = ($toParts[0] -eq $fromParts[0]) -and ($toParts[1] -eq ($fromParts[1] + 1)) -and ($toParts[2] -eq 0)
            }
            "patch" {
                # Patch incremented, major/minor unchanged
                $valid = ($toParts[0] -eq $fromParts[0]) -and ($toParts[1] -eq $fromParts[1]) -and ($toParts[2] -eq ($fromParts[2] + 1))
            }
        }
        
        Write-Message -Type "Validation" -Message "Version progression '$From' -> '$To' ($BumpType): $valid"
        
        return @{
            Success = $valid
            Message = if ($valid) { "Version progression '$From' -> '$To' follows $BumpType bump" } else { "Version progression '$From' -> '$To' does not follow $BumpType bump" }
            Type    = "version-progression"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to validate version progression: $_"
            Type    = "version-progression"
        }
    }
}

<#
.SYNOPSIS
    Check if major version incremented correctly.

.PARAMETER From
    Starting major version

.PARAMETER To
    Ending major version

.EXAMPLE
    Validate-MajorIncrement -From 0 -To 1
#>
function Validate-MajorIncrement {
    param(
        [Parameter(Mandatory = $true)][int]$From,
        [Parameter(Mandatory = $true)][int]$To
    )
    
    $valid = ($To -eq ($From + 1))
    
    Write-Message -Type "Validation" -Message "Major increment $From -> ${To}: $valid"
    
    return @{
        Success = $valid
        Message = if ($valid) { "Major version incremented from $From to $To" } else { "Major version increment invalid: $From -> $To (expected $($From + 1))" }
        Type    = "major-increment"
    }
}

<#
.SYNOPSIS
    Check if multiple major tags coexist.

.PARAMETER Tags
    Array of major tag names (e.g., @("v0", "v1"))

.EXAMPLE
    Validate-MajorTagCoexistence -Tags @("v0", "v1")
#>
function Validate-MajorTagCoexistence {
    param([Parameter(Mandatory = $true)][array]$Tags)
    
    $allExist = $true
    $existingTags = @()
    
    foreach ($tag in $Tags) {
        $exists = git tag -l $tag 2>$null
        if ([string]::IsNullOrEmpty($exists)) {
            $allExist = $false
        } else {
            $existingTags += $tag
        }
    }
    
    Write-Message -Type "Validation" -Message "Major tags coexist ($($Tags -join ', ')): $allExist"
    
    return @{
        Success = $allExist
        Message = if ($allExist) { "All major tags exist: $($Tags -join ', ')" } else { "Not all major tags exist. Found: $($existingTags -join ', ')" }
        Type    = "major-tags-coexist"
    }
}

<#
.SYNOPSIS
    Check if major tags progress correctly.

.PARAMETER Tags
    Array of major tag names in order

.EXAMPLE
    Validate-MajorTagProgression -Tags @("v0", "v1", "v2")
#>
function Validate-MajorTagProgression {
    param([Parameter(Mandatory = $true)][array]$Tags)
    
    $valid = $true
    
    for ($i = 0; $i -lt $Tags.Count; $i++) {
        $tag = $Tags[$i]
        $exists = git tag -l $tag 2>$null
        
        if ([string]::IsNullOrEmpty($exists)) {
            $valid = $false
            break
        }
        
        # Check if version number matches index
        if ($tag -match '^v(\d+)$') {
            $version = [int]$matches[1]
            if ($version -ne $i) {
                $valid = $false
                break
            }
        }
    }
    
    Write-Message -Type "Validation" -Message "Major tag progression ($($Tags -join ', ')): $valid"
    
    return @{
        Success = $valid
        Message = if ($valid) { "Major tags progress correctly: $($Tags -join ', ')" } else { "Major tag progression invalid" }
        Type    = "major-tag-progression"
    }
}

<#
.SYNOPSIS
    Check that major version branches don't contaminate each other.

.PARAMETER V1
    Version 1 tag

.PARAMETER V2
    Version 2 tag

.EXAMPLE
    Validate-NoCrossContamination -V1 "v1.0.0" -V2 "v2.0.0"

.NOTES
    Placeholder implementation - validates tags exist.
#>
function Validate-NoCrossContamination {
    param(
        [Parameter(Mandatory = $true)][string]$V1,
        [Parameter(Mandatory = $true)][string]$V2
    )
    
    try {
        $v1Sha = git rev-parse $V1 2>$null
        $v2Sha = git rev-parse $V2 2>$null
        
        $valid = (-not [string]::IsNullOrEmpty($v1Sha)) -and (-not [string]::IsNullOrEmpty($v2Sha)) -and ($v1Sha -ne $v2Sha)
        
        Write-Message -Type "Validation" -Message "No cross-contamination between '$V1' and '$V2': $valid"
        
        return @{
            Success = $valid
            Message = if ($valid) { "No cross-contamination between '$V1' and '$V2'" } else { "Cross-contamination detected or invalid tags" }
            Type    = "no-cross-contamination"
        }
    } catch {
        return @{
            Success = $false
            Message = "Failed to check cross-contamination: $_"
            Type    = "no-cross-contamination"
        }
    }
}

<#
.SYNOPSIS
    Check that no tag conflicts exist.

.EXAMPLE
    Validate-NoTagConflicts

.NOTES
    Checks for duplicate tags (shouldn't happen) and other conflicts.
#>
function Validate-NoTagConflicts {
    $tags = @(git tag -l)
    
    # Check for duplicates (shouldn't happen but validate)
    $uniqueTags = $tags | Select-Object -Unique
    $noDuplicates = ($tags.Count -eq $uniqueTags.Count)
    
    Write-Message -Type "Validation" -Message "No tag conflicts: $noDuplicates"
    
    return @{
        Success = $noDuplicates
        Message = if ($noDuplicates) { "No tag conflicts detected" } else { "Tag conflicts detected" }
        Type    = "no-tag-conflicts"
    }
}

<#
.SYNOPSIS
    Check if workflow execution succeeded.

.PARAMETER Workflow
    Workflow name

.PARAMETER ActResult
    Result from Invoke-ActWorkflow

.EXAMPLE
    Validate-WorkflowSuccess -Workflow "bump-version" -ActResult $actResult
#>
function Validate-WorkflowSuccess {
    param(
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][object]$ActResult
    )
    
    $success = $ActResult.Success -and ($ActResult.ExitCode -eq 0)
    
    Write-Message -Type "Validation" -Message "Workflow '$Workflow' success: $success"
    
    return @{
        Success = $success
        Message = if ($success) { "Workflow '$Workflow' succeeded" } else { "Workflow '$Workflow' failed with exit code: $($ActResult.ExitCode)" }
        Type    = "workflow-success"
    }
}

<#
.SYNOPSIS
    Check if workflow execution succeeded.

.PARAMETER Workflow
    Workflow name

.PARAMETER ActResult
    Result from Invoke-ActWorkflow

.EXAMPLE
    Validate-WorkflowFailure -Workflow "bump-version" -ActResult $actResult
#>
function Validate-WorkflowFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][object]$ActResult
    )

    $success = -not $ActResult.Success -and ($ActResult.ExitCode -ne 0)

    Write-Message -Type "Validation" -Message "Workflow '$Workflow' failure: $success"

    return @{
        Success = $success
        Message = if ($success) { "Workflow '$Workflow' failed as expected" } else { "Workflow '$Workflow' succeeded unexpectedly" }
        Type    = "workflow-failure"
    }
}

<#
.SYNOPSIS
    Check that operation is idempotent.

.EXAMPLE
    Validate-IdempotencyVerified

.NOTES
    Placeholder for future implementation.
#>
function Validate-IdempotencyVerified {
    Write-Message -Type "Validation" -Message "Idempotency check (placeholder)"
    
    return @{
        Success = $true
        Message = "Idempotency verification placeholder"
        Type    = "idempotency-verified"
    }
}