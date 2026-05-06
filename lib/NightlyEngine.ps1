# ============================================================================
# Group 11: Daily/Experimental Update Engine - Orchestrate dev build updates
# ============================================================================
# Functions:
#   Invoke-NightlyUpdate     - Full update flow: Java check -> JAR update ->
#                               back up custom mods -> invoke JAR -> restore ->
#                               patch -> verify -> history
#   Invoke-NightlyUpdaterJar - Build and execute the Java command line, stream output
#
# Daily/Experimental updates use the official gtnh-nightly-updater.jar which
# handles downloading and applying the update. This engine wraps it with
# custom mod preservation, config patching, and verification.
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

    # ── Step 1: Check Java 21+ ────────────────────────────────────────────────
    Write-Step "Checking Java version..."

    $javaPath = $Config.JavaPath
    if ([string]::IsNullOrEmpty($javaPath) -or -not (Test-Path -LiteralPath $javaPath)) {
        Write-Err "Java path not configured or not found: $javaPath"
        Write-Info "Configure a valid Java 21+ path in Settings."
        return
    }

    # Parse Java version
    $javaVersionOutput = $null
    try {
        $javaVersionOutput = & $javaPath -version 2>&1 | Out-String
    }
    catch {
        Write-Err "Could not execute Java: $($_.Exception.Message)"
        return
    }

    $javaMajorVersion = 0
    if ($javaVersionOutput -match '"(\d+)[\._]') {
        $javaMajorVersion = [int]$Matches[1]
    } elseif ($javaVersionOutput -match 'version "(\d+)') {
        $javaMajorVersion = [int]$Matches[1]
    }

    if ($javaMajorVersion -lt 21) {
        Write-Err "Java 21 or newer is required for daily/experimental channels. Found: Java $javaMajorVersion"
        Write-Info "Path: $javaPath"
        Write-Info "Download Java 21+: https://adoptium.net/temurin/releases/"
        return
    }

    Write-Success "Java $javaMajorVersion detected."

    # ── Step 2: Get/update nightly updater JAR ────────────────────────────────
    Write-Step "Checking updater JAR..."

    $jarPath = Get-LatestNightlyUpdater -Config $Config
    if (-not $jarPath) {
        Write-Err "Updater JAR is not available. Cannot proceed."
        return
    }

    Write-Success "Updater ready: $(Split-Path -Leaf $jarPath)"

    # ── Step 3: Preserve custom mods from config saved list ───────────────────
    Write-Step "Backing up custom mods..."

    $savedMods = $Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @())
    $customModTempDir = Join-Path $script:TempDir 'nightly-custom-mods'

    if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
        Remove-Item -LiteralPath $customModTempDir -Recurse -Force
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
        if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
            try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
        }
        return
    }

    # ── Preserve critical files ──────────────────────────────────────────────────
    Write-Step "Preserving critical files..."

    $preserveTempDir = Join-Path $script:TempDir 'nightly-preserved'
    if (Test-Path -LiteralPath $preserveTempDir) {
        Remove-Item -LiteralPath $preserveTempDir -Recurse -Force
    }
    $preserveOk = Invoke-PreserveFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir
    if (-not $preserveOk) {
        Write-Warn "Some files could not be preserved. They may be lost during the update."
        if (-not (Confirm-Action "Continue anyway?")) {
            Write-Info "Update cancelled."
            if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
                try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
            }
            if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
                try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
            }
            return
        }
    }

    # ── Save rollback snapshot (mods/ and config/ before the JAR touches them) ──
    Write-Step "Saving rollback snapshot..."

    $nightlyRollbackDir = Join-Path $script:TempDir "rollback-nightly-${Target}"
    if (Test-Path -LiteralPath $nightlyRollbackDir) {
        try { Remove-Item -LiteralPath $nightlyRollbackDir -Recurse -Force } catch {}
    }
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
    if ($Target -eq 'server') {
        Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "  ║  Back up your server and make sure it is STOPPED.           ║" -ForegroundColor Red
        Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    } else {
        Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor DarkYellow
        Write-Host "  ║  Back up your client instance before continuing.            ║" -ForegroundColor DarkYellow
        Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor DarkYellow
    }
    Write-Host ""
    if (-not (Confirm-Action "Ready to proceed? Instance is backed up?")) {
        Write-Info "Update cancelled."
        if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
            try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
        }
        if ($nightlyRollbackDir -and (Test-Path -LiteralPath $nightlyRollbackDir)) {
            try { Remove-Item -LiteralPath $nightlyRollbackDir -Recurse -Force } catch {}
        }
        if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
            try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
        }
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

    $success = Invoke-NightlyUpdaterJar -JavaPath $javaPath -JarPath $jarPath -Channel $Channel -Targets $targets

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

        # Clean up temp dirs before returning
        if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
            try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
        }
        if ($nightlyRollbackDir -and (Test-Path -LiteralPath $nightlyRollbackDir)) {
            try { Remove-Item -LiteralPath $nightlyRollbackDir -Recurse -Force } catch {}
        }
        return
    }

    Write-Host ""

    # ── Step 4b: Restore preserved files ────────────────────────────────────────
    Write-Step "Restoring preserved files..."
    if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
        Invoke-RestoreFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir
    }

    # ── Step 5: Restore custom mods ───────────────────────────────────────────
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
                Copy-Item -LiteralPath $source -Destination (Join-Path $modsDir $modFile) -Force
                $restoredCount++
            }
        }
        Write-Success "Restored $restoredCount custom mod(s)."
    } else {
        Write-Info "No custom mods to restore."
    }

    # ── Step 6: Apply config patches ──────────────────────────────────────────
    Write-Step "Applying config patches..."

    Invoke-ConfigPatches -Config $Config -InstancePath $instancePath -Target $Target

    # ── Step 7: Run verification ──────────────────────────────────────────────
    Write-Step "Running verification..."

    Invoke-Verification -InstancePath $instancePath -Target $Target

    # ── Step 8: Record history ────────────────────────────────────────────────
    Write-Step "Recording update..."

    # Use cached nightly tag if available, otherwise fall back to date stamp
    $versionLabel = if ($script:CachedLatestNightly) {
        $script:CachedLatestNightly
    } else {
        "$Channel-$(Get-Date -Format 'yyyyMMdd')"
    }

    Add-UpdateHistoryEntry -Config $Config -Version $versionLabel -Channel $Channel -Target $Target

    # Only overwrite installed version if we have a real nightly tag, or the current
    # value is already a nightly stamp - avoids clobbering a real pack version with a date
    $currentInstalled = $Target -eq 'server' ? $Config.InstalledServerVersion : $Config.InstalledClientVersion
    $isAlreadyNightly = $currentInstalled -match 'nightly|daily|experimental|\d{8}'
    if ($script:CachedLatestNightly -or $isAlreadyNightly -or [string]::IsNullOrEmpty($currentInstalled)) {
        if ($Target -eq 'server') { $Config.InstalledServerVersion = $versionLabel }
        else { $Config.InstalledClientVersion = $versionLabel }
        Save-Config -Config $Config
    }

    # Clean up
    if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
        try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
    }
    if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
        try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
    }
    if ($nightlyRollbackDir -and (Test-Path -LiteralPath $nightlyRollbackDir)) {
        try { Remove-Item -LiteralPath $nightlyRollbackDir -Recurse -Force } catch {}
    }

    Write-Host ""
    Write-Success "$Channel update complete! $Target updated."
}

