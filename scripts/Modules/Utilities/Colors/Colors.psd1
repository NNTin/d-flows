@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule           = 'Colors.psm1'
    ModuleVersion        ='1.1.2'
    GUID                 = 'fc71ab99-aca7-46e9-b75d-65e789820b51'
    Author               = 'Tin Nguyen'
    CompanyName          = 'N/A'
    Copyright            = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description          = 'Provides a centralized set of console colors for consistent script output.'

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport    = @('Get-Color')
    VariablesToExport    = @('Colors')

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
            Tags       = @('Colors', 'Console', 'Logging', 'Utility')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
