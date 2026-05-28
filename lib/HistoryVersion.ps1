# ============================================================================
# Group 16: Update History & Version Check - Track updates and check versions
# ============================================================================
# Functions:
#   Add-UpdateHistoryEntry       - Append entry to config, trim to 20 entries
#   Show-VersionMismatchWarning  - Warn if server and client versions differ
#
# History entries are stored in Config.UpdateHistory as an array of objects
# with Date (ISO 8601), Version, Channel, and Target fields.
# ============================================================================

function Add-UpdateHistoryEntry {
    <#
    .SYNOPSIS
        Append an update history entry to config and trim to 20 entries.
    .DESCRIPTION
        Creates an entry object with the current date (ISO 8601), version, channel,
        and target. Appends to Config.UpdateHistory, trims to keep only the 20 most
        recent entries, and saves the config.
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Version
        The version that was installed.
    .PARAMETER Channel
        The channel used: 'stable', 'beta', 'daily', or 'experimental'.
    .PARAMETER Target
        What was updated: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Version,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Channel,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [string]$Details = ''
    )

    $entry = [PSCustomObject]@{
        Date    = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Version = $Version
        Channel = $Channel
        Target  = $Target
        Details = $Details
    }

    # Ensure UpdateHistory is an array
    if ($null -eq $Config.UpdateHistory) {
        $Config.UpdateHistory = @()
    }

    # Append new entry
    $Config.UpdateHistory = @($Config.UpdateHistory) + $entry

    # Trim to 20 most recent entries (keep the last 20)
    if ($Config.UpdateHistory.Count -gt 20) {
        $Config.UpdateHistory = @($Config.UpdateHistory | Select-Object -Last 20)
    }

    Save-Config -Config $Config
    Write-Log "[HISTORY] Recorded: $Channel $Target update to v$Version"
}

function Show-VersionMismatchWarning {
    <#
    .SYNOPSIS
        Display a yellow warning if server and client versions are both set but differ.
    .DESCRIPTION
        Compares InstalledServerVersion and InstalledClientVersion. If both are
        non-empty and different, displays a prominent yellow warning. This helps
        users notice when their server and client are on different versions.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $serverVer = $Config.InstalledServerVersion
    $clientVer = $Config.InstalledClientVersion

    if (-not [string]::IsNullOrEmpty($serverVer) -and
        -not [string]::IsNullOrEmpty($clientVer) -and
        $serverVer -ne $clientVer) {
        Write-Warn "VERSION MISMATCH: Server is $serverVer but Client is $clientVer"
        Write-Warn "Players may experience issues connecting with mismatched versions."
    }
}
