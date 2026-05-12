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
        Uses regex to strip version-like patterns from mod filenames.
        Keeps identity brackets (e.g., [BiomesOPlenty]) but strips version brackets.
        Handles common GTNH naming conventions:
          - MouseTweaks-2.10.jar -> mousetweaks
          - GregTech-mc1.7.10-5.09.jar -> gregtech
          - BiblioCraft[v1.11.7][MC1.7.10].jar -> bibliocraft
          - BiblioWoods[BiomesOPlenty][v1.9].jar -> bibliowoods[biomesoplenty]
          - Thaumic Machina-1.7.10-0.2.1.jar -> thaumic machina
          - +unimixins-all-1.7.10-0.3.0.jar -> +unimixins-all
    .PARAMETER FileName
        The mod JAR filename to normalize.
    #>
    param(
        [Parameter(Mandatory)][string]$FileName
    )

    # Strip .jar extension first
    $name = $FileName -replace '\.jar$', ''

    # Strip bracket-enclosed content that looks like versions: [v1.2.3], [MC1.7.10], [1.7.10]
    # Keep brackets that are mod identity (e.g., [BiomesOPlenty], [Forestry], [Natura])
    $name = $name -replace '\[v[\d\.]+\]', ''
    $name = $name -replace '(?i)\[MC[\d\.]+\]', ''
    $name = $name -replace '\[\d[\d\.]*\]', ''

    # Strip everything from the first occurrence of -<digit>, _<digit>, or -mc
    $name = $name -replace '(?i)[-_](mc|\d).*$', ''

    # Trim trailing whitespace/separators left by bracket removal
    $name = $name.TrimEnd(' ', '-', '_', '.')

    # Guard against empty result (malformed filename stripped to nothing)
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $FileName.ToLower() -replace '\.jar$', ''
    }

    return $name.ToLower()
}
