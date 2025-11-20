@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule           = 'GitManager.psm1'
    ModuleVersion        ='1.0.2'
    GUID                 = '4bd44232-beb2-4444-a5c5-a78af6d6243e'
    Author               = 'Tin Nguyen'
    CompanyName          = 'N/A'
    Copyright            = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description          = 'Provides git state management functions for creating and manipulating tags, branches, and commits during integration testing.'

    # Dependencies
    RequiredModules      = @('MessageUtils')

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport    = @(
        'Get-CurrentCommitSha',
        'Test-GitTagExists',
        'Test-GitBranchExists',
        'New-GitCommit',
        'New-GitTag',
        'New-GitBranch',
        'Set-GitBranch',
        'Clear-GitState'
    )

    # ──────────────────────────────
    # PowerShell compatibility
    # ──────────────────────────────
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # ──────────────────────────────
    # Private data
    # ──────────────────────────────
    PrivateData          = @{
        PSData = @{
            Tags       = @('Git', 'Testing', 'Integration', 'Branches', 'Tags', 'Commits', 'State', 'Management')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
