@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule           = 'TestArtifacts.psm1'
    ModuleVersion        ='1.1.2'
    GUID                 = '2da18094-d83e-4c2d-874a-a0d5259ed76b'
    Author               = 'Tin Nguyen'
    CompanyName          = 'N/A'
    Copyright            = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description          = 'Manages and exports test artifacts such as reports, logs, tags, and branch data.'

    # Dependencies
    RequiredModules      = @('MessageUtils', 'RepositoryUtils')

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport    = @(
        'Export-TestReport',
        'Export-TestTagsFile',
        'Export-TestBranchesFile',
        'Export-TestCommitsBundle'
    )

    VariablesToExport    = @(
        'TestStateDirectory',
        'TestTagsFile',
        'BackupDirectory',
        'TestLogsDirectory',
        'IntegrationTestsDirectory',
        'TestBranchesFile',
        'TestCommitsBundle'
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
            Tags       = @('Testing', 'Artifacts', 'CI/CD', 'Reports', 'Utilities')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
