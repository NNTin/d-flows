# MessageUtils.psm1
# Function for consistent debug output with emoji and color support.

# Import required modules
Import-Module -Name Emojis -ErrorAction Stop
Import-Module -Name Colors -ErrorAction Stop

function Write-Message {
    <#
    .SYNOPSIS
        Write debug messages with consistent formatting.

    .DESCRIPTION
        Wrapper function for consistent debug output with emoji prefixes and colors.

    .PARAMETER Type
        Message type: must match a key in the Emojis/Colors modules

    .PARAMETER Message
        The message text to display

    .EXAMPLE
        Write-DebugMessage -Type "INFO" -Message "Starting scenario application"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Message
    )

    # Lazy-load module variables
    if (-not $script:Emojis) {
        $script:Emojis = (Import-Module Emojis -PassThru).ExportedVariables["Emojis"]
    }
    if (-not $script:Colors) {
        $script:Colors = (Import-Module Colors -PassThru).ExportedVariables["Colors"]
    }
    
    $emoji = Get-Emoji $Type
    $color = Get-Color $Type

    Write-Host "$emoji $Message" -ForegroundColor $color
}

# Export the function
Export-ModuleMember -Function Write-Message
