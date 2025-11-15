# Emojis.psm1
# Provides emoji constants and lookup functions for consistent script output.

$script:Emojis = [ordered]@{
    # --- Status / Severity ---
    Success    = "✅"
    Warning    = "⚠️"
    Error      = "❌"
    Info       = "ℹ️"
    Debug      = "🔍"
    # --- Process / Workflow ---
    Start      = "🚀"
    Workflow   = "⚙️"
    Validation = "🔎"
    Cleanup    = "🧹"
    Restore    = "♻️"
    Backup     = "💾"
    # --- Testing ---
    Test       = "🧪"
    Scenario   = "🎬"
    Fixture    = "📄"
    Target     = "🎯"
    # --- Source Control ---
    Branch     = "🌿"
    Tag        = "🏷️"
    # --- Documentation / Notes ---
    Note       = "📝"
    List       = "📋"
    # --- Miscellaneous ---
    Folder     = "📁"
    Config     = "⚙️"
}

function Get-Emoji {
    <#
    .SYNOPSIS
        Retrieves an emoji by key name.

    .PARAMETER Name
        The key name (e.g. 'Success', 'Error', 'Backup').

    .EXAMPLE
        PS> Get-Emoji Success
        ✅

    .EXAMPLE
        PS> "Build complete $(Get-Emoji 'Success')"
        Build complete ✅
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )

    if ($script:Emojis.Contains($Name)) {
        return $script:Emojis[$Name]
    }
    else {
        Write-Verbose "Unknown emoji key: '$Name'"
        return "❔"
    }
}