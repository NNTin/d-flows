@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule           = 'GitSnapshot.psm1'
    ModuleVersion        ='1.1.1'
    GUID                 = '56a06e8b-29bd-4f64-b93d-c6175321f811'
    Author               = 'Tin Nguyen'
    CompanyName          = 'N/A'
    Copyright            = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description          = 'Provides functions for backing up and restoring git repository state including tags, branches, and commits for integration testing.'

    # Dependencies
    RequiredModules      = @('MessageUtils', 'RepositoryUtils')

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport    = @(
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
            Tags       = @(
                'git',
                'backup',
                'restore',
                'testing',
                'integration-testing',
                'version-control',
                'repository-state',
                'snapshot'
            )
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