function Invoke-NightlyUpdaterJar {
    <#
    .SYNOPSIS
        Build and execute the nightly updater Java command, streaming output.
    .DESCRIPTION
        Constructs the command line:
          java -jar <jar> -M <CHANNEL> --add -s SERVER -m <path> --add -s CLIENT -m <path>
        Streams stdout line by line in gray text. Checks exit code.
    .PARAMETER JavaPath
        Full path to java.exe (Java 21+).
    .PARAMETER JarPath
        Full path to the nightly updater JAR.
    .PARAMETER Channel
        The nightly channel: 'daily' or 'experimental'.
    .PARAMETER Targets
        Hashtable of target->path (e.g., @{ 'server' = 'D:\path'; 'client' = 'C:\path' }).
    .OUTPUTS
        $true if the JAR exited with code 0, $false otherwise.
    #>
    param(
        [Parameter(Mandatory)][string]$JavaPath,
        [Parameter(Mandatory)][string]$JarPath,
        [Parameter(Mandatory)][ValidateSet('daily', 'experimental')][string]$Channel,
        [Parameter(Mandatory)][hashtable]$Targets
    )

    # Build the command arguments
    $channelFlag = $Channel.ToUpper()
    $javaArgs = @('-jar', $JarPath, '-M', $channelFlag)

    # Add target blocks
    foreach ($targetKey in $Targets.Keys) {
        $side = $targetKey.ToUpper()
        $path = $Targets[$targetKey]
        $javaArgs += '--add'
        $javaArgs += '-s'
        $javaArgs += $side
        $javaArgs += '-m'
        $javaArgs += $path
    }

    $commandLine = "$JavaPath $($javaArgs -join ' ')"
    Write-Log "[NIGHTLY] Executing: $commandLine"
    Write-Info "Command: java -jar $(Split-Path -Leaf $JarPath) -M $channelFlag ..."

    try {
        # Start the process and stream output
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $JavaPath
        # Use ArgumentList (array) instead of Arguments (string) for correct
        # handling of paths with spaces - no manual quoting needed
        foreach ($arg in $javaArgs) {
            $processInfo.ArgumentList.Add($arg)
        }
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null

        # Read stderr asynchronously to prevent deadlock when both stdout and
        # stderr buffers fill. Synchronous reads on both streams can hang if
        # the child process writes enough to stderr to fill the OS pipe buffer
        # while we're blocked reading stdout.
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # Stream stdout line by line in gray and log it
        $lastLines = @()
        while (-not $process.StandardOutput.EndOfStream) {
            $line = $process.StandardOutput.ReadLine()
            Write-Host "    $line" -ForegroundColor Gray
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "[JAR] $line"
            }
            $lastLines += $line
            # Keep only last 20 lines for error reporting
            if ($lastLines.Count -gt 20) {
                $lastLines = $lastLines[-20..-1]
            }
        }

        # Wait for stderr to finish and get the result
        $stderr = $stderrTask.GetAwaiter().GetResult()

        # Wait with timeout (30 minutes) to prevent hanging forever
        $exited = $process.WaitForExit(1800000)  # 30 min in milliseconds
        if (-not $exited) {
            Write-Err "Nightly updater timed out after 30 minutes."
            Write-Log "[ERROR] Nightly updater timed out - killing process."
            try { $process.Kill() } catch {}
            return $false
        }

        $exitCode = $process.ExitCode

        if ($exitCode -ne 0) {
            Write-Err "Nightly updater failed (exit code $exitCode)."
            if ($stderr) {
                Write-Err "stderr: $stderr"
            }
            if ($lastLines.Count -gt 0) {
                Write-Info "Last output lines:"
                $lastLines | Select-Object -Last 5 | ForEach-Object {
                    Write-Info "  $_"
                }
            }
            Write-Log "[ERROR] Nightly updater exit code $exitCode. stderr: $stderr"
            return $false
        }

        return $true
    }
    catch {
        Write-Err "Failed to execute nightly updater: $($_.Exception.Message)"
        Write-Log "[ERROR] Nightly updater execution failed: $($_.Exception.ToString())"
        return $false
    }
    finally {
        if ($process) {
            try { $process.Dispose() } catch {}
        }
    }
}
