@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule           = 'MessageUtils.psm1'
    ModuleVersion        ='1.0.2'
    GUID                 = 'c777b9d4-1d3c-468d-8cb3-6d42f80d33e4'
    Author               = 'Tin Nguyen'
    CompanyName          = 'N/A'
    Copyright            = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description          = 'Provides various function with emoji and color support for consistent output.'

    # Dependencies
    RequiredModules      = @('Emojis', 'Colors')

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport    = @('Write-Message')

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
            Tags       = @('Emoji', 'Colors', 'Console', 'Logging', 'Utility')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
