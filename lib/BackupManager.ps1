# ============================================================================
# Group 14: Backup Manager - Full instance backups with restore and retention
# ============================================================================
# Functions:
#   Invoke-FullInstanceBackup   - Full backup of the entire instance (one level
#                                  above configured path). Checks disk space first.
#   Invoke-RestoreBackup        - Restore a backup by copying its contents back
#                                  to the instance, replacing current folders.
#   Invoke-BackupCleanup        - Enforce retention count, delete oldest beyond limit
#   Invoke-BackupMenu           - Sub-menu: view, restore, clean, open folder
#   Save-RollbackSnapshot       - Save a lightweight snapshot before update for
#                                  quick rollback without needing AMP
#   Invoke-RollbackFromSnapshot - Restore from the pre-update snapshot
#
# Backups are stored in the configured BackupDir with timestamped folder names.
# Format: gtnh-full-<target>-yyyy-MM-dd_HHmmss
#
# Rollback snapshots are stored in .temp/rollback-<target>/ and are
# automatically cleaned up after a successful update.
# ============================================================================

function Invoke-FullInstanceBackup {
    <#
    .SYNOPSIS
        Create a full backup of the entire instance directory.
    .DESCRIPTION
        Copies everything in the instance path to a timestamped backup folder.
        Shows estimated size and checks disk space before proceeding.
        Naming: gtnh-full-<target>-yyyy-MM-dd_HHmmss

        When called with -Silent (automated update flow), respects BackupEnabled setting.
        When called without -Silent (user-initiated from menu), always proceeds.
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER InstancePath
        The root path of the instance to back up.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER Silent
        If true, skips confirmation prompts and respects BackupEnabled setting.
        Used during automated pre-update flow.
    .OUTPUTS
        $true on success, $false on failure, $null if skipped by user.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [switch]$Silent
    )

    $backupDir = $Config.BackupDir
    if ([string]::IsNullOrEmpty($backupDir)) {
        $backupDir = Join-Path $script:ScriptDir 'backups'
    }

    # When called from the automated update flow (-Silent), respect BackupEnabled setting.
    # When called from the menu (no -Silent), always proceed — user explicitly requested it.
    if ($Silent -and -not $Config.BackupEnabled) {
        return $true  # Not a failure, just disabled
    }

    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    }

    # Determine the backup root: one level above the configured instance path.
    # For client: .minecraft -> instance root (has mmc-pack.json, patches/, libraries/)
    # For server: Minecraft -> AMP/panel instance root (has server wrapper configs)
    $backupSourceDir = Split-Path -Parent $InstancePath

    # Estimate instance size (from the parent directory)
    $instanceSizeGB = $null
    try {
        $bytes = (Get-ChildItem -LiteralPath $backupSourceDir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $instanceSizeGB = [math]::Round($bytes / 1GB, 2)
    } catch {}

    # Check free space on backup drive
    try {
        $freeSpaceGB = $null
        if ($IsWindows) {
            $driveRoot = [System.IO.Path]::GetPathRoot($backupDir)
            $freeSpaceGB = [math]::Round(([System.IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace / 1GB, 2)
        } else {
            # On Linux, DriveInfo('/') always returns root filesystem info regardless of mount point.
            # Use df to get the actual free space for the backup directory's mount point.
            $dfOutput = df -B1 $backupDir 2>/dev/null | Select-Object -Last 1
            if ($dfOutput -match '\s(\d+)\s+\d+%\s') {
                $freeSpaceGB = [math]::Round([long]$Matches[1] / 1GB, 2)
            } else {
                # Fallback to DriveInfo (better than nothing)
                $driveRoot = [System.IO.Path]::GetPathRoot($backupDir)
                $freeSpaceGB = [math]::Round(([System.IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace / 1GB, 2)
            }
        }
        if ($freeSpaceGB) {
            if ($instanceSizeGB -and $freeSpaceGB -lt ($instanceSizeGB * 1.1)) {
                Write-Warn "Insufficient disk space: need ~${instanceSizeGB} GB, have ${freeSpaceGB} GB free."
                if (-not (Confirm-Action "Continue anyway?")) { return $null }
            } elseif ($freeSpaceGB -lt 3) {
                Write-Warn "Low disk space on backup drive: ${freeSpaceGB} GB free."
                if (-not (Confirm-Action "Continue anyway?")) { return $null }
            }
        }
    } catch {
        Write-Warn "Could not check disk space: $($_.Exception.Message)"
    }

    # Warn if backup is on same drive as instance
    $instanceDrive = [System.IO.Path]::GetPathRoot($backupSourceDir)
    $backupDrive   = [System.IO.Path]::GetPathRoot($backupDir)
    if ($instanceDrive -eq $backupDrive -and -not $Silent) {
        Write-Warn "Backup is on the same drive as the instance ($instanceDrive). A drive failure would lose both."
    }

    if (-not $Silent -and $instanceSizeGB) {
        Write-Info "Instance size: ~${instanceSizeGB} GB (backing up full instance root)"
        if (-not (Confirm-Action "Create full $Target backup (~${instanceSizeGB} GB)?")) { return $null }
    }

    $timestamp      = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupName     = "gtnh-full-${Target}-${timestamp}"
    $backupPath     = Join-Path $backupDir $backupName

    New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
    Write-Step "Creating full backup: $backupName"
    Write-Info "  Source: $backupSourceDir"

    try {
        # Copy entire instance root directory (one level above configured path)
        Get-ChildItem -LiteralPath $backupSourceDir | ForEach-Object {
            $dest = Join-Path $backupPath $_.Name
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
        }

        Write-Success "Full backup complete: $backupName"
        Write-Log "[BACKUP] Full backup created: $backupPath"

        # Prune old full backups (keep BackupRetention, default 2 for full backups)
        $retention = [math]::Max(1, ($Config.BackupRetention ?? 2))
        $oldFull = Get-ChildItem -LiteralPath $backupDir -Directory -Filter "gtnh-full-${Target}-*" |
            Sort-Object Name | Select-Object -SkipLast $retention
        foreach ($old in $oldFull) {
            try { Remove-Item -LiteralPath $old.FullName -Recurse -Force; Write-Log "[BACKUP] Pruned: $($old.Name)" } catch {}
        }

        return $true
    }
    catch {
        Write-Err "Full backup failed: $($_.Exception.Message)"
        Write-Log "[ERROR] Full backup failed: $($_.Exception.ToString())"
        if (Test-Path -LiteralPath $backupPath) {
            try { Remove-Item -LiteralPath $backupPath -Recurse -Force } catch {}
        }
        return $false
    }
}

function Invoke-RestoreBackup {
    <#
    .SYNOPSIS
        Restore a backup by copying its contents back to the instance.
    .PARAMETER BackupPath
        Full path to the backup folder to restore from.
    .PARAMETER InstancePath
        The root path of the instance to restore to.
    #>
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$InstancePath
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Write-Err "Backup folder not found: $BackupPath"
        return $false
    }

    if (-not (Test-Path -LiteralPath $InstancePath)) {
        Write-Err "Instance path not found: $InstancePath"
        return $false
    }

    Write-Step "Restoring from: $(Split-Path -Leaf $BackupPath)"

    try {
        $items = Get-ChildItem -LiteralPath $BackupPath

        foreach ($item in $items) {
            $destPath = Join-Path $InstancePath $item.Name

            # Remove existing at destination
            if (Test-Path -LiteralPath $destPath) {
                Remove-Item -LiteralPath $destPath -Recurse -Force
            }

            # Copy from backup
            Copy-Item -LiteralPath $item.FullName -Destination $destPath -Recurse -Force
            Write-Info "  Restored: $($item.Name)"
        }

        Write-Success "Restore complete."
        Write-Log "[BACKUP] Restored from: $BackupPath"
        return $true
    }
    catch {
        Write-Err "Restore failed: $($_.Exception.Message)"
        Write-Log "[ERROR] Restore failed: $($_.Exception.ToString())"
        return $false
    }
}

function Invoke-BackupCleanup {
    <#
    .SYNOPSIS
        Enforce backup retention count, delete oldest beyond configured limit.
    .PARAMETER Config
        The config PSCustomObject with BackupDir and BackupRetention.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $backupDir = $Config.BackupDir
    if ([string]::IsNullOrEmpty($backupDir)) {
        $backupDir = Join-Path $script:ScriptDir 'backups'
    }

    if (-not (Test-Path -LiteralPath $backupDir)) {
        return
    }

    $retention = $Config.BackupRetention ?? 5
    $pattern = "gtnh-backup-${Target}-*"

    $backups = Get-ChildItem -LiteralPath $backupDir -Directory -Filter $pattern | Sort-Object Name

    if ($backups.Count -gt $retention) {
        $toDelete = $backups | Select-Object -First ($backups.Count - $retention)
        foreach ($old in $toDelete) {
            try {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
                Write-Info "  Cleaned old backup: $($old.Name)"
                Write-Log "[BACKUP] Deleted old: $($old.FullName)"
            }
            catch {
                Write-Warn "Could not delete old backup: $($old.Name)"
            }
        }
    }
}

function Invoke-BackupMenu {
    <#
    .SYNOPSIS
        Sub-menu for managing backups: list, restore, clean, open folder.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Backup Manager"
        Write-Host ""

        $backupDir = $Config.BackupDir
        if ([string]::IsNullOrEmpty($backupDir)) {
            $backupDir = Join-Path $script:ScriptDir 'backups'
        }

        $backups = @()
        if (Test-Path -LiteralPath $backupDir) {
            $backups = @(Get-ChildItem -LiteralPath $backupDir -Directory -Filter 'gtnh-*' | Sort-Object Name -Descending)
        }

        if ($backups.Count -gt 0) {
            Write-Info "Backups ($($backups.Count)):"
            Write-Host ""
            $tagWidth = "[$($backups.Count)]".Length
            for ($i = 0; $i -lt $backups.Count; $i++) {
                $backup = $backups[$i]
                $tag = "[$($i + 1)]".PadLeft($tagWidth)
                try {
                    $sizeBytes = (Get-ChildItem -LiteralPath $backup.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum
                    $sizeMB = [math]::Round($sizeBytes / 1MB, 1)
                    Write-Host "    $tag $($backup.Name)  (${sizeMB} MB)" -ForegroundColor Cyan
                }
                catch {
                    Write-Host "    $tag $($backup.Name)  (size unknown)" -ForegroundColor Cyan
                }
            }
        } else {
            Write-Info "No backups found."
        }

        Write-Host ""
        Write-MenuOption -Key '1' -Description 'Create full instance backup'
        Write-MenuOption -Key '2' -Description 'Restore a backup'
        Write-MenuOption -Key '3' -Description "Clean old backups (keep $($Config.BackupRetention ?? 5))"
        Write-MenuOption -Key 'O' -Description 'Open backup folder'
        Write-Host ""
        Write-MenuOption -Key 'R' -Description 'Return'

        $choice = Read-MenuChoice -Prompt 'Choose an option'

        switch ($choice.ToUpper()) {
            '1' {
                $hasServer = -not [string]::IsNullOrEmpty($Config.ServerPath)
                $hasClient = -not [string]::IsNullOrEmpty($Config.ClientInstancePath)
                if (-not $hasServer -and -not $hasClient) {
                    Write-Warn "No instance paths configured."; Wait-ForKey; continue
                }
                if ($hasServer -and $hasClient) {
                    Write-MenuOption "1" "Server"
                    Write-MenuOption "2" "Client"
                    Write-MenuOption "3" "Both"
                    $tChoice = Read-MenuChoice "Target"
                    $doServer = $tChoice -eq '1' -or $tChoice -eq '3'
                    $doClient = $tChoice -eq '2' -or $tChoice -eq '3'
                } else {
                    $doServer = $hasServer; $doClient = $hasClient
                }
                if ($doServer) {
                    Invoke-FullInstanceBackup -Config $Config -InstancePath $Config.ServerPath -Target 'server'
                }
                if ($doClient) {
                    Invoke-FullInstanceBackup -Config $Config -InstancePath $Config.ClientInstancePath -Target 'client'
                }
                Wait-ForKey
            }
            '2' {
                if ($backups.Count -eq 0) {
                    Write-Warn "No backups to restore."
                    Wait-ForKey
                    continue
                }

                Write-Host ""
                $pickNum = Read-UserInput "Enter backup number to restore"
                $pickIdx = 0
                if ([int]::TryParse($pickNum, [ref]$pickIdx) -and $pickIdx -ge 1 -and $pickIdx -le $backups.Count) {
                    $selectedBackup = $backups[$pickIdx - 1]

                    # Determine target from backup name
                    $isServer = $selectedBackup.Name -match 'server'
                    $targetLabel = $isServer ? 'server' : 'client'
                    $instancePath = $isServer ? $Config.ServerPath : $Config.ClientInstancePath

                    if ([string]::IsNullOrEmpty($instancePath)) {
                        Write-Err "No $targetLabel path configured. Cannot restore."
                        Wait-ForKey
                        continue
                    }

                    Write-Host ""
                    Write-Warn "This will REPLACE the following in your $targetLabel instance:"
                    $backupContents = Get-ChildItem -LiteralPath $selectedBackup.FullName
                    foreach ($item in $backupContents) {
                        Write-Info "  - $($item.Name)"
                    }
                    Write-Host ""

                    if (Confirm-Action "Restore this backup to $instancePath?") {
                        Invoke-RestoreBackup -BackupPath $selectedBackup.FullName -InstancePath $instancePath
                    } else {
                        Write-Info "Restore cancelled."
                    }
                } else {
                    Write-Warn "Invalid selection."
                }
                Wait-ForKey
            }
            '3' {
                Invoke-BackupCleanup -Config $Config -Target 'server'
                Invoke-BackupCleanup -Config $Config -Target 'client'
                Write-Success "Cleanup complete."
                Wait-ForKey
            }
            'O' {
                if (-not (Test-Path -LiteralPath $backupDir)) {
                    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
                }
                Open-FolderInFileManager -Path $backupDir
            }
            'R' {
                return
            }
            default {
                Write-Warn "Invalid option. Please try again."
            }
        }
    }
}

function Save-RollbackSnapshot {
    <#
    .SYNOPSIS
        Save a lightweight snapshot of folders that will be deleted during update.
    .DESCRIPTION
        Copies the folders the update will delete to a rollback directory in .temp/.
        This allows the script to roll back without needing AMP if the update fails
        after the point of no return. The snapshot is automatically cleaned up after
        a successful update.
    .PARAMETER InstancePath
        The root path of the instance.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .OUTPUTS
        The rollback directory path on success, $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $rollbackDir = Join-Path $script:TempDir "rollback-${Target}"

    # Clean any previous rollback snapshot
    if (Test-Path -LiteralPath $rollbackDir) {
        try { Remove-Item -LiteralPath $rollbackDir -Recurse -Force } catch {}
    }

    New-Item -Path $rollbackDir -ItemType Directory -Force | Out-Null

    Write-Step "Saving rollback snapshot..."

    $foldersToSnapshot = $Target -eq 'server' ? $script:ServerFoldersToDelete : $script:ClientFoldersToDelete

    try {
        $snapshotCount = 0
        foreach ($folder in $foldersToSnapshot) {
            $sourcePath = Join-Path $InstancePath $folder
            if (Test-Path -LiteralPath $sourcePath) {
                $destPath = Join-Path $rollbackDir $folder
                Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                $snapshotCount++
                Write-Log "[ROLLBACK] Snapshot: $folder/"
            }
        }

        # Also snapshot Java 17+ specific items (always snapshot regardless of pack type for safety)

        if ($Target -eq 'server') {
            foreach ($file in $script:ServerJava17FilesToDelete) {
                $filePath = Join-Path $InstancePath $file
                if (Test-Path -LiteralPath $filePath) {
                    Copy-Item -LiteralPath $filePath -Destination (Join-Path $rollbackDir $file) -Force
                    $snapshotCount++
                    Write-Log "[ROLLBACK] Snapshot: $file"
                }
            }
        } else {
            $instanceRoot = Split-Path -Parent $InstancePath
            foreach ($item in $script:ClientJava17InstanceRootItems) {
                $itemPath = Join-Path $instanceRoot $item
                if (Test-Path -LiteralPath $itemPath) {
                    $destPath = Join-Path $rollbackDir "instance-root-$item"
                    Copy-Item -LiteralPath $itemPath -Destination $destPath -Recurse -Force
                    $snapshotCount++
                    Write-Log "[ROLLBACK] Snapshot (instance root): $item"
                }
            }
        }

        Write-Success "Rollback snapshot saved ($snapshotCount items)"
        Write-Log "[ROLLBACK] Snapshot saved to: $rollbackDir"
        return $rollbackDir
    }
    catch {
        Write-Err "Failed to save rollback snapshot: $($_.Exception.Message)"
        Write-Log "[ERROR] Rollback snapshot failed: $($_.Exception.ToString())"
        return $null
    }
}

function Invoke-RollbackFromSnapshot {
    <#
    .SYNOPSIS
        Restore the instance from a pre-update rollback snapshot.
    .DESCRIPTION
        Copies the snapshot contents back to the instance path, replacing whatever
        the failed update left behind. For client targets, also restores instance-root
        items (libraries/, patches/, mmc-pack.json).
    .PARAMETER RollbackDir
        Path to the rollback snapshot directory.
    .PARAMETER InstancePath
        The root path of the instance.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$RollbackDir,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    if (-not (Test-Path -LiteralPath $RollbackDir)) {
        Write-Err "Rollback snapshot not found: $RollbackDir"
        return $false
    }

    Write-Step "Rolling back from snapshot..."

    try {
        $foldersToRestore = $Target -eq 'server' ? $script:ServerFoldersToDelete : $script:ClientFoldersToDelete

        foreach ($folder in $foldersToRestore) {
            $sourcePath = Join-Path $RollbackDir $folder
            if (Test-Path -LiteralPath $sourcePath) {
                $destPath = Join-Path $InstancePath $folder
                if (Test-Path -LiteralPath $destPath) {
                    Remove-Item -LiteralPath $destPath -Recurse -Force
                }
                Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                Write-Info "  Restored: $folder/"
            }
        }

        # Restore Java 17+ specific items
        if ($Target -eq 'server') {
            foreach ($file in $script:ServerJava17FilesToDelete) {
                $sourcePath = Join-Path $RollbackDir $file
                if (Test-Path -LiteralPath $sourcePath) {
                    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $InstancePath $file) -Force
                    Write-Info "  Restored: $file"
                }
            }
        } else {
            $instanceRoot = Split-Path -Parent $InstancePath
            foreach ($item in $script:ClientJava17InstanceRootItems) {
                $sourcePath = Join-Path $RollbackDir "instance-root-$item"
                if (Test-Path -LiteralPath $sourcePath) {
                    $destPath = Join-Path $instanceRoot $item
                    if (Test-Path -LiteralPath $destPath) {
                        Remove-Item -LiteralPath $destPath -Recurse -Force
                    }
                    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                    Write-Info "  Restored (instance root): $item"
                }
            }
        }

        Write-Success "Rollback complete. Instance restored to pre-update state."
        Write-Log "[ROLLBACK] Restored from: $RollbackDir"
        return $true
    }
    catch {
        Write-Err "Rollback failed: $($_.Exception.Message)"
        Write-Log "[ERROR] Rollback failed: $($_.Exception.ToString())"
        return $false
    }
}
