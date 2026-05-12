# ============================================================================
# Group 15: Download Cache Manager - Manage cached download files
# ============================================================================
# Functions:
#   Get-CachedFile       - Check if a filename exists in cache/; return path or $null
#   Invoke-CachePrune    - Remove old cached files, keep only the 5 most recent
#   Invoke-StartupCleanup - Clean stale staging folders, old nightly JARs, orphaned temps
#   Invoke-CacheMenu     - Sub-menu: list cached files, clear cache, open folder
#
# Cache directory is $script:CacheDir (set in Update-GTNH.ps1).
# Files are stored with their original filenames from downloads.
# ============================================================================

function Get-CachedFile {
    <#
    .SYNOPSIS
        Check if a file exists in the cache directory.
    .DESCRIPTION
        Looks for the specified filename in $script:CacheDir. Returns the full
        path if found, or $null if not cached.
    .PARAMETER FileName
        The filename to look for in the cache.
    .OUTPUTS
        Full path to the cached file, or $null if not found.
    #>
    param(
        [Parameter(Mandatory)][string]$FileName
    )

    $cacheDir = $script:CacheDir
    if ([string]::IsNullOrEmpty($cacheDir) -or -not (Test-Path -LiteralPath $cacheDir)) {
        return $null
    }

    $cachedPath = Join-Path $cacheDir $FileName
    if (Test-Path -LiteralPath $cachedPath) {
        return $cachedPath
    }

    return $null
}

function Invoke-CachePrune {
    <#
    .SYNOPSIS
        Remove old cached files, keeping only the 5 most recent by write time.
    .DESCRIPTION
        Runs silently during startup. Prevents the cache folder from growing
        indefinitely as users update through multiple versions.
    #>

    $cacheDir = $script:CacheDir
    if (-not $cacheDir -or -not (Test-Path -LiteralPath $cacheDir)) {
        return
    }

    $maxCachedFiles = 5
    $cachedFiles = Get-ChildItem -LiteralPath $cacheDir -File | Sort-Object LastWriteTime -Descending

    if ($cachedFiles.Count -gt $maxCachedFiles) {
        $toDelete = $cachedFiles | Select-Object -Skip $maxCachedFiles
        foreach ($file in $toDelete) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Log "[CACHE] Pruned old cached file: $($file.Name)"
            }
            catch {
                # Silently continue
            }
        }
    }
}

