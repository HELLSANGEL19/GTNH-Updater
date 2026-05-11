# ============================================================================
# Group 11: Daily/Experimental Update Engine - Orchestrate dev build updates
# ============================================================================
# Functions:
#   Invoke-NightlyUpdate     - Full update flow: binary update ->
#                               back up custom mods -> invoke binary -> restore ->
#                               patch -> verify -> history
#   Invoke-NightlyUpdaterJar - Build and execute the gtnh-daily-updater binary
#
# Daily/Experimental updates use gtnh-daily-updater (Go binary) which
# handles downloading and applying the update. No Java required.
# ============================================================================

function Invoke-NightlyUpdate {
    <#
    .SYNOPSIS
        Orchestrate the full nightly update flow for a given target and channel.
    .DESCRIPTION
        Steps:
          1. Check Java 21+ is available
          2. Get/update nightly updater JAR
          3. Preserve custom mods from config saved list (no auto-detection)
          4. Invoke nightly updater JAR
          5. Restore custom mods
          6. Apply config patches
          7. Run verification
          8. Record history
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER Channel
        The nightly channel: 'daily' or 'experimental'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [Parameter(Mandatory)][ValidateSet('daily', 'experimental')][string]$Channel
    )

    $instancePath = $Target -eq 'server' ? $Config.ServerPath : $Config.ClientInstancePath

    # Initialize cleanup variables upfront so finally/cleanup blocks are safe
    $customModTempDir = $null
    $nightlyRollbackDir = $null
    $preserveTempDir = $null

    if ([string]::IsNullOrEmpty($instancePath)) {
        Write-Err "No $Target path configured. Run setup wizard first."
        return
    }

    if (-not (Test-Path -LiteralPath $instancePath)) {
        Write-Err "$Target path does not exist: $instancePath"
        return
    }

    Write-Header "$($Channel.ToUpper()) Update - $($Target.ToUpper())"

    # ── Step 1: Get/update daily updater binary ───────────────────────────────
    Write-Step "Checking daily updater..."

    $jarPath = Get-LatestNightlyUpdater -Config $Config
    if (-not $jarPath) {
        Write-Err "Daily updater binary is not available. Cannot proceed."
        return
    }

    Write-Success "Updater ready: $(Split-Path -Leaf $jarPath)"

    # ── Step 3: Preserve custom mods from config saved list ───────────────────
    Write-Step "Backing up custom mods..."

    $savedMods = $Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @())
    $customModTempDir = Join-Path $script:TempDir 'nightly-custom-mods'

    if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
        Remove-TempDir $customModTempDir
    }

    $modsPath = Join-Path $instancePath 'mods'
    if ($savedMods.Count -gt 0 -and (Test-Path -LiteralPath $modsPath)) {
        New-Item -Path $customModTempDir -ItemType Directory -Force | Out-Null
        $backedUpCount = 0
        foreach ($modFile in $savedMods) {
            $modPath = Join-Path $modsPath $modFile
            if (Test-Path -LiteralPath $modPath) {
                Copy-Item -LiteralPath $modPath -Destination (Join-Path $customModTempDir $modFile) -Force
                $backedUpCount++
            } else {
                Write-Warn "  Custom mod not found: $modFile"
            }
        }
        if ($backedUpCount -gt 0) {
            Write-Success "Backed up $backedUpCount custom mod(s)."
        }
    } else {
        Write-Info "No custom mods to back up."
    }

    # ── Script-level backup (if enabled) ─────────────────────────────────────
    $backupOk = Invoke-ScriptBackup -Config $Config -InstancePath $instancePath -Target $Target
    if ($backupOk -eq $false) {
        Write-Err "Backup failed. Update cancelled for safety."
        Write-Info "Fix the backup issue or disable backups in Settings, then try again."
        # Clean up temp dir before returning
        Remove-TempDir $customModTempDir
        return
    }

    # ── Preserve critical files ──────────────────────────────────────────────────
    Write-Step "Preserving critical files..."

    $preserveTempDir = Join-Path $script:TempDir 'nightly-preserved'
    Remove-TempDir $preserveTempDir
    $preserveOk = Invoke-PreserveFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir
    if (-not $preserveOk) {
        Write-Warn "Some files could not be preserved. They may be lost during the update."
        if (-not (Confirm-Action "Continue anyway?")) {
            Write-Info "Update cancelled."
            Remove-TempDir $customModTempDir
            Remove-TempDir $preserveTempDir
            return
        }
    }

    # ── Save rollback snapshot (mods/ and config/ before the JAR touches them) ──
    Write-Step "Saving rollback snapshot..."

    $nightlyRollbackDir = Join-Path $script:TempDir "rollback-nightly-${Target}"
    Remove-TempDir $nightlyRollbackDir
    New-Item -Path $nightlyRollbackDir -ItemType Directory -Force | Out-Null

    $nightlyFoldersToSnapshot = @('mods', 'config', 'resources', 'scripts', 'shaderpacks')
    try {
        foreach ($folder in $nightlyFoldersToSnapshot) {
            $sourcePath = Join-Path $instancePath $folder
            if (Test-Path -LiteralPath $sourcePath) {
                Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $nightlyRollbackDir $folder) -Recurse -Force
            }
        }
        Write-Success "Snapshot saved."
    }
    catch {
        Write-Warn "Could not save rollback snapshot: $($_.Exception.Message)"
        $nightlyRollbackDir = $null
    }

    # ── Backup confirmation before running ──────────────────────────────────
    Write-Host ""
    Write-BackupWarning -Target $Target
    Write-Host ""
    if (-not (Confirm-Action "Ready to proceed? Instance is backed up?")) {
        Write-Info "Update cancelled."
        Remove-TempDir $customModTempDir
        Remove-TempDir $nightlyRollbackDir
        Remove-TempDir $preserveTempDir
        return
    }

    # ── Step 4: Invoke nightly updater JAR ────────────────────────────────────
    Write-Step "Running $Channel updater - this may take several minutes..."
    Write-Host ""

    # Ensure mods/ directory exists (nightly JAR requires it)
    $modsDir = Join-Path $instancePath 'mods'
    if (-not (Test-Path -LiteralPath $modsDir)) {
        New-Item -Path $modsDir -ItemType Directory -Force | Out-Null
        Write-Info "Created mods/ directory (required by updater)."
    }

    # Build targets hashtable for the JAR invocation
    $targets = @{}
    $targets[$Target] = $instancePath

    $success = Invoke-NightlyUpdaterJar -JarPath $jarPath -Channel $Channel -Targets $targets

    if (-not $success) {
        Write-Err "Update failed. Check output above for details."

        # Offer rollback if snapshot exists
        if ($nightlyRollbackDir -and (Test-Path -LiteralPath $nightlyRollbackDir)) {
            Write-Host ""
            Write-Host "  A rollback snapshot of mods/ and config/ was saved before the update." -ForegroundColor Yellow
            Write-Host ""
            if (Confirm-Action "Restore mods/ and config/ to their pre-update state?") {
                try {
                    foreach ($folder in $nightlyFoldersToSnapshot) {
                        $sourcePath = Join-Path $nightlyRollbackDir $folder
                        if (Test-Path -LiteralPath $sourcePath) {
                            $destPath = Join-Path $instancePath $folder
                            if (Test-Path -LiteralPath $destPath) {
                                Remove-Item -LiteralPath $destPath -Recurse -Force
                            }
                            Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                            Write-Info "  Restored: $folder/"
                        }
                    }
                    Write-Success "Rollback complete."
                }
                catch {
                    Write-Err "Rollback failed: $($_.Exception.Message)"
                    Write-Warn "You may need to restore from your backup."
                }
            }
        }

        Remove-TempDir $customModTempDir
        Remove-TempDir $nightlyRollbackDir
        Remove-TempDir $preserveTempDir
        return
    }

    try {
        Write-Host ""

        # ── Step 4b: Restore preserved files ─────────────────────────────────
        Write-Step "Restoring preserved files..."
        if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
            Invoke-RestoreFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir
        }

        # ── Step 5: Restore custom mods ───────────────────────────────────────
        Write-Step "Restoring custom mods..."

        if ($savedMods.Count -gt 0 -and (Test-Path -LiteralPath $customModTempDir)) {
            $modsDir = Join-Path $instancePath 'mods'
            if (-not (Test-Path -LiteralPath $modsDir)) {
                New-Item -Path $modsDir -ItemType Directory -Force | Out-Null
            }
            $restoredCount = 0
            foreach ($modFile in $savedMods) {
                $source = Join-Path $customModTempDir $modFile
                if (Test-Path -LiteralPath $source) {
                    # Remove any jar with the same base name the nightly JAR may have placed
                    # (e.g. it updated Angelica-beta66 -> Angelica-beta67; we're restoring beta66)
                    $customBase = Get-ModBaseName -FileName $modFile
                    Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                        Where-Object { (Get-ModBaseName -FileName $_.Name) -eq $customBase -and $_.Name -ne $modFile } |
                        ForEach-Object {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                            Write-Log "[NIGHTLY] Removed updated pack version '$($_.Name)' — restoring custom '$modFile'"
                        }
                    Copy-Item -LiteralPath $source -Destination (Join-Path $modsDir $modFile) -Force
                    $restoredCount++
                }
            }
            Write-Success "Restored $restoredCount custom mod(s)."
        } else {
            Write-Info "No custom mods to restore."
        }

        # ── Step 6: Apply config patches ──────────────────────────────────────
        Write-Step "Applying config patches..."
        Invoke-ConfigPatches -Config $Config -InstancePath $instancePath -Target $Target

        # ── Step 7: Run verification ───────────────────────────────────────────
        Write-Step "Running verification..."
        Invoke-Verification -InstancePath $instancePath -Target $Target

        # ── Step 8: Record history ─────────────────────────────────────────────
        Write-Step "Recording update..."

        $versionLabel = if ($script:CachedLatestNightly) {
            $script:CachedLatestNightly
        } else {
            "$Channel-$(Get-Date -Format 'yyyyMMdd')"
        }

        Add-UpdateHistoryEntry -Config $Config -Version $versionLabel -Channel $Channel -Target $Target

        $currentInstalled = $Target -eq 'server' ? $Config.InstalledServerVersion : $Config.InstalledClientVersion
        $isAlreadyNightly = $currentInstalled -match 'nightly|daily|experimental|\d{8}'
        if ($script:CachedLatestNightly -or $isAlreadyNightly -or [string]::IsNullOrEmpty($currentInstalled)) {
            if ($Target -eq 'server') { $Config.InstalledServerVersion = $versionLabel }
            else { $Config.InstalledClientVersion = $versionLabel }
            Save-Config -Config $Config
        }

        Write-Host ""
        Write-Success "$Channel update complete! $Target updated."
    }
    finally {
        # Always clean up temp dirs, even if a post-success step throws
        Remove-TempDir $customModTempDir
        Remove-TempDir $preserveTempDir
        Remove-TempDir $nightlyRollbackDir
    }
}

