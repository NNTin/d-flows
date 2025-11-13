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

Write-Message -Type Info -Message "Bootstrap completed. Modules loaded: Emojis, Colors, MessageUtils.\n\n"
Write-Message -Type Unknown -Message "Unknown Message"
Write-Message -Type Success -Message "Success Message"
Write-Message -Type Warning -Message "Warning Message"
Write-Message -Type Error -Message "Error Message"
Write-Message -Type Info -Message "Info Message"
Write-Message -Type Debug -Message "Debug Message"
Write-Message -Type Test -Message "Test Message"
Write-Message -Type Test -Message ""
Write-Message
Write-Message -Message ""
Write-Message -Message "Only message"

