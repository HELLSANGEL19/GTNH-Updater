# ============================================================================
# Group 14: Backup Manager - Full instance backups with restore and retention
# ============================================================================
# Functions:
#   Invoke-FullInstanceBackup   - Full backup of the instance. Server: backs up
#                                  the server folder. Client: backs up the Prism
#                                  instance root (parent of .minecraft).
#   Invoke-RestoreBackup        - Restore a backup by copying its contents back
#                                  to the instance, replacing current folders.
#   Invoke-BackupCleanup        - Enforce retention count, delete oldest beyond limit
#   Invoke-BackupMenu           - Sub-menu: view, restore, clean, open folder
#   Save-RollbackSnapshot       - Save a lightweight snapshot before update for
#                                  quick rollback (persists until next update)
#   Invoke-RollbackFromSnapshot - Restore from the pre-update snapshot
#
# Backups are stored in the configured BackupDir with timestamped folder names.
# Format: gtnh-full-<target>-yyyy-MM-dd_HHmmss
#
# Rollback snapshots are stored next to the instance as .gtnh-rollback-<target>/
# and persist until the next update overwrites them.
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

    # Determine the backup root based on target type.
    # For client: one level above .minecraft (Prism instance root has libraries/, patches/, mmc-pack.json)
    # For server: the instance path itself (server folder contains everything needed)
    $backupSourceDir = if ($Target -eq 'client') {
        $p = Split-Path -Parent $InstancePath
        if ($p.Length -gt 1 -and $p.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $p = $p.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        }
        $p
    } else {
        # Normalize: remove trailing separator unless it's a drive root (e.g., D:\)
        $p = $InstancePath
        if ($p.Length -gt 3 -and $p.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $p = $p.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        }
        $p
    }

    # Safety check: ensure we're not backing up something too broad.
    # If the parent directory contains more than 10 subdirectories that look like
    # other game instances, we're probably too high (e.g., backing up all of "instances/")
    if (-not (Test-Path -LiteralPath $backupSourceDir)) {
        Write-Err "Backup source directory not found: $backupSourceDir"
        return $false
    }
    $parentSubDirs = @(Get-ChildItem -LiteralPath $backupSourceDir -Directory -ErrorAction SilentlyContinue)
    if ($parentSubDirs.Count -gt 10) {
        $modsCount = @($parentSubDirs | Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'mods')) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName '.minecraft'))
        }).Count
        if ($modsCount -gt 3) {
            Write-Warn "Backup source '$backupSourceDir' appears to contain multiple game instances ($($parentSubDirs.Count) subdirs)."
            Write-Warn "This would back up ALL instances, not just yours."
            Write-Info "Your configured path may be pointing at the wrong level."
            if (-not (Confirm-Action "Back up this entire directory anyway?")) { return $null }
        }
    }

    # Estimate instance size (excluding internal dirs that won't be backed up)
    # Skip for silent/automated calls (no confirmation prompt shown anyway)
    # These are the same dirs excluded during the actual backup
    $internalExcludes = @('.temp', 'cache', 'logs', 'crash-reports', 'backups', 'backup', 'simplebackups')
    $instanceSizeGB = $null
    if (-not $Silent) {
        try {
            Write-Host "  Scanning..." -NoNewline -ForegroundColor Gray
            $bytes = 0
            $srcLen = $backupSourceDir.Length + 1
            Get-ChildItem -LiteralPath $backupSourceDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Substring($srcLen)
                if ($rel.Contains([System.IO.Path]::DirectorySeparatorChar)) {
                    $top = $rel.Split([System.IO.Path]::DirectorySeparatorChar)[0]
                    if ($top.ToLower() -in $internalExcludes) { return }
                }
                $bytes += $_.Length
            }
            $instanceSizeGB = [math]::Round($bytes / 1GB, 2)
            Write-Host "`r  Instance size: ~${instanceSizeGB} GB                    " -ForegroundColor Gray
        } catch {
            Write-Host "`r$(' ' * (Get-TerminalWidth))`r" -NoNewline
        }
    }

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
        if (-not (Confirm-Action "Create full $Target backup?")) { return $null }
    }

    $timestamp      = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupName     = "gtnh-full-${Target}-${timestamp}"
    $backupZipName  = "${backupName}.zip"
    $backupPath     = Join-Path $backupDir $backupZipName

    if (-not $Silent) {
        Write-Phase "Backup"
        Write-Info "$backupZipName"
    }

    try {
        # ── Build exclusion list ──────────────────────────────────────────────
        $excludeDirs = @()

        # Always exclude internal/temp directories (regenerated, not critical)
        # $internalExcludes is defined earlier (used for both estimate and actual backup)
        $actualInternalExcludes = @()
        foreach ($ie in $internalExcludes) {
            if (Test-Path -LiteralPath (Join-Path $backupSourceDir $ie)) {
                $excludeDirs += $ie
                $actualInternalExcludes += $ie
            }
        }

        # Detect if backup dir is inside the source dir (would cause infinite recursion)
        $resolvedBackupDir = [System.IO.Path]::GetFullPath($backupDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $resolvedSourceDir = [System.IO.Path]::GetFullPath($backupSourceDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $backupInsideSource = $resolvedBackupDir.StartsWith($resolvedSourceDir, [System.StringComparison]::OrdinalIgnoreCase)
        if ($backupInsideSource) {
            $excludeDirs += Split-Path -Leaf $backupDir
            Write-Log "[BACKUP] Excluding backup dir inside source"
        }

        # Exclude rollback snapshot directories
        $excludeDirs += ".gtnh-rollback-${Target}"
        $excludeDirs += ".gtnh-rollback-nightly-${Target}"

        # Exclude updater script directory if inside source
        $scriptDirResolved = [System.IO.Path]::GetFullPath($script:ScriptDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $scriptInsideSource = $scriptDirResolved.StartsWith($resolvedSourceDir, [System.StringComparison]::OrdinalIgnoreCase)
        if ($scriptInsideSource -and $scriptDirResolved -ne $resolvedSourceDir) {
            $excludeDirs += Split-Path -Leaf $script:ScriptDir
            Write-Log "[BACKUP] Excluding updater script dir inside source"
        }

        # Exclude lock file and temp files
        $excludeFiles = @('.gtnh-updater.lock', '.gtnh-nightly-state.json.tmp')

        Write-Log "[BACKUP] Exclusions: dirs=[$($excludeDirs -join ', ')], files=[$($excludeFiles -join ', ')]"

        # ── Create zip backup ─────────────────────────────────────────────────
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        # Build exclusion lookup sets for fast matching
        $excludeDirSet = @{}
        foreach ($xd in $excludeDirs) { $excludeDirSet[$xd.ToLower()] = $true }
        $excludeFileSet = @{}
        foreach ($xf in $excludeFiles) { $excludeFileSet[$xf.ToLower()] = $true }

        # Scan files first (may take a moment on large instances)
        if (-not $Silent) {
            Write-Host "  Scanning files..." -NoNewline -ForegroundColor Gray
        }
        $allFiles = Get-ChildItem -LiteralPath $backupSourceDir -Recurse -File -ErrorAction SilentlyContinue
        $totalFiles = @($allFiles).Count
        if (-not $Silent) {
            Write-Host "`r$(' ' * (Get-TerminalWidth))`r" -NoNewline
        }

        # Create zip with Fastest compression
        $zipStream = [System.IO.File]::Create($backupPath)
        $zip = [System.IO.Compression.ZipArchive]::new($zipStream, 'Create')

        $fileCount = 0
        $sourceLen = $backupSourceDir.Length + 1  # +1 for the path separator
        foreach ($file in $allFiles) {
            # Check if file is in an excluded directory (only for files in subdirectories)
            $relativePath = $file.FullName.Substring($sourceLen)
            if ($relativePath.Contains([System.IO.Path]::DirectorySeparatorChar)) {
                $topDir = $relativePath.Split([System.IO.Path]::DirectorySeparatorChar)[0]
                if ($excludeDirSet.ContainsKey($topDir.ToLower())) { continue }
            }
            if ($excludeFileSet.ContainsKey($file.Name.ToLower())) { continue }

            # Add to zip — skip compression on already-compressed files
            $entryName = $relativePath -replace '\\', '/'
            $compressionLevel = if ($file.Extension -imatch '^\.(jar|zip|gz|7z|rar|tar|lz4|zst|png|jpg|jpeg|ogg|mp3|mp4|webp|gif|bmp)$') {
                [System.IO.Compression.CompressionLevel]::NoCompression
            } else {
                [System.IO.Compression.CompressionLevel]::Fastest
            }
            try {
                $entry = $zip.CreateEntry($entryName, $compressionLevel)
                $entryStream = $entry.Open()
                try {
                    $fileStream = [System.IO.File]::OpenRead($file.FullName)
                    try {
                        $fileStream.CopyTo($entryStream)
                    } finally {
                        $fileStream.Dispose()
                    }
                } finally {
                    $entryStream.Dispose()
                }
                $fileCount++
            } catch {
                Write-Log "[BACKUP] Skipped (locked/error): $relativePath"
            }

            # Update progress bar every 50 files
            if (-not $Silent -and $fileCount % 50 -eq 0 -and $totalFiles -gt 0) {
                $percent = [math]::Floor(($fileCount / $totalFiles) * 100)
                $bar = ('█' * [math]::Floor($percent / 2)).PadRight(50, '░')
                $elapsed = [math]::Floor($stopwatch.Elapsed.TotalSeconds)
                $eta = ''
                if ($fileCount -gt 0 -and $elapsed -gt 2) {
                    $rate = $fileCount / $elapsed
                    if ($rate -gt 0) {
                        $remaining = [math]::Ceiling(($totalFiles - $fileCount) / $rate)
                        if ($remaining -gt 0 -and $remaining -lt 60) {
                            $eta = " ~${remaining}s"
                        } elseif ($remaining -ge 60 -and $remaining -lt 3600) {
                            $eta = " ~$([math]::Floor($remaining / 60))m$($remaining % 60)s"
                        }
                    }
                }
                $progressLine = "  [$bar] ${percent}%  ${fileCount}/${totalFiles}${eta}"
                Write-Host "`r$($progressLine.PadRight((Get-TerminalWidth)))" -NoNewline -ForegroundColor Gray
            }
        }

        $zip.Dispose()
        $zip = $null
        $zipStream.Dispose()
        $zipStream = $null

        $stopwatch.Stop()
        $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

        if (-not $Silent) {
            $finalBar = "  [$(('█' * 50))] 100%  ${fileCount}/${totalFiles}  ${elapsed}s"
            Write-Host "`r$(' ' * (Get-TerminalWidth))" -NoNewline
            Write-Host "`r$finalBar" -ForegroundColor Gray
        }

        # ── Summary ───────────────────────────────────────────────────────────
        $zipSizeBytes = (Get-Item -LiteralPath $backupPath).Length
        $sizeLabel = if ($zipSizeBytes -ge 1GB) { "$([math]::Round($zipSizeBytes / 1GB, 1)) GB" }
                     elseif ($zipSizeBytes -ge 1MB) { "$([math]::Round($zipSizeBytes / 1MB, 0)) MB" }
                     else { "$([math]::Round($zipSizeBytes / 1KB, 0)) KB" }

        Write-Success "Backup complete: $sizeLabel, $fileCount files, ${elapsed}s"
        Write-Log "[BACKUP] Created: $backupPath ($sizeLabel, $fileCount files, ${elapsed}s)"

        # Quick sanity check
        if ($fileCount -lt 10) {
            Write-Warn "Backup appears incomplete ($fileCount files). Check the log for errors."
            Write-Log "[BACKUP] WARNING: Only $fileCount files in backup"
        }

        # Prune old backups (keep BackupRetention, default 5)
        $retention = [math]::Max(1, ($Config.BackupRetention ?? 5))
        $oldBackups = Get-ChildItem -LiteralPath $backupDir -File -Filter "gtnh-full-${Target}-*.zip" |
            Sort-Object Name | Select-Object -SkipLast $retention
        foreach ($old in $oldBackups) {
            try { Remove-Item -LiteralPath $old.FullName -Force; Write-Log "[BACKUP] Pruned: $($old.Name)" } catch {}
        }
        # Also prune legacy folder-based backups from older versions
        $oldFolders = Get-ChildItem -LiteralPath $backupDir -Directory -Filter "gtnh-full-${Target}-*" |
            Sort-Object Name | Select-Object -SkipLast $retention
        foreach ($old in $oldFolders) {
            try { $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'; Remove-Item -LiteralPath $old.FullName -Recurse -Force; $ProgressPreference = $oldProgress; Write-Log "[BACKUP] Pruned legacy: $($old.Name)" } catch { $ProgressPreference = $oldProgress }
        }

        return $true
    }
    catch {
        # Clear any lingering progress bar
        if (-not $Silent) { Write-Host "`r$(' ' * (Get-TerminalWidth))`r" -NoNewline }
        Write-Err "Backup failed: $($_.Exception.Message)"
        Write-Log "[ERROR] Full backup failed: $($_.Exception.ToString())"
        if (Test-Path -LiteralPath $backupPath) {
            try { Remove-Item -LiteralPath $backupPath -Force } catch {}
        }
        return $false
    }
    finally {
        if ($zip) { try { $zip.Dispose() } catch {} }
        if ($zipStream) { try { $zipStream.Dispose() } catch {} }
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

    Write-Phase "Restore"
    Write-Info "$(Split-Path -Leaf $BackupPath)"

    try {
        $items = Get-ChildItem -LiteralPath $BackupPath

        foreach ($item in $items) {
            $destPath = Join-Path $InstancePath $item.Name

            # Remove existing at destination
            if (Test-Path -LiteralPath $destPath) {
                $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                Remove-Item -LiteralPath $destPath -Recurse -Force
                $ProgressPreference = $oldProgress
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
    $pattern = "gtnh-full-${Target}-*"

    # Clean zip backups
    $zipBackups = Get-ChildItem -LiteralPath $backupDir -File -Filter "${pattern}.zip" -ErrorAction SilentlyContinue | Sort-Object Name
    if ($zipBackups.Count -gt $retention) {
        $toDelete = $zipBackups | Select-Object -First ($zipBackups.Count - $retention)
        foreach ($old in $toDelete) {
            try {
                Remove-Item -LiteralPath $old.FullName -Force
                Write-Info "  Cleaned old backup: $($old.Name)"
                Write-Log "[BACKUP] Deleted old: $($old.FullName)"
            }
            catch {
                Write-Warn "Could not delete old backup: $($old.Name)"
            }
        }
    }

    # Clean legacy folder backups
    $folderBackups = Get-ChildItem -LiteralPath $backupDir -Directory -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object Name
    if ($folderBackups.Count -gt $retention) {
        $toDelete = $folderBackups | Select-Object -First ($folderBackups.Count - $retention)
        foreach ($old in $toDelete) {
            try {
                $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
                $ProgressPreference = $oldProgress
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
            # Find both zip backups (new format) and folder backups (legacy)
            $zipBackups = @(Get-ChildItem -LiteralPath $backupDir -File -Filter 'gtnh-full-*.zip' -ErrorAction SilentlyContinue)
            $folderBackups = @(Get-ChildItem -LiteralPath $backupDir -Directory -Filter 'gtnh-full-*' -ErrorAction SilentlyContinue)
            $backups = @($zipBackups + $folderBackups | Sort-Object Name -Descending)
        }

        if ($backups.Count -gt 0) {
            Write-Info "Backups ($($backups.Count)):"
            Write-Host ""
            $tagWidth = "[$($backups.Count)]".Length
            for ($i = 0; $i -lt $backups.Count; $i++) {
                $backup = $backups[$i]
                $tag = "[$($i + 1)]".PadLeft($tagWidth)
                $bName = $backup.Name -replace '\.zip$', ''
                # Parse date and target from name (gtnh-full-<target>-yyyy-MM-dd_HHmmss)
                $dateDisplay = ''
                $targetDisplay = ''
                if ($bName -match 'gtnh-full-(server|client)-(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(\d{2})$') {
                    $targetDisplay = $Matches[1]
                    $dateDisplay = "$($Matches[3])/$($Matches[4])/$($Matches[2]) $($Matches[5]):$($Matches[6])"
                }
                $isZip = $backup.Name.EndsWith('.zip')
                $formatLabel = if ($isZip) { 'zip' } else { 'folder' }
                Write-Host "    $tag " -NoNewline -ForegroundColor White
                Write-Host "$targetDisplay" -NoNewline -ForegroundColor $(if ($targetDisplay -eq 'server') { 'Green' } else { 'Cyan' })
                Write-Host "  $dateDisplay" -NoNewline -ForegroundColor Gray
                Write-Host "  ($formatLabel)" -ForegroundColor DarkGray
            }
        } else {
            Write-Info "No backups found."
        }

        Write-Host ""
        Write-MenuOption -Key '1' -Description 'Restore a backup'
        Write-MenuOption -Key '2' -Description 'Delete a backup'
        Write-MenuOption -Key '3' -Description "Clean old backups (keep $($Config.BackupRetention ?? 5))"
        Write-MenuOption -Key 'O' -Description 'Open backup folder'
        Write-Host ""
        Write-MenuOption -Key 'R' -Description 'Return'

        $choice = Read-MenuChoice -Prompt 'Choose an option'

        switch ($choice.ToUpper()) {
            '1' {
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

                    $isZipBackup = $selectedBackup.Name.EndsWith('.zip')

                    # Determine restore target
                    $restorePath = $null
                    if ($isServer) {
                        if ($isZipBackup) {
                            # Zip backups always contain server folder contents
                            $restorePath = $instancePath
                        } else {
                            # Legacy folder: check if it has mods/ directly (new format) or not (old parent format)
                            $backupHasModsDirectly = Test-Path -LiteralPath (Join-Path $selectedBackup.FullName 'mods')
                            $restorePath = if ($backupHasModsDirectly) { $instancePath } else { Split-Path -Parent $instancePath }
                        }
                    } else {
                        $restorePath = Split-Path -Parent $instancePath
                    }

                    Write-Host ""
                    Write-Warn "This will REPLACE files in your $targetLabel instance at:"
                    Write-Info "  $restorePath"
                    Write-Host ""

                    if (Confirm-Action "Restore this backup?") {
                        if ($isZipBackup) {
                            # Extract zip to restore path (overwrites existing files)
                            Write-Phase "Restore"
                            $zip = $null
                            try {
                                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                                $zip = [System.IO.Compression.ZipFile]::OpenRead($selectedBackup.FullName)
                                $entryCount = 0
                                $totalEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) }).Count
                                foreach ($entry in $zip.Entries) {
                                    if ([string]::IsNullOrEmpty($entry.Name)) { continue }  # Skip directory entries
                                    $destFile = Join-Path $restorePath $entry.FullName
                                    $destDir = Split-Path -Parent $destFile
                                    if (-not (Test-Path -LiteralPath $destDir)) {
                                        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                                    }
                                    $entryStream = $entry.Open()
                                    try {
                                        $fileStream = [System.IO.File]::Create($destFile)
                                        try {
                                            $entryStream.CopyTo($fileStream)
                                        } finally {
                                            $fileStream.Dispose()
                                        }
                                    } finally {
                                        $entryStream.Dispose()
                                    }
                                    $entryCount++
                                    if ($entryCount % 200 -eq 0 -and $totalEntries -gt 0) {
                                        $pct = [math]::Floor(($entryCount / $totalEntries) * 100)
                                        $bar = ('█' * [math]::Floor($pct / 2)).PadRight(50, '░')
                                        $progressLine = "  [$bar] ${pct}%  ${entryCount}/${totalEntries}"
                                        Write-Host "`r$($progressLine.PadRight((Get-TerminalWidth)))" -NoNewline -ForegroundColor Gray
                                    }
                                }
                                if ($totalEntries -gt 200) {
                                    Write-Host "`r$(' ' * (Get-TerminalWidth))" -NoNewline
                                    $finalLine = "  [$(('█' * 50))] 100%  ${entryCount}/${totalEntries}"
                                    Write-Host "`r$finalLine" -ForegroundColor Gray
                                }
                                Write-Success "Restore complete ($entryCount files extracted)."
                                
                                # Detect stale files in mods/ that weren't in the backup
                                $modsDir = Join-Path $restorePath 'mods'
                                if (-not (Test-Path -LiteralPath $modsDir)) {
                                    $modsDir = Join-Path $restorePath '.minecraft' 'mods'
                                }
                                if (Test-Path -LiteralPath $modsDir) {
                                    $backupModEntries = @{}
                                    foreach ($e in $zip.Entries) {
                                        if ($e.FullName -match '^(?:\.minecraft/)?mods/([^/]+\.jar)$') {
                                            $backupModEntries[$Matches[1].ToLower()] = $true
                                        }
                                    }
                                    if ($backupModEntries.Count -gt 0) {
                                        $staleJars = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                                            Where-Object { -not $backupModEntries.ContainsKey($_.Name.ToLower()) })
                                        if ($staleJars.Count -gt 0) {
                                            Write-Host ""
                                            Write-Warn "$($staleJars.Count) mod(s) in mods/ were not in this backup (added after it was taken):"
                                            foreach ($stale in ($staleJars | Sort-Object Name | Select-Object -First 10)) {
                                                Write-Host "    - $($stale.Name)" -ForegroundColor DarkYellow
                                            }
                                            if ($staleJars.Count -gt 10) {
                                                Write-Host "    ... and $($staleJars.Count - 10) more" -ForegroundColor DarkGray
                                            }
                                            Write-Host ""
                                            if (Confirm-Action "Remove these $($staleJars.Count) stale mod(s)?") {
                                                foreach ($stale in $staleJars) {
                                                    try { Remove-Item -LiteralPath $stale.FullName -Force } catch {}
                                                }
                                                Write-Success "Removed $($staleJars.Count) stale mod(s)."
                                                Write-Log "[BACKUP] Removed $($staleJars.Count) stale mods after restore"
                                            }
                                        }
                                    }
                                }

                                Write-Log "[BACKUP] Restored zip: $($selectedBackup.Name) to $restorePath ($entryCount files)"
                            } catch {
                                Write-Err "Restore failed: $($_.Exception.Message)"
                                Write-Log "[ERROR] Zip restore failed: $($_.Exception.ToString())"
                            } finally {
                                if ($zip) { try { $zip.Dispose() } catch {} }
                            }
                        } else {
                            # Legacy folder restore
                            Invoke-RestoreBackup -BackupPath $selectedBackup.FullName -InstancePath $restorePath
                        }

                        # Re-detect version from restored instance
                        $detected = Get-InstalledGtnhVersion -InstancePath $instancePath
                        if ($detected -ne 'unknown') {
                            if ($isServer) { $Config.InstalledServerVersion = $detected }
                            else { $Config.InstalledClientVersion = $detected }
                        } else {
                            if ($isServer) { $Config.InstalledServerVersion = '' }
                            else { $Config.InstalledClientVersion = '' }
                        }
                        Save-Config -Config $Config
                    } else {
                        Write-Info "Restore cancelled."
                    }
                } else {
                    Write-Warn "Invalid selection."
                }
                Wait-ForKey
            }
            '2' {
                if ($backups.Count -eq 0) {
                    Write-Warn "No backups to delete."
                    Wait-ForKey
                    continue
                }

                Write-Host ""
                $pickNum = Read-UserInput "Enter backup number to delete"
                $pickIdx = 0
                if ([int]::TryParse($pickNum, [ref]$pickIdx) -and $pickIdx -ge 1 -and $pickIdx -le $backups.Count) {
                    $selectedBackup = $backups[$pickIdx - 1]
                    Write-Host ""
                    if (Confirm-Action "Delete $($selectedBackup.Name)?") {
                        try {
                            if ($selectedBackup.PSIsContainer) {
                                $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                                Remove-Item -LiteralPath $selectedBackup.FullName -Recurse -Force
                                $ProgressPreference = $oldProgress
                            } else {
                                Remove-Item -LiteralPath $selectedBackup.FullName -Force
                            }
                            Write-Success "Deleted: $($selectedBackup.Name)"
                            Write-Log "[BACKUP] User deleted: $($selectedBackup.Name)"
                        } catch {
                            Write-Err "Could not delete: $($_.Exception.Message)"
                        }
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
        MOVES (not copies) the folders the update will delete to a rollback directory.
        Using Move-Item is instant on the same drive (just a directory rename) vs
        Copy-Item which duplicates every byte. The rollback dir is placed next to the
        instance to maximize the chance of being on the same filesystem.
        The snapshot persists until the next update overwrites it, allowing the user
        to rollback even after a successful update if the game crashes on launch.
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

    # Place rollback dir next to instance (same drive = instant moves)
    $rollbackDir = Join-Path (Split-Path -Parent $InstancePath) ".gtnh-rollback-${Target}"

    # Clean any previous rollback snapshot
    if (Test-Path -LiteralPath $rollbackDir) {
        try { $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'; Remove-Item -LiteralPath $rollbackDir -Recurse -Force; $ProgressPreference = $oldProgress } catch { $ProgressPreference = $oldProgress }
    }

    New-Item -Path $rollbackDir -ItemType Directory -Force | Out-Null

    Write-Dots "Saving rollback snapshot"

    $foldersToSnapshot = $Target -eq 'server' ? $script:ServerFoldersToDelete : $script:ClientFoldersToDelete

    try {
        $snapshotCount = 0
        foreach ($folder in $foldersToSnapshot) {
            $sourcePath = Join-Path $InstancePath $folder
            if (Test-Path -LiteralPath $sourcePath) {
                $destPath = Join-Path $rollbackDir $folder
                # Use Move for speed (instant on same filesystem)
                # Falls back to copy+delete if cross-drive (still works, just slower)
                Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
                $snapshotCount++
                Write-Log "[ROLLBACK] Snapshot (moved): $folder/"
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

        Complete-Dots "$snapshotCount items"
        Write-Log "[ROLLBACK] Snapshot saved to: $rollbackDir"
        return $rollbackDir
    }
    catch {
        Complete-Dots "failed" -Color Red
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

    Write-Phase "Rollback"

    try {
        $foldersToRestore = $Target -eq 'server' ? $script:ServerFoldersToDelete : $script:ClientFoldersToDelete

        foreach ($folder in $foldersToRestore) {
            $sourcePath = Join-Path $RollbackDir $folder
            if (Test-Path -LiteralPath $sourcePath) {
                $destPath = Join-Path $InstancePath $folder
                if (Test-Path -LiteralPath $destPath) {
                    try { $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'; Remove-Item -LiteralPath $destPath -Recurse -Force; $ProgressPreference = $oldProgress } catch { $ProgressPreference = $oldProgress; throw }
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
                        try { $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'; Remove-Item -LiteralPath $destPath -Recurse -Force; $ProgressPreference = $oldProgress } catch { $ProgressPreference = $oldProgress; throw }
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
