# MessageUtils.psm1
# Function for consistent debug output with emoji and color support.

function Convert-ColorNameToConsoleColor {
    param (
        [string]$colorName
    )
    
    # Define a hashtable to map valid color names to ConsoleColor enum values
    $validColors = @{
        "Black"      = [System.ConsoleColor]::Black
        "DarkBlue"   = [System.ConsoleColor]::DarkBlue
        "DarkGreen"  = [System.ConsoleColor]::DarkGreen
        "DarkCyan"   = [System.ConsoleColor]::DarkCyan
        "DarkRed"    = [System.ConsoleColor]::DarkRed
        "DarkMagenta"= [System.ConsoleColor]::DarkMagenta
        "DarkYellow" = [System.ConsoleColor]::DarkYellow
        "Gray"       = [System.ConsoleColor]::Gray
        "DarkGray"   = [System.ConsoleColor]::DarkGray
        "Blue"       = [System.ConsoleColor]::Blue
        "Green"      = [System.ConsoleColor]::Green
        "Cyan"       = [System.ConsoleColor]::Cyan
        "Red"        = [System.ConsoleColor]::Red
        "Magenta"    = [System.ConsoleColor]::Magenta
        "Yellow"     = [System.ConsoleColor]::Yellow
        "White"      = [System.ConsoleColor]::White
    }
    
    # Check if the color name is in the hashtable, if not return a default color
    if ($validColors.ContainsKey($colorName)) {
        return $validColors[$colorName]
    } else {
        Write-Host "$(Get-Emoji "Error") Invalid color name '$colorName'. Using default 'White'." -ForegroundColor Red -BackgroundColor Yellow
        return [System.ConsoleColor]::White  # Default to White if invalid
    }
}

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

    .PARAMETER ForegroundColor
        Optional color to override the default color from the Colors module

    .PARAMETER NoNewline
        If specified, the message will not end with a newline.

    .EXAMPLE
        Write-Message -Type "INFO" "Starting scenario application" -ForegroundColor Cyan
    #>
    param(
        [Parameter(Position = 0)]
        [string]$Message = "",
        [string]$Type = "None",
        [string]$ForegroundColor,
        [switch]$NoNewline
    )

    # Lazy-load module variables
    if (-not $script:Emojis) {
        $script:Emojis = (Import-Module Emojis -PassThru).ExportedVariables["Emojis"]
    }
    if (-not $script:Colors) {
        $script:Colors = (Import-Module Colors -PassThru).ExportedVariables["Colors"]
    }

    $emoji = Get-Emoji $Type
    $color = if ($ForegroundColor) { Convert-ColorNameToConsoleColor $ForegroundColor } else { Get-Color $Type }

    if ($Type -eq "None") {
        if ($NoNewline) {
            Write-Host "$Message" -ForegroundColor $color -NoNewline
        } else {
            Write-Host "$Message" -ForegroundColor $color
        }
    }
    else {
        $emoji = Get-Emoji $Type
        if ($NoNewline) {
            Write-Host "$emoji $Message" -ForegroundColor $color -NoNewline
        } else {
            Write-Host "$emoji $Message" -ForegroundColor $color
        }
    }
}