function Get-RepositoryRoot {
    $currentPath = Get-Location
    $searchPath = $currentPath

    while ($searchPath.Path -ne (Split-Path $searchPath.Path)) {
        Write-Debug "$($Emojis.Debug) Searching for .git in: $searchPath"
        
        $gitPath = Join-Path $searchPath.Path ".git"
        if (Test-Path $gitPath) {
            Write-Debug "$($Emojis.Debug) Found repository root: $($searchPath.Path)"
            return $searchPath.Path
        }
        
        $searchPath = Split-Path $searchPath.Path -Parent
    }

    throw "❌ Not in a git repository. Please navigate to the repository root and try again."
}

# Clear old module versions before bootstrapping
Get-Module | Where-Object { $_.Name -in 'MessageUtils','Emojis','Colors' } | Remove-Module -Force
Remove-Variable -Name Emojis,Colors -Scope Global -ErrorAction SilentlyContinue

$root = Get-RepositoryRoot

# Add to PSModulePath only if not already present
$projectModules = Join-Path $root 'scripts\Modules'
$utilitiesModules = Join-Path $projectModules 'Utilities'

# Function to prepend a path if missing
function Add-ToPSModulePath {
    param([string]$Path)
    if (-not ($env:PSModulePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $Path })) {
        $env:PSModulePath = "$Path;$env:PSModulePath"
    }
}

# Prepend both paths
Add-ToPSModulePath $utilitiesModules
Add-ToPSModulePath $projectModules


# Import modules
Import-Module Emojis
Import-Module Colors
Import-Module MessageUtils

# --- Success ---
Write-Message -Type Success -Message "Operation completed successfully."
Write-Message -Type Success -Message "Operation completed successfully." -ForegroundColor Green
Write-Message -Type Success -Message ""  # Empty message, just the emoji
Write-Message -Type Success -Message "Everything is good!" -ForegroundColor Yellow
Write-Message -Message "No type provided, just message"  # Default type

# --- Warning ---
Write-Message -Type Warning -Message "This is a warning."
Write-Message -Type Warning -Message "This is a warning." -ForegroundColor Magenta
Write-Message -Type Warning -Message "Warning: Check the configuration." -ForegroundColor Cyan
Write-Message -Type Warning -Message ""  # Empty message, just the emoji
Write-Message -Message "Warning message with no type"
Write-Message -Type Warning -Message "Be cautious!" -ForegroundColor Red

# --- Error ---
Write-Message -Type Error -Message "An error occurred."
Write-Message -Type Error -Message "An error occurred." -ForegroundColor DarkRed
Write-Message -Type Error -Message "Critical error! Please fix it." -ForegroundColor Black
Write-Message -Type Error -Message ""  # Empty message, just the emoji
Write-Message -Message "Unknown error message"
Write-Message -Type Error -Message "System failure!" -ForegroundColor White

# --- Info ---
Write-Message -Type Info -Message "This is an informational message."
Write-Message -Type Info -Message "Info: Data processed successfully." -ForegroundColor Blue
Write-Message -Type Info -Message ""  # Empty message, just the emoji
Write-Message -Message "No type, just info"
Write-Message -Type Info -Message "Info: Debugging process started." -ForegroundColor Gray

# --- Debug ---
Write-Message -Type Debug -Message "Debugging the issue."
Write-Message -Type Debug -Message "Inspecting variable values." -ForegroundColor Green
Write-Message -Type Debug -Message ""  # Empty message, just the emoji
Write-Message -Message "Debugging phase initiated"
Write-Message -Type Debug -Message "Verbose log output." -ForegroundColor Yellow

# --- Test ---
Write-Message -Type Test -Message "Running unit tests."
Write-Message -Type Test -Message "Running unit tests." -ForegroundColor Orange
Write-Message -Type Test -Message ""  # Empty message, just the emoji
Write-Message -Message "Testing phase: No type"
Write-Message -Type Test -Message "Test case passed!" -ForegroundColor Cyan

# --- Scenario ---
Write-Message -Type Scenario -Message "Test scenario executed."
Write-Message -Type Scenario -Message "Test scenario executed." -ForegroundColor Purple
Write-Message -Type Scenario -Message ""  # Empty message, just the emoji
Write-Message -Message "Scenario executed"
Write-Message -Type Scenario -Message "Scenario: Timeout exceeded!" -ForegroundColor Magenta

# --- Fixture ---
Write-Message -Type Fixture -Message "Fixture setup complete."
Write-Message -Type Fixture -Message "Fixture setup complete." -ForegroundColor Brown
Write-Message -Type Fixture -Message ""  # Empty message, just the emoji
Write-Message -Message "Fixture loaded without issues"
Write-Message -Type Fixture -Message "Fixture: Initialization failure" -ForegroundColor Gray

# --- Target ---
Write-Message -Type Target -Message "Target acquired."
Write-Message -Type Target -Message "Target acquired." -ForegroundColor Blue
Write-Message -Type Target -Message ""  # Empty message, just the emoji
Write-Message -Message "Target selection in progress"
Write-Message -Type Target -Message "Target locked!" -ForegroundColor Yellow

# --- No Parameters ---
Write-Message  # Empty, no type, no message

# --- Empty Message with Foreground Color ---
Write-Message -Message "" -ForegroundColor Red

# --- Only Type, No Message ---
Write-Message -Type Info  # Message is empty by default
Write-Message -Type Warning  # Message is empty by default
Write-Message -Type Success  # Message is empty by default

# --- Only ForegroundColor, No Type ---
Write-Message -Message "Message in Green" -ForegroundColor Green
Write-Message -Message "Message in Blue" -ForegroundColor Blue
Write-Message -Message "Message in Yellow" -ForegroundColor Yellow