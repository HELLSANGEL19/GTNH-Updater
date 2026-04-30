# ============================================================================
# Group 8: Custom Mod Detection - Identify and manage user-added mods
# ============================================================================
# Functions:
#   Get-ModBaseName         - Strip version numbers and .jar extension, lowercase
#
# Mod name normalization uses regex to strip trailing version patterns:
#   -1.2.3, _1.2.3, -mc1.7.10-1.2.3, -forge-1.2.3, etc.
# This allows matching mods across version bumps.
#
# Custom mod detection and marking is handled inline in StableEngine.ps1
# during the preview-first update flow.
# ============================================================================

function Get-ModBaseName {
    <#
    .SYNOPSIS
        Strip version numbers and .jar extension from a mod filename.
    .DESCRIPTION
        Uses regex to strip everything from the first occurrence of -<digit> or
        _<digit> or -mc to the end, then strips .jar. Returns lowercased result.
        Example: 'MouseTweaks-2.10.jar' -> 'mousetweaks'
                 'GregTech-mc1.7.10-5.09.jar' -> 'gregtech'
    .PARAMETER FileName
        The mod JAR filename to normalize.
    #>
    param(
        [Parameter(Mandatory)][string]$FileName
    )

    # Strip .jar extension first
    $name = $FileName -replace '\.jar$', ''

    # Strip everything from the first occurrence of -<digit>, _<digit>, or -mc
    $name = $name -replace '[-_](\d|mc).*$', ''

    return $name.ToLower()
}