function Invoke-NightlyUpdaterJar {
    <#
    .SYNOPSIS
        Execute gtnh-daily-updater binary, streaming output.
    .PARAMETER JavaPath
        Unused - kept for call-site compatibility. Pass $null.
    .PARAMETER JarPath
        Full path to the gtnh-daily-updater binary.
    .PARAMETER Channel
        The nightly channel: 'daily' or 'experimental'.
    .PARAMETER Targets
        Hashtable of target->path (e.g., @{ 'server' = 'D:\path' }).
    .OUTPUTS
        $true if exited with code 0, $false otherwise.
    #>
    param(
        [string]$JavaPath,
        [Parameter(Mandatory)][string]$JarPath,
        [Parameter(Mandatory)][ValidateSet('daily', 'experimental')][string]$Channel,
        [Parameter(Mandatory)][hashtable]$Targets
    )

    Write-Log "[NIGHTLY] Executing: $JarPath update --mode $Channel ..."
    Write-Info "Command: gtnh-daily-updater update --mode $Channel ..."

    try {
        foreach ($targetKey in $Targets.Keys) {
            $instancePath = $Targets[$targetKey]
            $side = $targetKey.ToLower()

            # Auto-init if the instance has not been initialized yet
            $stateFile = Join-Path $instancePath '.gtnh-daily-updater-state.json'
            if (-not (Test-Path -LiteralPath $stateFile)) {
                Write-Info "Initializing daily updater for $targetKey instance..."
                & $JarPath init --instance-dir $instancePath --side $side --mode $Channel 2>&1 |
                    ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "Init failed for $targetKey."
                    return $false
                }
                Write-Success "Initialized."
            }

            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $JarPath
            foreach ($arg in @('update', '--instance-dir', $instancePath)) {
                $processInfo.ArgumentList.Add($arg)
            }
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError  = $true
            $processInfo.UseShellExecute  = $false
            $processInfo.CreateNoWindow   = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            $process.Start() | Out-Null

            $stderrTask = $process.StandardError.ReadToEndAsync()
            $lastLines = @()
            while (-not $process.StandardOutput.EndOfStream) {
                $line = $process.StandardOutput.ReadLine()
                Write-Host "    $line" -ForegroundColor Gray
                Write-Log "[DAILY] $line"
                $lastLines += $line
                if ($lastLines.Count -gt 20) { $lastLines = $lastLines[-20..-1] }
            }

            $stderr = $stderrTask.GetAwaiter().GetResult()
            $exited = $process.WaitForExit(1800000)
            if (-not $exited) {
                Write-Err "Daily updater timed out after 30 minutes."
                try { $process.Kill() } catch {}
                return $false
            }

            if ($process.ExitCode -ne 0) {
                Write-Err "Daily updater failed (exit code $($process.ExitCode))."
                if ($stderr) { Write-Err "stderr: $stderr" }
                Write-Log "[ERROR] Daily updater exit $($process.ExitCode). stderr: $stderr"
                return $false
            }

            try { $process.Dispose() } catch {}
        }
        return $true
    }
    catch {
        Write-Err "Failed to execute daily updater: $($_.Exception.Message)"
        Write-Log "[ERROR] Daily updater execution failed: $($_.Exception.ToString())"
        return $false
    }
}