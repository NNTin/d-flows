@{
    # ──────────────────────────────
    # Module metadata
    # ──────────────────────────────
    RootModule = 'ValidationSuite.psm1'
    ModuleVersion = '0.0.1' # TODO: Make this update via CI/CD
    GUID = 'f26debd5-0e23-4ccd-b4f9-935492d99ec1'
    Author = 'Tin Nguyen'
    CompanyName = 'N/A'
    Copyright = '(c) 2025 Tin Nguyen. All rights reserved.'
    Description = 'A suite of validation functions for various processes.'
    
    RequiredModules = @('MessageUtils')

    # ──────────────────────────────
    # Export definitions
    # ──────────────────────────────
    FunctionsToExport = @(
        'Validate-TagExists',
        'Validate-TagNotExists',
        'Validate-TagPointsTo',
        'Validate-TagAccessible',
        'Validate-TagCount',
        'Validate-BranchExists',
        'Validate-BranchPointsToTag',
        'Validate-BranchCount',
        'Validate-CurrentBranch',
        'Validate-VersionGreater',
        'Validate-VersionProgression',
        'Validate-MajorIncrement',
        'Validate-MajorTagCoexistence',
        'Validate-MajorTagProgression',
        'Validate-NoCrossContamination',
        'Validate-NoTagConflicts',
        'Validate-WorkflowSuccess',
        'Validate-WorkflowFailure',
        'Validate-IdempotencyVerified'
    )

    # ──────────────────────────────
    # PowerShell compatibility
    # ──────────────────────────────
    PowerShellVersion = '5.1'  # Minimum version of PowerShell required to use this module (set accordingly)
    CompatiblePSEditions = @('Desktop', 'Core')

    # ──────────────────────────────
    # Private data
    # ──────────────────────────────
    PrivateData = @{
        PSData = @{
            Tags = @('Validation', 'Tools', 'Workflow', 'Git', 'CI/CD')
            ProjectUri = 'https://github.com/nntin/d-flows'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            License    = 'MIT'
        }
    }
}
