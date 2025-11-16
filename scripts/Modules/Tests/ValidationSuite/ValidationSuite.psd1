@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule           = 'ValidationSuite.psm1'
    ModuleVersion        ='0.1.3'
    GUID                 = 'f26debd5-0e23-4ccd-b4f9-935492d99ec1'
    Author               = 'Tin Nguyen'
    CompanyName          = 'N/A'
    Copyright            = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description          = 'A suite of validation functions for various processes.'

    # Dependencies
    RequiredModules      = @('MessageUtils')

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport    = @(
        'Test-TagExists',
        'Test-TagNotExists',
        'Test-TagPointsTo',
        'Test-TagAccessible',
        'Test-TagCount',
        'Test-BranchExists',
        'Test-BranchPointsToTag',
        'Test-BranchCount',
        'Test-CurrentBranch',
        'Test-VersionGreater',
        'Test-VersionProgression',
        'Test-MajorIncrement',
        'Test-MajorTagCoexistence',
        'Test-MajorTagProgression',
        'Test-NoCrossContamination',
        'Test-NoTagConflicts',
        'Test-WorkflowSuccess',
        'Test-WorkflowFailure',
        'Test-IdempotencyVerified'
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
            Tags       = @('Validation', 'Tools', 'Workflow', 'Git', 'CI/CD')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
