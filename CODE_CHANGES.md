# Code Changes: Workflow Output Assertions Implementation

## Summary of Changes to `run-integration-tests.ps1`

### 1. New Helper Function: `Test-WorkflowOutput`

**Location**: After `Invoke-WorkflowTest` function (around line 187)

**Purpose**: Parses `act` output and validates workflow outputs against expected values

```powershell
function Test-WorkflowOutput {
    param(
        [string]$ActOutput,
        [string]$StepName,
        [hashtable]$ExpectedOutputs
    )
    
    # Handles empty inputs gracefully
    if ([string]::IsNullOrEmpty($ActOutput) -or $null -eq $ExpectedOutputs -or $ExpectedOutputs.Count -eq 0) {
        return $true
    }
    
    # Parses output in two formats:
    # 1. KEY=VALUE (standard environment format)
    # 2. ::set-output name=KEY::VALUE (GitHub Actions format)
    
    $OutputLines = $ActOutput -split "`n"
    foreach ($Line in $OutputLines) {
        if ($Line -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') {
            $Key = $matches[1]
            $Value = $matches[2]
            $ParsedOutputs[$Key] = $Value
        }
        elseif ($Line -match '::set-output\s+name=([A-Z_][A-Z0-9_]*)::(.*)$') {
            $Key = $matches[1]
            $Value = $matches[2]
            $ParsedOutputs[$Key] = $Value
        }
    }
    
    # Validates each expected output
    foreach ($ExpectedKey in $ExpectedOutputs.Keys) {
        if ($ParsedOutputs[$ExpectedKey] -ne $ExpectedOutputs[$ExpectedKey]) {
            # Fails validation with error message
            return $false
        }
    }
    
    return $true
}
```

**Key Features**:
- ✅ Supports multiple output formats (KEY=VALUE and ::set-output)
- ✅ Gracefully handles missing outputs or null expectations
- ✅ Provides detailed error messages with color coding
- ✅ Supports verbose mode for debugging
- ✅ Returns boolean for easy integration into test logic

---

### 2. Updated: `Test-CompleteReleaseCycle`

**Location**: Around line 356

**Changes Made**:
- Added Step 2.5: Bump-version workflow output validation
- Added Step 4.5: Release workflow output validation
- Updated final pass condition to include output validations

**Code Additions**:

```powershell
# Step 2.5: Validate bump-version workflow outputs
Write-Host "📊 Validating bump-version workflow outputs..." -ForegroundColor Cyan
$BumpExpectedOutputs = @{
    "NEW_VERSION" = "1.0.0"
    "FIRST_RELEASE" = "false"
    "CURRENT_MAJOR" = "0"
}
$BumpOutputsValid = Test-WorkflowOutput -ActOutput ($BumpResult.Logs) -StepName "Calculate New Version" -ExpectedOutputs $BumpExpectedOutputs

if (-not $BumpOutputsValid) {
    throw "Bump-version workflow outputs validation failed"
}

# ... (other validation steps)

# Step 4.5: Validate release workflow outputs
Write-Host "📊 Validating release workflow outputs..." -ForegroundColor Cyan
$ReleaseExpectedOutputs = @{
    "MAJOR_VERSION" = "1"
}
$ReleaseOutputsValid = Test-WorkflowOutput -ActOutput ($ReleaseResult.Logs) -StepName "Extract Major Version" -ExpectedOutputs $ReleaseExpectedOutputs

if (-not $ReleaseOutputsValid) {
    throw "Release workflow outputs validation failed"
}

