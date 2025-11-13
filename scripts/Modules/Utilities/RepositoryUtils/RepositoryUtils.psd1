@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule        = 'RepositoryUtils.psm1'
    ModuleVersion     = '0.0.1' # TODO: Make this update via CI/CD
    GUID              = '9150b029-d4f9-46a0-bbf0-ffbbea2a9c10'
    Author            = 'Tin Nguyen'
    CompanyName       = 'N/A'
    Copyright         = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description       = 'Provides various utility functions for working with Git repositories.'

    # Dependencies
    RequiredModules   = @('MessageUtils')


    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport = @('Get-RepositoryRoot')


    # ──────────────────────────────
    # PowerShell compatibility
    # ──────────────────────────────
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # ──────────────────────────────
    # Private data
    # ──────────────────────────────
    PrivateData = @{
        PSData = @{
            Tags       = @('Console', 'Utility', 'Git', 'Repository', 'Path')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
