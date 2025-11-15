# Colors.psm1
# Provides reusable color mappings and lookup functions for consistent script output.

$script:Colors = [ordered]@{
    # --- Status / Severity ---
    Success    = [System.ConsoleColor]::Green
    Warning    = [System.ConsoleColor]::Yellow
    Error      = [System.ConsoleColor]::Red
    Info       = [System.ConsoleColor]::Cyan
    Debug      = [System.ConsoleColor]::DarkGray
    # --- Process / Workflow ---
    Start      = [System.ConsoleColor]::White
    Workflow   = [System.ConsoleColor]::White
    Validation = [System.ConsoleColor]::White
    Cleanup    = [System.ConsoleColor]::White
    Restore    = [System.ConsoleColor]::White
    Backup     = [System.ConsoleColor]::White
    # --- Testing ---
    Test       = [System.ConsoleColor]::Magenta
    Scenario   = [System.ConsoleColor]::White
    Fixture    = [System.ConsoleColor]::White
    Target     = [System.ConsoleColor]::White
    # --- Source Control ---
    Branch     = [System.ConsoleColor]::White
    Tag        = [System.ConsoleColor]::White
    # --- Documentation / Notes ---
    Note       = [System.ConsoleColor]::White
    List       = [System.ConsoleColor]::White
    # --- Miscellaneous ---
    Folder     = [System.ConsoleColor]::White
    Config     = [System.ConsoleColor]::White
}

function Get-Color {
    <#
    .SYNOPSIS
        Retrieves a console color by key name.

    .PARAMETER Name
        The color key (e.g. 'Success', 'Error', 'Debug').

    .EXAMPLE
        PS> Get-Color Success
        Green

    .EXAMPLE
        PS> Write-Host "Build completed" -ForegroundColor (Get-Color 'Success')
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )

    if ($script:Colors.Contains($Name)) {
        return $script:Colors[$Name]
    }
    else {
        Write-Verbose "Unknown color key: '$Name'"
        return [System.ConsoleColor]::White
    }
}