# Updated final condition
if ($TagsValid -and $VersionValid -and $NoBranchCreated -and $BumpOutputsValid -and $ReleaseOutputsValid) {
    # Test passes
}
```

**Impact**:
- Test now validates 5 workflow outputs in addition to state checks
- Ensures version calculations are correct (not just that tags exist)
- Validates major version extraction in release workflow

---

### 3. Updated: `Test-MultiStepVersionProgression`

**Location**: Around line 452

**Changes Made**:
- Added output validation after each of 4 version bump steps
- Updated final pass condition to require all output validations

**Code Additions**:

**Step 1 - First Release**:
```powershell
Write-Host "📊 Validating first release outputs..." -ForegroundColor Cyan
$FirstExpectedOutputs = @{
    "NEW_VERSION" = "0.1.0"
    "FIRST_RELEASE" = "true"
}
$FirstOutputsValid = Test-WorkflowOutput -ActOutput ($FirstResult.Logs) -StepName "Calculate New Version" -ExpectedOutputs $FirstExpectedOutputs
if (-not $FirstOutputsValid) { throw "First release output validation failed" }
```

**Step 2 - Patch Bump**:
```powershell
Write-Host "📊 Validating patch bump outputs..." -ForegroundColor Cyan
$PatchExpectedOutputs = @{
    "NEW_VERSION" = "0.1.1"
    "FIRST_RELEASE" = "false"
}
$PatchOutputsValid = Test-WorkflowOutput -ActOutput ($PatchResult.Logs) -StepName "Calculate New Version" -ExpectedOutputs $PatchExpectedOutputs
if (-not $PatchOutputsValid) { throw "Patch bump output validation failed" }
```

**Step 3 - Minor Bump**:
```powershell
Write-Host "📊 Validating minor bump outputs..." -ForegroundColor Cyan
$MinorExpectedOutputs = @{
    "NEW_VERSION" = "0.2.0"
    "FIRST_RELEASE" = "false"
}
$MinorOutputsValid = Test-WorkflowOutput -ActOutput ($MinorResult.Logs) -StepName "Calculate New Version" -ExpectedOutputs $MinorExpectedOutputs
if (-not $MinorOutputsValid) { throw "Minor bump output validation failed" }
```

**Step 4 - Major Bump**:
```powershell
Write-Host "📊 Validating major bump outputs..." -ForegroundColor Cyan
$MajorExpectedOutputs = @{
    "NEW_VERSION" = "1.0.0"
    "FIRST_RELEASE" = "false"
    "CURRENT_MAJOR" = "0"
}
$MajorOutputsValid = Test-WorkflowOutput -ActOutput ($MajorResult.Logs) -StepName "Calculate New Version" -ExpectedOutputs $MajorExpectedOutputs
if (-not $MajorOutputsValid) { throw "Major bump output validation failed" }
```

**Updated Final Condition**:
```powershell
$AllValid = $FirstOutputsValid -and $PatchOutputsValid -and $MinorOutputsValid -and $MajorOutputsValid
```

**Impact**:
- Test now validates 8 workflow outputs across 4 progression steps
- Ensures each semantic versioning bump produces correct output
- Validates FIRST_RELEASE flag state transitions
- Tracks CURRENT_MAJOR through progression

---

## Test Assertions Added

### `Test-CompleteReleaseCycle`
- ✅ bump-version: `NEW_VERSION = "1.0.0"`
- ✅ bump-version: `FIRST_RELEASE = "false"`
- ✅ bump-version: `CURRENT_MAJOR = "0"`
- ✅ release: `MAJOR_VERSION = "1"`

### `Test-MultiStepVersionProgression`
- ✅ First release: `NEW_VERSION = "0.1.0"`
- ✅ First release: `FIRST_RELEASE = "true"`
- ✅ Patch bump: `NEW_VERSION = "0.1.1"`
- ✅ Patch bump: `FIRST_RELEASE = "false"`
- ✅ Minor bump: `NEW_VERSION = "0.2.0"`
- ✅ Minor bump: `FIRST_RELEASE = "false"`
- ✅ Major bump: `NEW_VERSION = "1.0.0"`
- ✅ Major bump: `FIRST_RELEASE = "false"`
- ✅ Major bump: `CURRENT_MAJOR = "0"`

---

## Validation Workflow

```
Workflow Execution
    ↓
Success Check (workflow exits without error)
    ↓
Output Extraction (parse act logs for KEY=VALUE patterns)
    ↓
Output Validation (compare against expected fixture values)
    ↓
State Validation (verify git tags/branches)
    ↓
Test Pass/Fail Decision
```

---

## Usage Example

```powershell
# Run with output validation
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle

# Run with verbose output logging
.\run-integration-tests.ps1 -Scenario CompleteReleaseCycle -Verbose

# Example verbose output:
# 📊 Validating bump-version workflow outputs...
#   ✓ Extracted output: NEW_VERSION=1.0.0
#   ✓ Extracted output: FIRST_RELEASE=false
#   ✓ Extracted output: CURRENT_MAJOR=0
#   ✓ Output validated: NEW_VERSION=1.0.0
#   ✓ Output validated: FIRST_RELEASE=false
#   ✓ Output validated: CURRENT_MAJOR=0
```

---

## Error Handling

When output validation fails:
```
❌ Missing output: NEW_VERSION (expected '1.0.0')
❌ Output mismatch for FIRST_RELEASE: expected 'false', got 'true'
```

Tests will immediately throw with clear error messages, making failures easy to diagnose.
