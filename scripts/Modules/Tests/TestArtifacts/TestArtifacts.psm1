# TestArtifacts.psm1

<#
.SYNOPSIS
    Export test results to JSON file.

.DESCRIPTION
    Saves test report to system temp logs directory.

.PARAMETER TestResults
    Array of test result objects

.PARAMETER OutputPath
    Optional output path (defaults to timestamped file)

.EXAMPLE
    $reportPath = Export-TestReport -TestResults $results

.NOTES
    Returns path to exported report file.
#>
function Export-TestReport {
    param(
        [Parameter(Mandatory = $true)]
        [array]$TestResults,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    # Generate output path if not provided
    if (-not $OutputPath) {
        $logsDir = $TestLogsDirectory
        New-TestStateDirectory | Out-Null
        
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $OutputPath = Join-Path $logsDir "test-report-$timestamp.json"
    }
    
    # Calculate statistics
    $totalTests = $TestResults.Count
    $passedTests = @($TestResults | Where-Object { $_.Success }).Count
    $failedTests = $totalTests - $passedTests
    # Convert Duration to seconds (or milliseconds) before summing
    $totalDuration = ($TestResults | ForEach-Object {
        # If Duration is a string, convert to TimeSpan first
        if ($_ -and $_.Duration -is [string]) {
            [TimeSpan]::Parse($_.Duration).TotalSeconds
        } elseif ($_ -and $_.Duration -is [TimeSpan]) {
            $_.Duration.TotalSeconds
        } else {
            0
        }
    } | Measure-Object -Sum).Sum

    
    # Create report object
    $report = @{
        timestamp     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        totalTests    = $totalTests
        passedTests   = $passedTests
        failedTests   = $failedTests
        totalDuration = $totalDuration.TotalSeconds
        tests         = $TestResults
    }
    
    # Export to JSON
    try {
        $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-Message -Type "Info" "Test report exported to: $OutputPath"
        return $OutputPath
    } catch {
        Write-Message -Type "Warning" "Failed to export test report: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Generate test-tags.txt file for bump-version.yml workflow.

.DESCRIPTION
    Exports git tags in format expected by bump-version.yml (lines 58-79).

.PARAMETER OutputPath
    Custom output path (defaults to temp directory test-tags.txt).

.PARAMETER Tags
    Array of tag names to export (defaults to all tags).

.EXAMPLE
    Export-TestTagsFile -Tags @("v0.2.1", "v1.0.0")

.NOTES
    Format: 'tag_name commit_sha' (one per line). Compatible with bump-version.yml tag restoration logic.
#>
function Export-TestTagsFile {
    param(
        [string]$OutputPath,
        [string[]]$Tags
    )

    try {
        # Default output path if not provided
        if (-not $OutputPath) {
            $testStateDir = New-TestStateDirectory
            $OutputPath = Join-Path $testStateDir $TestTagsFile
        }

        Write-Message -Type "Info" "Generating test-tags.txt file"
        Write-Message -Type "Debug" "Output path: $OutputPath"

        # If no tags specified, get all tags
        if (-not $Tags -or $Tags.Count -eq 0) {
            $Tags = @(git tag -l)
            Write-Message -Type "Debug" "No tags specified, using all repository tags: $($Tags.Count) tags"
        }

        # Build file content
        $fileContent = @()

        foreach ($tag in $Tags) {
            try {
                $sha = git rev-list -n 1 $tag 2>$null
                
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
                    $fileContent += "$tag $sha"
                    Write-Message -Type "Tag" "Exporting tag: $tag -> $sha"
                } else {
                    Write-Message -Type "Warning" "Failed to get SHA for tag: $tag"
                }
            } catch {
                Write-Message -Type "Warning" "Error exporting tag '$tag': $_"
                continue
            }
        }

        # Ensure output directory exists
        $outputDir = Split-Path $OutputPath -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            Write-Message -Type "Debug" "Created output directory: $outputDir"
        }

        # Write to file
        $fileContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        
        Write-Message -Type "Success" "Test-tags.txt generated with $($fileContent.Count) tags"
        Write-Message -Type "Debug" "File path: $OutputPath"

        return $OutputPath
    } catch {
        Write-Message -Type "Error" "Failed to export test tags file: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Export git branches to test-branches.txt file.

.DESCRIPTION
    Exports git branch names and their commit SHAs to a test-branches.txt file in the test state directory.
    This file is used by workflows to restore branches to their original state during testing.
    
    Format: 'branch_name commit_sha' (one per line)
    
    If no branches are specified, all branches in the repository are exported.
    The function handles branch name cleanup (removes asterisks from current branch marker).

.PARAMETER OutputPath
    Custom output path for the test-branches.txt file.
    Example: "C:\temp\test-state\test-branches.txt"
    If not provided, defaults to <temp>/d-flows-test-state-<guid>/test-branches.txt

.PARAMETER Branches
    Array of branch names to export.
    Example: @("main", "release/v1", "develop")
    If not provided or empty, all branches in the repository are exported.

.EXAMPLE
    Export-TestBranchesFile -Branches @("main", "release/v1")

.EXAMPLE
    Export-TestBranchesFile -Branches @("main", "release/v1") -OutputPath "C:\temp\test-branches.txt"

.EXAMPLE
    # Export all branches (no branches specified)
    Export-TestBranchesFile

.NOTES
    Format: 'branch_name commit_sha' (one per line). Compatible with workflow branch restoration logic.
#>
function Export-TestBranchesFile {
    param(
        [string]$OutputPath,
        [string[]]$Branches
    )

    try {
        # Default output path if not provided
        if (-not $OutputPath) {
            $testStateDir = New-TestStateDirectory
            $OutputPath = Join-Path $testStateDir $TestBranchesFile
        }

        Write-Message -Type "Info" "Generating test-branches.txt file"
        Write-Message -Type "Debug" "Output path: $OutputPath"

        # If no branches specified, get all branches
        if (-not $Branches -or $Branches.Count -eq 0) {
            $gitBranches = @(git branch -l)
            # Clean up branch names: remove asterisks and trim whitespace
            $Branches = @()
            foreach ($branch in $gitBranches) {
                $cleanBranch = $branch.TrimStart('*').Trim()
                # Skip detached HEAD or empty entries
                if ($cleanBranch -and $cleanBranch -notmatch '^\(HEAD') {
                    $Branches += $cleanBranch
                }
            }
            Write-Message -Type "Debug" "No branches specified, using all repository branches: $($Branches.Count) branches"
        }

        # Build file content
        $fileContent = @()

        foreach ($branch in $Branches) {
            try {
                $sha = git rev-parse $branch 2>$null
                
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
                    $fileContent += "$branch $sha"
                    Write-Message -Type "Branch" "Exporting branch: $branch -> $sha"
                } else {
                    Write-Message -Type "Warning" "Failed to get SHA for branch: $branch"
                }
            } catch {
                Write-Message -Type "Warning" "Error exporting branch '$branch': $_"
                continue
            }
        }

        # Ensure output directory exists
        $outputDir = Split-Path $OutputPath -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            Write-Message -Type "Debug" "Created output directory: $outputDir"
        }

        # Write to file
        $fileContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        
        Write-Message -Type "Success" "Test-branches.txt generated with $($fileContent.Count) branches"
        Write-Message -Type "Debug" "File path: $OutputPath"

        return $OutputPath
    } catch {
        Write-Message -Type "Error" "Failed to export test branches file: $_"
        throw $_
    }
}

<#
.SYNOPSIS
    Export test commits to a git bundle file.

.DESCRIPTION
    Creates a git bundle containing all commits referenced by test tags and branches.
    This ensures commit objects are available in workflow containers for tag/branch restoration.
    
    The bundle is designed to be unbundled in the workflow before restoring tags, ensuring
    all commit SHAs exist in the repository.

.PARAMETER OutputPath
    Optional path where the bundle file should be saved.
    Defaults to test-commits.bundle in the test state directory.

.PARAMETER Tags
    Optional array of tag names to include in the bundle.
    If not specified, all current tags will be bundled.

.PARAMETER Branches
    Optional array of branch names to include in the bundle.
    If not specified, all current branches will be bundled.

.EXAMPLE
    Export-TestCommitsBundle
    Exports all tags and branches to test-commits.bundle in the test state directory.

.EXAMPLE
    Export-TestCommitsBundle -OutputPath "C:\temp\commits.bundle"
    Exports to a custom path.

.EXAMPLE
    Export-TestCommitsBundle -Tags @("v0.2.1", "v0.2.2") -Branches @("main", "release/v0")
    Exports specific tags and branches.

.NOTES
    This function mirrors the pattern of Export-TestTagsFile and Export-TestBranchesFile.
    The bundle format is compatible with bump-version.yml workflow restoration logic.
    Empty repositories (no refs) will create an empty bundle file for consistency.
    
    The workflow unbundles commits before restoring tags using:
    git bundle unbundle test-commits.bundle
#>
function Export-TestCommitsBundle {
    param(
        [string]$OutputPath,
        [string[]]$Tags,
        [string[]]$Branches
    )

    try {
        # Default output path if not provided
        if (-not $OutputPath) {
            $testStateDir = New-TestStateDirectory
            $OutputPath = Join-Path $testStateDir $TestCommitsBundle
        }

        Write-Message -Type "Info" "Generating test-commits.bundle file"
        
        # Collect all refs to bundle
        $allRefs = @()
        
        # If no tags specified, get all tags
        if (-not $Tags -or $Tags.Count -eq 0) {
            $gitTags = @(git tag -l 2>$null)
            if ($gitTags.Count -gt 0) {
                $allRefs += $gitTags
                Write-Message -Type "Tag" "Including $($gitTags.Count) tags in bundle"
            }
        } else {
            $allRefs += $Tags
            Write-Message -Type "Tag" "Including $($Tags.Count) specified tags in bundle"
        }
        
        # If no branches specified, get all branches
        if (-not $Branches -or $Branches.Count -eq 0) {
            $gitBranches = @(git branch -l 2>$null)
            # Clean up branch names: remove asterisks and trim whitespace
            $cleanBranches = @()
            foreach ($branch in $gitBranches) {
                $cleanBranch = $branch.TrimStart('*').Trim()
                # Skip detached HEAD or empty entries
                if ($cleanBranch -and $cleanBranch -notmatch '^\(HEAD') {
                    $cleanBranches += $cleanBranch
                }
            }
            if ($cleanBranches.Count -gt 0) {
                $allRefs += $cleanBranches
                Write-Message -Type "Branch" "Including $($cleanBranches.Count) branches in bundle"
            }
        } else {
            $allRefs += $Branches
            Write-Message -Type "Branch" "Including $($Branches.Count) specified branches in bundle"
        }
        
        # Handle empty repository (no refs to bundle)
        if ($allRefs.Count -eq 0) {
            Write-Message -Type "Warning" "No refs found to bundle (empty repository or no tags/branches)"
            # Create an empty file to maintain backup structure
            "" | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
            Write-Message -Type "Debug" "Created empty bundle file: $OutputPath"
            return $OutputPath
        }

        Write-Message -Type "Debug" "Bundling $($allRefs.Count) refs"

        # Create git bundle with explicit ref list
        $bundleArgs = @('bundle', 'create', $OutputPath) + $allRefs
        
        $gitOutput = & git @bundleArgs 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            # If failed, write the captured output to the console
            $gitOutput | ForEach-Object { Write-Host $_ }
            throw "Git bundle create failed with exit code: $exitCode"
        }

        Write-Message -Type "Success" "Test-commits.bundle generated with $($allRefs.Count) refs"
        Write-Message -Type "Debug" "File path: $OutputPath"

        return $OutputPath
    } catch {
        Write-Message -Type "Error" "Failed to export test commits bundle: $_"
        throw $_
    }
}

# Explicite import is not necessary
# Import-Module RepositoryUtils -ErrorAction Stop

$TestTagsFile = "test-tags.txt"
$TestBranchesFile = "test-branches.txt"
$TestCommitsBundle = "test-commits.bundle"
$IntegrationTestsDirectory = "tests/integration"
# defined in RepositoryUtils module
$TestStateDirectory = Get-TestStateBasePath
$TestLogsDirectory = Join-Path (Get-TestStateBasePath) "logs"
$BackupDirectory = Get-BackupBasePath

Write-Message -Type "Debug" "Test State Directory: $TestStateDirectory"
Write-Message -Type "Debug" "Files: $TestTagsFile $TestBranchesFile $TestCommitsBundle"
Write-Message -Type "Debug" "Test Logs Directory: $TestLogsDirectory"
Write-Message -Type "Debug" "Integration Tests Directory: $IntegrationTestsDirectory"
Write-Message -Type "Debug" "Backup Directory: $BackupDirectory"

Export-ModuleMember -Function * -Variable 'TestStateDirectory','TestTagsFile','TestBranchesFile','TestCommitsBundle','IntegrationTestsDirectory','TestLogsDirectory','BackupDirectory'
