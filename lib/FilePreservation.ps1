# ============================================================================
# Group 7: File Preservation & Restoration - Protect critical files during updates
# ============================================================================
# Functions:
#   Get-ServerPreservationList  - Return list of server-specific files/folders
#   Get-ClientPreservationList  - Return list of client-specific files/folders
#   Invoke-PreserveFiles        - Copy preserved items to .temp/ before deletion
#   Invoke-RestoreFiles         - Copy preserved items back from .temp/ after extraction
#
# Preservation lists contain relative paths from the instance root.
# Items with path separators (like 'config/JourneyMapServer') are handled by
# ensuring parent directories exist during restoration.
# ============================================================================

function Get-ServerPreservationList {
    <#
    .SYNOPSIS
        Return the list of server-specific files/folders to preserve during updates.
    #>
    return @(
        'config/JourneyMapServer'
        'serverutilities'
        'ops.json'
        'whitelist.json'
        'banned-players.json'
        'banned-ips.json'
        'usercache.json'
        'server.properties'
        'opencomputers'
    )
}

function Get-ClientPreservationList {
    <#
    .SYNOPSIS
        Return the list of client-specific files/folders to preserve during updates.
    #>
    return @(
        'journeymap'
        'options.txt'
        'servers.dat'
        'optionsof.txt'
        'optionsnf.txt'
        'resourcepacks'
        'opencomputers'
        'config/NEI'
        'config/shaders.properties'
        'config/vendingmachine'
        'maps'
    )
}

function Invoke-PreserveFiles {
    <#
    .SYNOPSIS
        Copy preserved files/folders to a temp directory before deletion.
    .DESCRIPTION
        Gets the appropriate preservation list for the target type, then copies
        each item that exists in the instance path to the temp directory.
    .PARAMETER InstancePath
        The root path of the instance (server root or .minecraft for client).
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER TempDir
        The temporary directory to copy preserved items into.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [Parameter(Mandatory)][string]$TempDir
    )

    $preserveList = $Target -eq 'server' ? (Get-ServerPreservationList) : (Get-ClientPreservationList)

    # Ensure temp directory exists
    if (-not (Test-Path -LiteralPath $TempDir)) {
        New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
    }

    $failedItems = @()

    foreach ($item in $preserveList) {
        $sourcePath = Join-Path $InstancePath ($item -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString())
        $destPath = Join-Path $TempDir ($item -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString())

        if (Test-Path -LiteralPath $sourcePath) {
            try {
                # Ensure parent directory exists in temp
                $destParent = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $destParent)) {
                    New-Item -Path $destParent -ItemType Directory -Force | Out-Null
                }

                if ((Get-Item -LiteralPath $sourcePath).PSIsContainer) {
                    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                } else {
                    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
                }

                Write-Info "Preserved: $item"
                Write-Log "[PRESERVE] Preserved: $item"
            }
            catch {
                Write-Err "Failed to preserve '$item': $($_.Exception.Message)"
                Write-Log "[ERROR] Preserve failed for '$item': $($_.Exception.ToString())"
                $failedItems += $item
            }
        }
    }

    return $failedItems.Count -eq 0
}

function Invoke-RestoreFiles {
    <#
    .SYNOPSIS
        Copy preserved files/folders back from temp directory after extraction.
    .DESCRIPTION
        Gets the appropriate preservation list for the target type, then copies
        each item from the temp directory back to the instance path. For items
        with path separators (like 'config/journeymap'), ensures parent directories
        exist before copying.
    .PARAMETER InstancePath
        The root path of the instance (server root or .minecraft for client).
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER TempDir
        The temporary directory where preserved items are stored.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [Parameter(Mandatory)][string]$TempDir
    )

    $preserveList = $Target -eq 'server' ? (Get-ServerPreservationList) : (Get-ClientPreservationList)

    foreach ($item in $preserveList) {
        $sourcePath = Join-Path $TempDir ($item -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString())
        $destPath = Join-Path $InstancePath ($item -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString())

        if (Test-Path -LiteralPath $sourcePath) {
            try {
                # Ensure parent directory exists in instance
                $destParent = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $destParent)) {
                    New-Item -Path $destParent -ItemType Directory -Force | Out-Null
                }

                if ((Get-Item -LiteralPath $sourcePath).PSIsContainer) {
                    # Remove existing directory first to avoid merge conflicts
                    if (Test-Path -LiteralPath $destPath) {
                        Remove-Item -LiteralPath $destPath -Recurse -Force
                    }
                    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                } else {
                    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
                }

                Write-Info "Restored: $item"
                Write-Log "[RESTORE] Restored: $item"
            }
            catch {
                Write-Err "Failed to restore '$item': $($_.Exception.Message)"
                Write-Log "[ERROR] Restore failed for '$item': $($_.Exception.ToString())"
            }
        }
    }
}