function Invoke-StartupCleanup {
    <#
    .SYNOPSIS
        Clean up stale files from previous runs on startup.
    .DESCRIPTION
        Removes:
        - Stale staging folders (staging-*/) from cancelled or failed updates
        - Old nightly updater JARs (keeps only the newest)
        - Orphaned temp subdirectories (NOT rollback snapshots - those are handled by the main loop)
        Runs silently during startup to prevent disk space accumulation.
    #>

    # Clean stale staging folders - skip any modified within the last 2 hours (active update in progress)
    $stagingDirs = Get-ChildItem -LiteralPath $script:ScriptDir -Directory -Filter 'staging-*' -ErrorAction SilentlyContinue
    foreach ($dir in $stagingDirs) {
        $ageHours = ((Get-Date) - $dir.LastWriteTime).TotalHours
        if ($ageHours -lt 2) {
            Write-Log "[CLEANUP] Skipping recent staging folder (< 2h old): $($dir.Name)"
            continue
        }
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
            Write-Log "[CLEANUP] Removed stale staging folder: $($dir.Name)"
        }
        catch {
            Write-Log "[CLEANUP] Could not remove staging folder: $($dir.Name)"
        }
    }

    # Clean old nightly updater JARs (keep only the newest)
    $updaterDir = $script:NightlyUpdaterDir
    if ($updaterDir -and (Test-Path -LiteralPath $updaterDir)) {
        $jars = Get-ChildItem -LiteralPath $updaterDir -Filter '*.jar' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        if ($jars.Count -gt 1) {
            $oldJars = $jars | Select-Object -Skip 1
            foreach ($jar in $oldJars) {
                try {
                    Remove-Item -LiteralPath $jar.FullName -Force
                    Write-Log "[CLEANUP] Removed old nightly updater JAR: $($jar.Name)"
                }
                catch {
                    # Silently continue
                }
            }
        }
    }

    # Clean old broken config backups (keep only the 3 most recent)
    $brokenConfigs = Get-ChildItem -LiteralPath $script:ScriptDir -Filter 'gtnh-updater-config.broken-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($brokenConfigs.Count -gt 3) {
        $oldBroken = $brokenConfigs | Select-Object -Skip 3
        foreach ($file in $oldBroken) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Log "[CLEANUP] Removed old broken config backup: $($file.Name)"
            }
            catch {
                # Silently continue
            }
        }
    }

    # Clean orphaned temp subdirectories in .temp/ (but NOT rollback-* dirs —
    # those are checked by Invoke-MainLoop immediately after this runs and
    # cleaned up there after the user is notified).
    $tempDir = $script:TempDir
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        # Clean orphaned temp dirs (but NOT rollback-* dirs —
        # those may contain user data from a crashed update and are handled separately)
        $orphanedDirs = @('preserved', 'custom-mods', 'nightly-custom-mods',
            'custom-mods-nightly-server', 'custom-mods-nightly-client',
            'preserved-nightly-server', 'preserved-nightly-client')
        foreach ($dirName in $orphanedDirs) {
            $orphanPath = Join-Path $tempDir $dirName
            if (Test-Path -LiteralPath $orphanPath) {
                try {
                    Remove-Item -LiteralPath $orphanPath -Recurse -Force
                    Write-Log "[CLEANUP] Removed orphaned temp dir: $dirName"
                }
                catch {
                    # Silently continue
                }
            }
        }
    }

    # Prune download cache
    Invoke-CachePrune

    # Clean orphaned .tmp files from interrupted atomic writes
    $tmpConfigs = Get-ChildItem -LiteralPath $script:ScriptDir -Filter 'gtnh-updater-config*.tmp' -File -ErrorAction SilentlyContinue
    foreach ($tmp in $tmpConfigs) {
        try {
            Remove-Item -LiteralPath $tmp.FullName -Force
            Write-Log "[CLEANUP] Removed orphaned temp config: $($tmp.Name)"
        }
        catch {
            # Silently continue
        }
    }

    # Clean stale lock file (from a crash where finally didn't run)
    $lockFile = Join-Path $script:ScriptDir '.gtnh-updater.lock'
    if (Test-Path -LiteralPath $lockFile) {
        try {
            $lockPid = [int]((Get-Content -LiteralPath $lockFile -Raw -ErrorAction Stop).Trim())
            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if (-not $proc) {
                Remove-Item -LiteralPath $lockFile -Force
                Write-Log "[CLEANUP] Removed stale lock file (PID $lockPid no longer running)"
            }
        }
        catch {
            # Lock file is corrupt - remove it
            Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
            Write-Log "[CLEANUP] Removed corrupt lock file"
        }
    }
}

function Invoke-CacheMenu {
    <#
    .SYNOPSIS
        Sub-menu for managing the download cache: list files, clear, open folder.
    #>

    while ($true) {
        Write-Header "Download Cache"
        Write-Host ""

        $cacheDir = $script:CacheDir

        if (Test-Path -LiteralPath $cacheDir) {
            $cachedFiles = Get-ChildItem -LiteralPath $cacheDir -File

            if ($cachedFiles.Count -gt 0) {
                Write-Info "Cached files ($($cachedFiles.Count)):"
                Write-Host ""
                foreach ($file in $cachedFiles) {
                    $sizeMB = [math]::Round($file.Length / 1MB, 1)
                    Write-Info "  $($file.Name)  (${sizeMB} MB)"
                }

                $totalMB = [math]::Round(($cachedFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
                Write-Host ""
                Write-Info "Total cache size: ${totalMB} MB"
            } else {
                Write-Info "Cache is empty."
            }
        } else {
            Write-Info "Cache directory does not exist yet."
        }

        Write-Host ""
        Write-MenuOption -Key '1' -Description 'Clear all cached files'
        Write-MenuOption -Key 'O' -Description 'Open cache folder'
        Write-Host ""
        Write-MenuOption -Key 'R' -Description 'Return'

        $choice = Read-MenuChoice -Prompt 'Choose an option'

        switch ($choice.ToUpper()) {
            '1' {
                if (Test-Path -LiteralPath $cacheDir) {
                    $cachedFiles = Get-ChildItem -LiteralPath $cacheDir -File
                    if ($cachedFiles.Count -gt 0) {
                        if (Confirm-Action "Delete all $($cachedFiles.Count) cached file(s)?") {
                            try {
                                Get-ChildItem -LiteralPath $cacheDir -File | Remove-Item -Force
                                Write-Success "Cache cleared."
                            }
                            catch {
                                Write-Err "Failed to clear cache: $($_.Exception.Message)"
                            }
                        }
                    } else {
                        Write-Info "Cache is already empty."
                    }
                } else {
                    Write-Info "Cache directory does not exist."
                }
                Wait-ForKey
            }
            'O' {
                if (-not (Test-Path -LiteralPath $cacheDir)) {
                    New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
                }
                Open-FolderInFileManager -Path $cacheDir
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
