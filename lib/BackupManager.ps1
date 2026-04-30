# ============================================================================
# Group 14: Backup Manager - Full instance backups with restore and retention
# ============================================================================
# Functions:
#   Invoke-ScriptBackup       - Back up all folders the update touches to a
#                                timestamped folder. Checks disk space first.
#   Invoke-RestoreBackup      - Restore a backup by copying its contents back
#                                to the instance, replacing current folders.
#   Invoke-BackupCleanup      - Enforce retention count, delete oldest beyond limit
#   Invoke-BackupMenu         - Sub-menu: view, restore, clean, open folder
#   Save-RollbackSnapshot     - Save a lightweight snapshot before update for
#                                quick rollback without needing AMP
#   Invoke-RollbackFromSnapshot - Restore from the pre-update snapshot
#
# Backups are stored in the configured BackupDir with timestamped folder names.
# Format: gtnh-backup-<target>-yyyy-MM-dd_HHmmss
#
# Rollback snapshots are stored in .temp/rollback-<target>/ and are
# automatically cleaned up after a successful update.
# ============================================================================

function Invoke-ScriptBackup {
    <#
    .SYNOPSIS
        Create a full backup of all folders and files the update touches.
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER InstancePath
        The root path of the instance to back up.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    if (-not $Config.BackupEnabled) {
        Write-Info "Script-level backups are disabled. Skipping."
        return $true  # Not a failure, just disabled
    }

    $backupDir = $Config.BackupDir
    if ([string]::IsNullOrEmpty($backupDir)) {
        $backupDir = Join-Path $script:ScriptDir 'backups'
    }

    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    }

    # Check disk space (warn if < 3 GB free)
    try {
        $drive = (Get-Item -LiteralPath $backupDir).PSDrive
        $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
        if ($freeSpaceGB -lt 3) {
            Write-Warn "Low disk space on backup drive: ${freeSpaceGB} GB free (recommend 3+ GB)"
            if (-not (Confirm-Action "Continue with backup anyway?")) {
                Write-Info "Backup skipped due to low disk space."
                return $false
            }
        }
    }
    catch {
        Write-Warn "Could not check disk space: $($_.Exception.Message)"
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupFolderName = "gtnh-backup-${Target}-${timestamp}"
    $backupPath = Join-Path $backupDir $backupFolderName

    New-Item -Path $backupPath -ItemType Directory -Force | Out-Null

    Write-Step "Creating backup: $backupFolderName"

    # Back up all folders and files the update touches
    if ($Target -eq 'server') {
        $foldersToBackup = @('config', 'libraries', 'mods', 'resources', 'scripts', 'serverutilities', 'journeymap')
        $filesToBackup = @('server.properties', 'ops.json', 'whitelist.json', 'banned-ips.json', 'banned-players.json')
    } else {
        $foldersToBackup = @('config', 'mods', 'serverutilities', 'resources', 'scripts', 'journeymap', 'resourcepacks')
        $filesToBackup = @('options.txt', 'optionsof.txt', 'servers.dat')
    }

    try {
        foreach ($folder in $foldersToBackup) {
            $sourcePath = Join-Path $InstancePath $folder
            if (Test-Path -LiteralPath $sourcePath) {
                $destPath = Join-Path $backupPath $folder
                Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                Write-Info "  Backed up: $folder/"
            }
        }

        foreach ($file in $filesToBackup) {
            $sourcePath = Join-Path $InstancePath $file
            if (Test-Path -LiteralPath $sourcePath) {
                Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $backupPath $file) -Force
                Write-Info "  Backed up: $file"
            }
        }

        Write-Success "Backup complete: $backupFolderName"
        Write-Log "[BACKUP] Created: $backupPath"

        Invoke-BackupCleanup -Config $Config -Target $Target
        return $true
    }
    catch {
        Write-Err "Backup failed: $($_.Exception.Message)"
        Write-Log "[ERROR] Backup failed: $($_.Exception.ToString())"
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
            $backups = @(Get-ChildItem -LiteralPath $backupDir -Directory -Filter 'gtnh-backup-*' | Sort-Object Name -Descending)
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
        Write-MenuOption -Key 'S' -Description 'Restore a backup'
        Write-MenuOption -Key 'D' -Description "Delete old backups (keep $($Config.BackupRetention ?? 5))"
        Write-MenuOption -Key 'O' -Description 'Open backup folder in Explorer'
        Write-MenuOption -Key 'R' -Description 'Return'

        $choice = Read-MenuChoice -Prompt 'Choose an option'

        switch ($choice.ToUpper()) {
            'S' {
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
            'D' {
                Invoke-BackupCleanup -Config $Config -Target 'server'
                Invoke-BackupCleanup -Config $Config -Target 'client'
                Write-Success "Cleanup complete."
                Wait-ForKey
            }
            'O' {
                if (-not (Test-Path -LiteralPath $backupDir)) {
                    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
                }
                Start-Process explorer.exe -ArgumentList "`"$backupDir`""
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
        foreach ($folder in $foldersToSnapshot) {
            $sourcePath = Join-Path $InstancePath $folder
            if (Test-Path -LiteralPath $sourcePath) {
                $destPath = Join-Path $rollbackDir $folder
                Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                Write-Info "  Snapshot: $folder/"
            }
        }

        # Also snapshot Java 17+ specific items
        $javaVersion = 'java17'  # Snapshot both just in case
        if ($Target -eq 'server') {
            foreach ($file in $script:ServerJava17FilesToDelete) {
                $filePath = Join-Path $InstancePath $file
                if (Test-Path -LiteralPath $filePath) {
                    Copy-Item -LiteralPath $filePath -Destination (Join-Path $rollbackDir $file) -Force
                    Write-Info "  Snapshot: $file"
                }
            }
        } else {
            $instanceRoot = Split-Path -Parent $InstancePath
            foreach ($item in $script:ClientJava17InstanceRootItems) {
                $itemPath = Join-Path $instanceRoot $item
                if (Test-Path -LiteralPath $itemPath) {
                    $destPath = Join-Path $rollbackDir "instance-root-$item"
                    Copy-Item -LiteralPath $itemPath -Destination $destPath -Recurse -Force
                    Write-Info "  Snapshot (instance root): $item"
                }
            }
        }

        Write-Success "Rollback snapshot saved."
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
