# ============================================================================
# Group 11: Daily/Experimental Update Engine - Native mod download implementation
# ============================================================================
# Functions:
#   Invoke-NightlyUpdate       - Full update flow: fetch manifest -> diff ->
#                                 backup -> download mods -> update configs ->
#                                 patch -> verify -> history
#   Get-NightlyManifest        - Fetch daily/experimental manifest from DreamAssemblerXXL
#   Get-NightlyReleaseInfo     - Get latest nightly release tag + config zip URL
#   Compare-ModsWithManifest   - Diff current mods/ against manifest
#   Invoke-NightlyModSync      - Download new/updated mods, remove old ones
#   Invoke-NightlyConfigSync   - Download and extract configs from release zip
#   Get-MavenDownloadUrl       - Construct GTNH Maven URL for a github_mod
#   Read-NightlyState          - Read local state JSON (installed version tracking)
#   Save-NightlyState          - Write local state JSON
#
# Native PowerShell 7 implementation replacing the Caedis gtnh-daily-updater
# binary. Downloads mods from GTNH Maven, configs from GitHub release zips.
# No external binaries, no Java, no Git required. Cross-platform.
# ============================================================================

# ── Constants ─────────────────────────────────────────────────────────────────
$script:ManifestBaseUrl = 'https://raw.githubusercontent.com/GTNewHorizons/DreamAssemblerXXL/master/releases/manifests'
$script:GtnhMavenBase = 'https://nexus.gtnewhorizons.com/repository/public/com/github/GTNewHorizons'
$script:ModpackReleasesApi = 'https://api.github.com/repos/GTNewHorizons/GT-New-Horizons-Modpack/releases'
$script:NightlyStateFileName = '.gtnh-nightly-state.json'
$script:MaxParallelDownloads = 8

function Invoke-NightlyUpdate {
    <#
    .SYNOPSIS
        Orchestrate the full daily/experimental update flow for a given target.
    .DESCRIPTION
        Native PowerShell implementation that handles the complete update:
          1. Fetch manifest (mod list + versions)
          2. Get latest release info (config tag)
          3. Show update plan and confirm
          4. Full instance backup (if enabled)
          5. Rollback snapshot (lightweight, for quick recovery)
          6. Handle stable-to-nightly transition (clean wipe)
          7. Preserve user files (JourneyMap, NEI, etc.)
          8. Sync mods (download new, remove old, preserve custom/override)
          9. Sync configs (from release zip)
         10. Restore preserved files
         11. Apply config patches (user-specific tweaks)
         12. Run verification (duplicate detection, integrity)
         13. Record history + save state
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
        [Parameter(Mandatory)][ValidateSet('daily', 'experimental')][string]$Channel,
        [switch]$SkipPostMenu
    )

    $instancePath = $Target -eq 'server' ? $Config.ServerPath : $Config.ClientInstancePath
    $nightlyRollbackDir = $null

    if ([string]::IsNullOrEmpty($instancePath)) {
        Write-Err "No $Target path configured. Run setup wizard first."
        return
    }

    if (-not (Test-Path -LiteralPath $instancePath)) {
        Write-Err "$Target path does not exist: $instancePath"
        return
    }

    # ── Running instance detection ────────────────────────────────────────────
    # Block updates if the game/server is running to prevent file corruption
    $instanceRunning = $false
    Write-Log "[NIGHTLY] Checking for running instance at: $instancePath"
    try {
        if ($IsWindows) {
            $javaProcs = Get-CimInstance Win32_Process -Filter "Name LIKE 'java%'" -ErrorAction SilentlyContinue
            foreach ($proc in $javaProcs) {
                if ($proc.CommandLine) {
                    # Normalize path separators for comparison (java may use / or \)
                    $normalizedCmd = $proc.CommandLine.Replace('/', '\')
                    $normalizedPath = $instancePath.Replace('/', '\')
                    if ($normalizedCmd -like "*$normalizedPath*") {
                        $instanceRunning = $true
                        Write-Log "[NIGHTLY] Detected running java process (PID $($proc.ProcessId)) with instance path in command line"
                        break
                    }
                }
            }
        } else {
            # Linux: check /proc/*/cmdline
            $javaProcs = Get-Process -Name 'java' -ErrorAction SilentlyContinue
            foreach ($proc in $javaProcs) {
                $cmdline = Get-Content "/proc/$($proc.Id)/cmdline" -Raw -ErrorAction SilentlyContinue
                if ($cmdline -and $cmdline -like "*$instancePath*") {
                    $instanceRunning = $true
                    Write-Log "[NIGHTLY] Detected running java process (PID $($proc.Id)) with instance path in cmdline"
                    break
                }
            }
        }
    } catch {
        Write-Log "[NIGHTLY] Process detection failed (non-fatal): $($_.Exception.Message)"
    }

    # Also check session.lock for servers (Minecraft holds this file open while running)
    if (-not $instanceRunning -and $Target -eq 'server') {
        $sessionLock = Join-Path $instancePath 'world' 'session.lock'
        if (Test-Path -LiteralPath $sessionLock) {
            try {
                $stream = [System.IO.File]::Open($sessionLock, 'Open', 'ReadWrite', 'None')
                $stream.Close()
                $stream.Dispose()
                Write-Log "[NIGHTLY] session.lock opened exclusively - server is NOT running"
            } catch {
                $instanceRunning = $true
                Write-Log "[NIGHTLY] session.lock is locked - server appears to be running"
            }
        }

        # Also check for server.pid file
        $pidFile = Join-Path $instancePath 'server.pid'
        if (-not $instanceRunning -and (Test-Path -LiteralPath $pidFile)) {
            $pidContent = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
            if ($pidContent) {
                $pid = $pidContent.Trim() -as [int]
                if ($null -ne $pid) {
                    try {
                        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
                        if ($proc -and $proc.ProcessName -match 'java') {
                            $instanceRunning = $true
                            Write-Log "[NIGHTLY] server.pid points to running java process (PID $pid)"
                        }
                    } catch {}
                }
            }
        }
    }

    if ($instanceRunning) {
        Write-Host ""
        Write-Err "Minecraft appears to be running from this instance!"
        Write-Info "Close the game/server before updating to prevent file corruption."
        Write-Host ""
        if (-not (Confirm-Action "Force update anyway? (RISK OF CORRUPTION)")) {
            return
        }
        Write-Warn "Proceeding despite running instance. You have been warned."
        Write-Log "[NIGHTLY] User forced update despite running instance detection"
    }

    Write-Header "$($Channel.ToUpper()) Update - $($Target.ToUpper())"

    # ── Step 1: Fetch manifest ────────────────────────────────────────────────
    Write-Step "Fetching $Channel manifest..."

    $manifest = Get-NightlyManifest -Channel $Channel
    if (-not $manifest) {
        Write-Err "Could not fetch $Channel manifest. Check your internet connection."
        return
    }

    $configTag = $manifest.config
    if (-not $configTag) {
        Write-Err "Manifest is missing the 'config' field. The manifest may be malformed."
        Write-Info "This is usually a temporary issue. Try again in a few minutes."
        return
    }
    if (-not $manifest.github_mods) {
        Write-Err "Manifest is missing 'github_mods'. The manifest may be malformed."
        Write-Info "This is usually a temporary issue. Try again in a few minutes."
        return
    }
    $githubModCount = @($manifest.github_mods.PSObject.Properties).Count
    $externalModCount = if ($manifest.external_mods) { @($manifest.external_mods.PSObject.Properties).Count } else { 0 }
    $totalModCount = $githubModCount + $externalModCount
    Write-Success "Manifest loaded: $totalModCount mods, config: $configTag"
    Write-Host ""

    # ── Step 2: Get release info ──────────────────────────────────────────────
    Write-Step "Checking release info..."

    $releaseInfo = Get-NightlyReleaseInfo -ConfigTag $configTag
    $versionLabel = $configTag

    # Read current state
    $state = Read-NightlyState -InstancePath $instancePath
    $currentVersion = if ($state) { $state.InstalledVersion } else { '' }

    # Also check the config's tracked version as fallback
    if ([string]::IsNullOrEmpty($currentVersion)) {
        $currentVersion = $Target -eq 'server' ? $Config.InstalledServerVersion : $Config.InstalledClientVersion
        if ([string]::IsNullOrEmpty($currentVersion)) { $currentVersion = '' }
    }

    # ── Step 3: Compute mod diff and show update plan ───────────────────────
    # Detect stable-to-nightly transition: only trigger if the current version looks
    # like a pure stable release (X.Y.Z with no nightly/daily/date indicators)
    $isTransition = $false
    if ([string]::IsNullOrEmpty($currentVersion)) {
        # No version recorded - check if mods/ has content to decide
        $modsDir = Join-Path $instancePath 'mods'
        $hasExistingMods = (Test-Path -LiteralPath $modsDir) -and
            @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count -gt 10
        if ($hasExistingMods) {
            # Has mods but no version - assume stable, trigger transition
            Write-Info "No version recorded but mods exist. Treating as stable-to-daily transition."
            $isTransition = $true
        }
        # If no mods either, it's a fresh install - no transition needed, just download everything
    } elseif (-not [string]::IsNullOrEmpty($currentVersion)) {
        $looksLikeNightly = $currentVersion -match 'nightly|daily|experimental|\d{4}-\d{2}-\d{2}'
        $looksLikePreRelease = $currentVersion -match '[-_](beta|rc|pre|alpha)'
        # Only transition if it's a clean stable version (not nightly, not pre-release)
        # Pre-release/beta versions are close enough to nightly that a full wipe isn't needed
        $isTransition = -not $looksLikeNightly -and -not $looksLikePreRelease
    }
    Write-Log "[NIGHTLY] Version check: current='$currentVersion' target='$versionLabel' isTransition=$isTransition"

    # Validate nightly state matches reality: if the state says we're on a nightly
    # but the mods on disk don't match (user manually restored files), force a transition
    if (-not $isTransition -and $state -and $state.ManifestMods) {
        $modsDir = Join-Path $instancePath 'mods'
        if (Test-Path -LiteralPath $modsDir) {
            $stateModCount = @($state.ManifestMods.PSObject.Properties).Count
            if ($stateModCount -gt 0) {
                # Spot-check: verify at least 50% of the state's mods exist on disk
                $foundCount = 0
                $checkCount = [math]::Min(20, $stateModCount)
                $sampled = @($state.ManifestMods.PSObject.Properties | Select-Object -First $checkCount)
                foreach ($prop in $sampled) {
                    if (Test-Path -LiteralPath (Join-Path $modsDir $prop.Value)) {
                        $foundCount++
                    }
                }
                $matchRatio = $foundCount / $checkCount
                if ($matchRatio -lt 0.5) {
                    Write-Warn "Mods on disk don't match the recorded state."
                    Write-Info "It looks like files were restored or replaced outside the updater."
                    Write-Info "A clean transition will be performed."
                    Write-Host ""
                    $isTransition = $true
                    # Clear stale state so it doesn't confuse future runs
                    $state = $null
                    $currentVersion = ''
                    $statePath = Join-Path $instancePath '.gtnh-nightly-state.json'
                    if (Test-Path -LiteralPath $statePath) {
                        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    # Second check: config says nightly but no state file exists (or state has no mod tracking)
    # Verify by checking if a few manifest mods are actually present on disk
    if (-not $isTransition -and (-not $state -or -not $state.ManifestMods -or @($state.ManifestMods.PSObject.Properties).Count -eq 0) -and $currentVersion -match 'nightly|daily|experimental|\d{4}-\d{2}-\d{2}') {
        $modsDir = Join-Path $instancePath 'mods'
        if (Test-Path -LiteralPath $modsDir) {
            # Spot-check a few mods from the current manifest against disk
            $manifestCheckCount = 0
            $manifestFoundCount = 0
            $checkMods = @($manifest.github_mods.PSObject.Properties | Select-Object -First 10)
            foreach ($prop in $checkMods) {
                $modSide = $prop.Value.side.ToUpper()
                $targetSide = $Target.ToUpper()
                if ($modSide -ne 'BOTH' -and $modSide -ne $targetSide) { continue }
                $expectedFile = "$($prop.Name)-$($prop.Value.version).jar"
                $manifestCheckCount++
                if (Test-Path -LiteralPath (Join-Path $modsDir $expectedFile)) {
                    $manifestFoundCount++
                }
            }
            if ($manifestCheckCount -gt 0 -and ($manifestFoundCount / $manifestCheckCount) -lt 0.3) {
                Write-Warn "Instance appears to have been restored to a non-daily state."
                Write-Info "A clean transition will be performed."
                Write-Host ""
                $isTransition = $true
                $currentVersion = ''
            }
        }
    }

    # "Already on this version" check - only if we haven't detected a state mismatch
    if (-not $isTransition -and $currentVersion -eq $versionLabel) {
        Write-Info "Already on $versionLabel."
        Write-Host ""
        if (-not (Confirm-Action "Re-apply this version anyway? (will re-download changed mods)")) {
            Write-Info "Update skipped."
            return
        }
    }

    # ── Downgrade warning ─────────────────────────────────────────────────────
    # If target version appears older than current, warn the user
    if (-not $isTransition -and $currentVersion -and $versionLabel -and $currentVersion -ne $versionLabel) {
        # For date-based versions (YYYY-MM-DD), compare dates
        $currentDate = $null; $targetDate = $null
        if ($currentVersion -match '(\d{4}-\d{2}-\d{2})') { $currentDate = $Matches[1] }
        if ($versionLabel -match '(\d{4}-\d{2}-\d{2})') { $targetDate = $Matches[1] }

        if ($currentDate -and $targetDate -and $targetDate -lt $currentDate) {
            Write-Host ""
            Write-Warn "Target version ($versionLabel) appears OLDER than current ($currentVersion)."
            Write-Info "This would downgrade your instance."
            Write-Log "[NIGHTLY] Downgrade detected: current='$currentVersion' target='$versionLabel'"
            if (-not (Confirm-Action "Proceed with downgrade?")) {
                Write-Info "Update cancelled."
                return
            }
            Write-Log "[NIGHTLY] User confirmed downgrade from '$currentVersion' to '$versionLabel'"
        }
    }

    # Compute the mod diff early so we can show it in the plan (skip for transitions -- everything is new)
    $precomputedDiff = $null
    if (-not $isTransition) {
        $precomputedDiff = Compare-ModsWithManifest -Manifest $manifest -InstancePath $instancePath `
            -Target $Target -State $state -Config $Config
    }

    # ── Stale custom mod detection ────────────────────────────────────────────
    # Check if any custom mods in config no longer exist on disk (removed manually, etc.)
    # Skip during transitions — mods folder gets wiped anyway
    $customModsList = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
    if ($customModsList.Count -gt 0 -and -not $isTransition) {
        $modsDir = Join-Path $instancePath 'mods'
        $staleMods = @()
        if (Test-Path -LiteralPath $modsDir) {
            # Build base name lookup of all jars on disk for fuzzy matching
            $diskBaseNames = @{}
            Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $diskBaseNames[(Get-ModBaseName -FileName $_.Name)] = $_.Name
            }
            foreach ($customFile in $customModsList) {
                $customPath = Join-Path $modsDir $customFile
                if (-not (Test-Path -LiteralPath $customPath)) {
                    # Exact file not found - check base name match (handles version bumps)
                    $customBase = Get-ModBaseName -FileName $customFile
                    if (-not $diskBaseNames.ContainsKey($customBase)) {
                        $staleMods += $customFile
                    }
                }
            }
        } else {
            # No mods dir at all - all custom mods are stale
            $staleMods = @($customModsList)
        }

        if ($staleMods.Count -gt 0) {
            Write-Warn "$($staleMods.Count) custom mod(s) not found on disk:"
            foreach ($stale in $staleMods) {
                Write-Info "  - $stale"
            }
            if (Confirm-Action "Remove stale entries from custom mods list?") {
                if ($Target -eq 'server') {
                    $Config.CustomServerMods = @($Config.CustomServerMods | Where-Object { $_ -notin $staleMods })
                } else {
                    $Config.CustomClientMods = @($Config.CustomClientMods | Where-Object { $_ -notin $staleMods })
                }
                Save-Config -Config $Config
                Write-Success "Removed $($staleMods.Count) stale entry/entries from custom mods list."
            }
            Write-Host ""
        }
    }

    $confirmed = Show-NightlyUpdatePlan -Config $Config -Target $Target -Channel $Channel `
        -InstancePath $instancePath -VersionLabel $versionLabel -CurrentVersion $currentVersion `
        -Manifest $manifest -IsTransition $isTransition -ModDiff $precomputedDiff
    if (-not $confirmed) {
        Write-Info "Update cancelled."
        return
    }

    # If user marked custom mods during the plan display, filter them from ToRemove
    # so the sync step doesn't delete newly-marked custom mods
    if ($precomputedDiff -and $precomputedDiff.ToRemove.Count -gt 0) {
        $updatedCustomMods = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
        if ($updatedCustomMods.Count -gt 0) {
            $customBaseNames = @{}
            foreach ($cm in $updatedCustomMods) {
                $customBaseNames[(Get-ModBaseName -FileName $cm)] = $true
            }
            $precomputedDiff.ToRemove = @($precomputedDiff.ToRemove | Where-Object {
                $fn = Split-Path -Leaf $_
                $base = Get-ModBaseName -FileName $fn
                -not $customBaseNames.ContainsKey($base)
            })
        }
    }

    # ── Step 4: Full instance backup (if enabled) ─────────────────────────────
    # Config diff detection is now manual-only (Settings > Config Patches > Re-scan)
    # to avoid false positives from game-modified config files.
    $baselinePath = Join-Path $instancePath '.gtnh-config-baseline.zip'
    $hasBaseline = Test-Path -LiteralPath $baselinePath
    $patchCount = @($Config.ConfigPatches | Where-Object { $_.Target -eq $Target -or $_.Target -eq 'both' }).Count

    if (-not $hasBaseline -and -not $isTransition -and $patchCount -eq 0) {
        # First update with this tool - warn about config reset
        Write-Host ""
        Write-Warn "This is your first update with this tool for $Target."
        Write-Info "Any config changes you've made (like disabling pollution) will be"
        Write-Info "reset to pack defaults. After this update, use:"
        Write-Info "  Settings > Config Patches > Re-scan"
        Write-Info "to detect and save your changes for future updates."
        Write-Host ""
    }

    $backupOk = Invoke-FullInstanceBackup -Config $Config -InstancePath $instancePath -Target $Target -Silent
    if ($backupOk -eq $false) {
        Write-Err "Backup failed. Update cancelled for safety."
        Write-Info "Fix the backup issue or disable backups in Settings, then try again."
        return
    }

    # Wrap the destructive portion in try/finally to ensure temp cleanup on any failure
    $preserveTempDir = $null
    try {

    # ── Step 5: Rollback snapshot ─────────────────────────────────────────────
    # Pre-flight: check available disk space before creating snapshot
    try {
        $instanceDrive = (Get-Item -LiteralPath $instancePath).PSDrive
        $freeBytes = $instanceDrive.Free
        # Quick size estimate: count mods and multiply by average mod size (~5MB)
        # This avoids the slow recursive Get-ChildItem on large mod folders
        $modsDir = Join-Path $instancePath 'mods'
        $modCount = if (Test-Path -LiteralPath $modsDir) {
            @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count
        } else { 0 }
        $estimatedSize = $modCount * 5MB + 50MB  # mods + config/resources/scripts estimate
        # Need roughly 2x the instance size (snapshot + download headroom)
        $requiredSpace = $estimatedSize * 2
        if ($freeBytes -gt 0 -and $requiredSpace -gt 0 -and $freeBytes -lt $requiredSpace) {
            $freeMB = [math]::Round($freeBytes / 1MB)
            $neededMB = [math]::Round($requiredSpace / 1MB)
            Write-Warn "Low disk space: ${freeMB} MB free, estimated ${neededMB} MB needed."
            Write-Warn "The update may fail partway through if disk fills up."
            if (-not (Confirm-Action "Continue anyway?")) {
                Write-Info "Update cancelled. Free up disk space and try again."
                return
            }
        }
    } catch {
        Write-Log "[NIGHTLY] Disk space check failed (non-fatal): $($_.Exception.Message)"
    }

    Write-Step "Saving rollback snapshot..."
    $nightlyFoldersToSnapshot = @('mods', 'config', 'resources', 'scripts')
    $nightlyRollbackDir = Join-Path (Split-Path -Parent $instancePath) ".gtnh-rollback-nightly-${Target}"
    if (Test-Path -LiteralPath $nightlyRollbackDir) {
        Remove-Item -LiteralPath $nightlyRollbackDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $nightlyRollbackDir -ItemType Directory -Force | Out-Null

    try {
        if (-not $isTransition -and $precomputedDiff) {
            # SELECTIVE SNAPSHOT: Only back up files that will actually change.
            # For incremental updates this is much faster than copying all 300+ mods.

            # Mark this as a selective snapshot so rollback knows to restore files individually
            New-Item -Path (Join-Path $nightlyRollbackDir '.selective-snapshot') -ItemType File -Force | Out-Null

            # Always snapshot config/ and scripts/ fully (config zip replaces them entirely)
            # Use Move-Item for instant moves on same drive (they get replaced by config zip anyway)
            foreach ($folder in @('config', 'resources', 'scripts')) {
                $sourcePath = Join-Path $instancePath $folder
                if (Test-Path -LiteralPath $sourcePath) {
                    Move-Item -LiteralPath $sourcePath -Destination (Join-Path $nightlyRollbackDir $folder) -Force
                    New-Item -Path $sourcePath -ItemType Directory -Force | Out-Null
                }
            }

            # For mods/, only snapshot files that will be removed or replaced
            $modsSnapshotDir = Join-Path $nightlyRollbackDir 'mods'
            New-Item -Path $modsSnapshotDir -ItemType Directory -Force | Out-Null

            # Save the current mods file list so rollback can detect newly-added files
            $modsDir = Join-Path $instancePath 'mods'
            if (Test-Path -LiteralPath $modsDir) {
                $currentModNames = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $currentModNames | Set-Content -LiteralPath (Join-Path $nightlyRollbackDir '.mods-before-update.txt') -Force
            }

            foreach ($filePath in $precomputedDiff.ToRemove) {
                if (Test-Path -LiteralPath $filePath) {
                    $destPath = Join-Path $modsSnapshotDir (Split-Path -Leaf $filePath)
                    Copy-Item -LiteralPath $filePath -Destination $destPath -Force
                }
            }
            $snappedModCount = $precomputedDiff.ToRemove.Count
            Write-Success "Snapshot saved (selective: $snappedModCount mod(s) + config/scripts)."
        }
        else {
            # FULL SNAPSHOT: Transition or no diff available — move everything (instant on same drive)
            foreach ($folder in $nightlyFoldersToSnapshot) {
                $sourcePath = Join-Path $instancePath $folder
                if (Test-Path -LiteralPath $sourcePath) {
                    Move-Item -LiteralPath $sourcePath -Destination (Join-Path $nightlyRollbackDir $folder) -Force
                    New-Item -Path $sourcePath -ItemType Directory -Force | Out-Null
                }
            }
            Write-Success "Snapshot saved."
        }
    }
    catch {
        Write-Warn "Could not save rollback snapshot: $($_.Exception.Message)"
        Write-Warn "If the update fails, automatic rollback will NOT be available."
        $nightlyRollbackDir = $null
        if (-not (Confirm-Action "Continue without rollback safety net?")) {
            Write-Info "Update cancelled."
            return
        }
    }

    # ── Step 6: Preserve user files ──────────────────────────────────────────
    # MUST happen before transition wipe (Step 7) so config/ files are still there
    Write-Step "Preserving user files..."
    $preserveTempDir = Join-Path $script:TempDir "preserved-nightly-${Target}"
    Invoke-PreserveFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir

    # ── Step 7: Handle stable-to-nightly transition ─────────────────────────────
    if ($isTransition) {
        Write-Step "Transitioning from stable to $Channel..."
        Write-Info "Clearing mods, config, and scripts for clean $Channel install..."

        $modsDir = Join-Path $instancePath 'mods'
        $configDir = Join-Path $instancePath 'config'
        $scriptsDir = Join-Path $instancePath 'scripts'

        # Save custom mods to temp BEFORE wiping (don't rely on rollback snapshot)
        $customMods = $Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @())
        $customModTempDir = Join-Path $script:TempDir "custom-mods-nightly-${Target}"
        if ($customMods.Count -gt 0 -and (Test-Path -LiteralPath $modsDir)) {
            New-Item -Path $customModTempDir -ItemType Directory -Force | Out-Null
            foreach ($customMod in $customMods) {
                $customPath = Join-Path $modsDir $customMod
                if (Test-Path -LiteralPath $customPath) {
                    Copy-Item -LiteralPath $customPath -Destination (Join-Path $customModTempDir $customMod) -Force
                }
            }
        }

        if (Test-Path -LiteralPath $modsDir) {
            Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -Recurse | Remove-Item -Force
        }
        if (Test-Path -LiteralPath $configDir) {
            $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Remove-Item -LiteralPath $configDir -Recurse -Force
            $ProgressPreference = $oldProgress
            New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $scriptsDir) {
            $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Remove-Item -LiteralPath $scriptsDir -Recurse -Force
            $ProgressPreference = $oldProgress
        }

        # Restore custom mods from temp (not from rollback -- rollback may be null)
        # Skip any custom mods that are also in the manifest (the manifest version supersedes)
        if (Test-Path -LiteralPath $customModTempDir) {
            # Build a set of manifest mod base names to detect conflicts
            $manifestBaseNames = @{}
            foreach ($prop in $manifest.github_mods.PSObject.Properties) {
                $manifestBaseNames[(Get-ModBaseName -FileName "$($prop.Name)-$($prop.Value.version).jar")] = $prop.Name
            }

            $savedCustom = Get-ChildItem -LiteralPath $customModTempDir -Filter '*.jar' -File -ErrorAction SilentlyContinue
            $restoredCustomCount = 0
            $skippedConflicts = @()
            foreach ($cm in $savedCustom) {
                $cmBase = Get-ModBaseName -FileName $cm.Name
                if ($manifestBaseNames.ContainsKey($cmBase)) {
                    # This custom mod conflicts with a manifest mod - skip it
                    $skippedConflicts += $cm.Name
                    Write-Log "[NIGHTLY] Skipping custom mod '$($cm.Name)' - superseded by manifest mod '$($manifestBaseNames[$cmBase])'"
                    continue
                }
                $destPath = Join-Path $modsDir $cm.Name
                Copy-Item -LiteralPath $cm.FullName -Destination $destPath -Force
                $restoredCustomCount++
                Write-Log "[NIGHTLY] Preserved custom mod: $($cm.Name)"
            }
            if ($restoredCustomCount -gt 0) {
                Write-Info "Preserved $restoredCustomCount custom mod(s)"
            }
            if ($skippedConflicts.Count -gt 0) {
                Write-Warn "$($skippedConflicts.Count) custom mod(s) skipped (newer version in $Channel pack):"
                foreach ($sc in $skippedConflicts) {
                    Write-Info "  $sc"
                }
                Write-Info "Remove these from Settings > Custom Mods if you want the pack version."
            }
            Remove-Item -LiteralPath $customModTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Success "Cleared for fresh $Channel install."
    }

    # ── Step 8: Sync mods ─────────────────────────────────────────────────────
    Write-Step "Syncing mods..."

    $modSyncResult = Invoke-NightlyModSync -Manifest $manifest -InstancePath $instancePath `
        -Target $Target -State $state -Config $Config -PrecomputedDiff $precomputedDiff

    if (-not $modSyncResult.Success) {
        Write-Err "Mod sync failed. Check output above for details."
        Invoke-NightlyRollback -RollbackDir $nightlyRollbackDir -InstancePath $instancePath `
            -FoldersToSnapshot $nightlyFoldersToSnapshot
        Remove-TempDir $nightlyRollbackDir
        Remove-TempDir $preserveTempDir
        return
    }

    # ── Step 9: Sync configs ──────────────────────────────────────────────────
    Write-Step "Syncing configs..."

    $configSyncOk = Invoke-NightlyConfigSync -ConfigTag $configTag -InstancePath $instancePath `
        -ReleaseInfo $releaseInfo -Manifest $manifest

    if (-not $configSyncOk) {
        Write-Err "Config sync failed. Mods were updated but configs may be missing/outdated."
        Write-Info "The instance may not work correctly without matching configs."
        Write-Host ""
        if ($nightlyRollbackDir -and (Confirm-Action "Rollback entire update to pre-update state?")) {
            Invoke-NightlyRollback -RollbackDir $nightlyRollbackDir -InstancePath $instancePath `
                -FoldersToSnapshot $nightlyFoldersToSnapshot
            Remove-TempDir $nightlyRollbackDir
            Remove-TempDir $preserveTempDir
            return
        }
        Write-Warn "Continuing with partial update. Re-run the update to retry config sync."
    }

    # ── Step 9b: Download missing external mods from gtnh-assets.json ──────────
    # External mods (Witchery, Thaumcraft, IC2, UniMixins, etc.) aren't on GTNH Maven.
    # The config sync (Step 9) may have placed some from the release zip's mods/ folder,
    # but naming conventions vary. This step is the authoritative source: it checks what's
    # actually on disk (case-insensitive) and only downloads what's truly missing.
    if ($manifest.external_mods) {
        $modsDir = Join-Path $instancePath 'mods'
        Write-Step "Checking external mods..."

        # Build a case-insensitive lookup of all jars currently in mods/ (includes
        # anything placed by config sync in Step 9)
        $existingJarsLower = @{}
        if (Test-Path -LiteralPath $modsDir) {
            Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $existingJarsLower[$_.Name.ToLower()] = $_.FullName
            }
            $subModsDir = Join-Path $modsDir '1.7.10'
            if (Test-Path -LiteralPath $subModsDir) {
                Get-ChildItem -LiteralPath $subModsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $existingJarsLower[$_.Name.ToLower()] = $_.FullName
                }
            }
        }

        # Fetch the assets database (same source as Caedis)
        $assetsUrl = 'https://raw.githubusercontent.com/GTNewHorizons/DreamAssemblerXXL/refs/heads/master/gtnh-assets.json'
        $gtnhAssets = $null
        try {
            $gtnhAssets = Invoke-RestMethod -Uri $assetsUrl -UserAgent 'GTNH-Updater-Script' -TimeoutSec 30 -ErrorAction Stop
            Write-Log "[NIGHTLY] Fetched gtnh-assets.json ($($gtnhAssets.mods.Count) mods)"
        }
        catch {
            Write-Warn "Could not fetch gtnh-assets.json: $($_.Exception.Message)"
            Write-Warn "External mods may be missing. You can manually add them to mods/."
        }

        if ($gtnhAssets) {
            $extDownloaded = 0
            $extFailed = 0
            $extSkipped = 0

            # First pass: build list of external mods that need downloading
            $extModsToDownload = @()
            foreach ($prop in $manifest.external_mods.PSObject.Properties) {
                $extModName = $prop.Name
                $extModInfo = $prop.Value
                $extSide = $extModInfo.side.ToUpper()
                $targetSide = $Target.ToUpper()
                if ($extSide -ne 'BOTH' -and $extSide -ne $targetSide -and $extSide -ne 'BOTH_JAVA9') { continue }

                # Check if this mod already exists (case-insensitive to catch mods placed by config sync)
                $checkModName = if ($extModName -eq 'UniMixins') { "+$extModName" } else { $extModName }
                $expectedJar = "${checkModName}-$($extModInfo.version).jar"
                if ($existingJarsLower.ContainsKey($expectedJar.ToLower())) {
                    $extSkipped++
                    continue
                }

                # Find this mod in the assets database
                $assetMod = $gtnhAssets.mods | Where-Object { $_.name -eq $extModName } | Select-Object -First 1
                if (-not $assetMod) {
                    Write-Log "[NIGHTLY] External mod '$extModName' not found in gtnh-assets.json"
                    continue
                }

                # Find the matching version
                $assetVersion = $assetMod.versions | Where-Object { $_.version_tag -eq $extModInfo.version } | Select-Object -First 1
                if (-not $assetVersion) {
                    Write-Log "[NIGHTLY] Version $($extModInfo.version) not found for '$extModName' in assets"
                    continue
                }

                # Get the download URL
                $downloadUrl = $assetVersion.download_url
                if (-not $downloadUrl) {
                    Write-Log "[NIGHTLY] No download_url for '$extModName' v$($extModInfo.version)"
                    continue
                }

                $fileModName = if ($extModName -eq 'UniMixins') { "+$extModName" } else { $extModName }
                $jarFileName = "${fileModName}-$($extModInfo.version).jar"

                $extModsToDownload += @{
                    Name        = $extModName
                    Version     = $extModInfo.version
                    Url         = $downloadUrl
                    FileName    = $jarFileName
                    CheckName   = $checkModName
                }
            }

            # Second pass: download in parallel with progress indicator
            $extTotal = $extModsToDownload.Count
            if ($extTotal -gt 0) {
                Write-Info "Downloading $extTotal external mod(s)..."

                $extDownloadResults = $extModsToDownload | ForEach-Object -ThrottleLimit $script:MaxParallelDownloads -Parallel {
                    $extMod = $_
                    $destModsDir = $using:modsDir
                    $httpClient = $null
                    try {
                        $httpClient = [System.Net.Http.HttpClient]::new()
                        $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
                        $httpClient.Timeout = [TimeSpan]::FromMinutes(3)
                        $modBytes = $httpClient.GetByteArrayAsync($extMod.Url).Result
                        if ($modBytes -and $modBytes.Length -gt 1024) {
                            # Remove old versions of this mod before writing new one
                            $oldVersions = Get-ChildItem -LiteralPath $destModsDir -Filter "$($extMod.CheckName)-*.jar" -File -ErrorAction SilentlyContinue
                            foreach ($old in $oldVersions) {
                                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                            }
                            $destPath = Join-Path $destModsDir $extMod.FileName
                            [System.IO.File]::WriteAllBytes($destPath, $modBytes)
                            return @{ Name = $extMod.Name; Success = $true }
                        } else {
                            return @{ Name = $extMod.Name; Success = $false; Error = "Download too small ($($modBytes.Length) bytes)" }
                        }
                    }
                    catch {
                        return @{ Name = $extMod.Name; Success = $false; Error = $_.Exception.Message }
                    }
                    finally {
                        if ($httpClient) { try { $httpClient.Dispose() } catch {} }
                    }
                }

                # Process results and show progress
                $extProgress = 0
                foreach ($result in $extDownloadResults) {
                    if ($result.Success) {
                        $extDownloaded++
                    } else {
                        Write-Warn "  Failed: $($result.Name) - $($result.Error)"
                        Write-Log "[NIGHTLY] External mod download failed: $($result.Name) - $($result.Error)"
                        $extFailed++
                    }
                    $extProgress++
                    $percent = [math]::Floor(($extProgress / $extTotal) * 100)
                    $bar = ('█' * [math]::Floor($percent / 2)).PadRight(50, '░')
                    Write-Host "`r$("  [$bar] ${percent}%  ${extProgress}/${extTotal} external mods".PadRight(80))" -NoNewline -ForegroundColor Gray
                }

                # Clear progress line
                Write-Host "`r$(' ' * 85)`r" -NoNewline
                Write-Host ""

                if ($extDownloaded -gt 0) {
                    Write-Success "Downloaded $extDownloaded external mod(s)."
                }
                if ($extFailed -gt 0) {
                    Write-Warn "$extFailed external mod(s) failed to download."
                }
            }
            if ($extSkipped -gt 0) {
                Write-Log "[NIGHTLY] $extSkipped external mod(s) already present, skipped."
            }
        }
    }

    # ── Track external mod filenames in InstalledMods for custom mod scan ─────
    # External mods aren't in $modSyncResult.InstalledMods because their filenames
    # are unknown at manifest-parse time. Now that Step 9/9b placed them on disk,
    # scan for them and add to the tracking map so the custom mod scan won't flag
    # them as user-added mods.
    if ($manifest.external_mods) {
        $extModsDir = Join-Path $instancePath 'mods'
        $targetSide = $Target.ToUpper()
        foreach ($prop in $manifest.external_mods.PSObject.Properties) {
            $extModName = $prop.Name
            $extModInfo = $prop.Value
            $extSide = $extModInfo.side.ToUpper()
            if ($extSide -ne 'BOTH' -and $extSide -ne $targetSide -and $extSide -ne 'BOTH_JAVA9') { continue }

            # Determine the expected filename (same logic as Step 9b)
            $fileModName = if ($extModName -eq 'UniMixins') { "+$extModName" } else { $extModName }
            $expectedJar = "${fileModName}-$($extModInfo.version).jar"

            # Check if it exists on disk (case-insensitive)
            $found = Get-ChildItem -LiteralPath $extModsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $expectedJar } | Select-Object -First 1
            if ($found) {
                $modSyncResult.InstalledMods[$extModName] = $found.Name
            } else {
                # Try base-name match for mods placed by the release zip with different naming
                $extBase = Get-ModBaseName -FileName $expectedJar
                $baseMatch = Get-ChildItem -LiteralPath $extModsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                    Where-Object { (Get-ModBaseName -FileName $_.Name) -eq $extBase } | Select-Object -First 1
                if ($baseMatch) {
                    $modSyncResult.InstalledMods[$extModName] = $baseMatch.Name
                }
            }
        }
        Write-Log "[NIGHTLY] ManifestMods now includes $($modSyncResult.InstalledMods.Count) mods (with externals)"
    }

    # ── Step 10: Restore preserved files ──────────────────────────────────────
    Write-Step "Restoring user files..."
    Invoke-RestoreFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir
    Remove-TempDir $preserveTempDir

    # ── Step 11: Apply config patches ─────────────────────────────────────────
    Write-Step "Applying config patches..."
    Invoke-ConfigPatches -Config $Config -InstancePath $instancePath -Target $Target

    # ── Step 12: Run verification ─────────────────────────────────────────────
    Write-Step "Running verification..."
    Invoke-Verification -InstancePath $instancePath -Target $Target -Quick

    # ── Step 13: Record history + save state ──────────────────────────────────
    Write-Step "Recording update..."

    Add-UpdateHistoryEntry -Config $Config -Version $versionLabel -Channel $Channel -Target $Target `
        -Details "+$($modSyncResult.Downloaded) -$($modSyncResult.Removed) ~$($modSyncResult.Unchanged)"

    if ($Target -eq 'server') { $Config.InstalledServerVersion = $versionLabel }
    else { $Config.InstalledClientVersion = $versionLabel }
    Save-Config -Config $Config

    # Save nightly state
    Save-NightlyState -InstancePath $instancePath -State @{
        InstalledVersion = $versionLabel
        Channel          = $Channel
        LastUpdated      = (Get-Date).ToString('o')
        ManifestMods     = $modSyncResult.InstalledMods
    }

    # ── Success ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║  Update complete!                                           ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  $Target updated to " -NoNewline -ForegroundColor Gray
    Write-Host "$versionLabel" -ForegroundColor Green
    Write-Host "  Channel: $Channel" -ForegroundColor Gray
    if ($modSyncResult.Downloaded -eq 0 -and $modSyncResult.Removed -eq 0) {
        Write-Host "  Mods: all $($modSyncResult.Unchanged) up to date" -ForegroundColor Gray
    }
    else {
        Write-Host "  Mods: $($modSyncResult.Downloaded) downloaded, $($modSyncResult.Removed) removed, $($modSyncResult.Unchanged) unchanged" -ForegroundColor Gray
    }
    Write-Host ""
    if (-not $SkipPostMenu) {
        $openLabel = if ($IsWindows) { "Open $Target folder in Explorer" } else { "Open $Target folder in file manager" }
        Write-MenuOption "O" $openLabel
        Write-MenuOption "Enter" "Return to main menu"
        $postChoice = Read-MenuChoice "Choose"
        if ($postChoice -eq 'O' -or $postChoice -eq 'o') {
            try { Open-FolderInFileManager -Path $instancePath } catch { Write-Warn "Could not open folder: $($_.Exception.Message)" }
        }
    }

    # Keep rollback snapshot until next update (allows user to rollback if game crashes on launch)
    # The snapshot will be overwritten by the next update's Step 5.
    if ($nightlyRollbackDir) {
        Write-Log "[NIGHTLY] Rollback snapshot preserved at: $nightlyRollbackDir"
    }

    } # end try
    finally {
        # Ensure temp directories are cleaned up even on unhandled exceptions
        Remove-TempDir $preserveTempDir
        # Note: rollback snapshot is intentionally kept on success — allows user to rollback
        # if the game crashes after a successful update. On failure, the snapshot was already
        # consumed by the automatic rollback offered earlier in the flow.
    }
}


# ── Manifest & Release Functions ──────────────────────────────────────────────

function Get-NightlyManifest {
    <#
    .SYNOPSIS
        Fetch the daily or experimental manifest from DreamAssemblerXXL.
    .DESCRIPTION
        Downloads the manifest JSON from the DreamAssemblerXXL repo which contains
        the full mod list with versions and side info for the specified channel.
    .PARAMETER Channel
        'daily' or 'experimental'.
    .OUTPUTS
        PSCustomObject parsed from the manifest JSON, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('daily', 'experimental')][string]$Channel
    )

    $manifestUrl = "$($script:ManifestBaseUrl)/${Channel}.json"
    Write-Log "[NIGHTLY] Fetching manifest: $manifestUrl"

    try {
        $headers = @{ 'User-Agent' = 'GTNH-Updater-Script' }
        $response = Invoke-RestMethod -Uri $manifestUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        return $response
    }
    catch {
        $ex = $_.Exception
        if (Test-IsNetworkException $ex) {
            Write-Err "Network request failed. Check your internet connection."
        }
        else {
            Write-Err "Failed to fetch manifest: $($ex.Message)"
        }
        Write-Log "[ERROR] Manifest fetch failed: $($ex.Message)"
        return $null
    }
}

function Get-NightlyReleaseInfo {
    <#
    .SYNOPSIS
        Get release info (zip download URL) for a specific config tag.
    .DESCRIPTION
        Queries the GT-New-Horizons-Modpack releases API to find the release
        matching the config tag. Returns the zip asset URL for config extraction.
    .PARAMETER ConfigTag
        The config version tag (e.g., '2.9.0-nightly-2026-05-11').
    .OUTPUTS
        PSCustomObject with TagName, ZipUrl, ZipSize, ZipName, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigTag
    )

    $tagUrl = "https://api.github.com/repos/GTNewHorizons/GT-New-Horizons-Modpack/releases/tags/$ConfigTag"
    Write-Log "[NIGHTLY] Fetching release info for tag: $ConfigTag"

    $release = Invoke-GitHubApi -Uri $tagUrl
    if ($release) {
        $zipAsset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($zipAsset) {
            return [PSCustomObject]@{
                TagName = $release.tag_name
                ZipUrl  = $zipAsset.browser_download_url
                ZipSize = $zipAsset.size
                ZipName = $zipAsset.name
            }
        }
    }

    # Fallback: construct the URL from known patterns
    $fallbackUrl = "https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/releases/download/$ConfigTag/${ConfigTag}.zip"
    Write-Log "[NIGHTLY] Using fallback release URL: $fallbackUrl"

    return [PSCustomObject]@{
        TagName = $ConfigTag
        ZipUrl  = $fallbackUrl
        ZipSize = 0
        ZipName = "${ConfigTag}.zip"
    }
}

# ── Mod Sync Functions ────────────────────────────────────────────────────────

function Get-MavenDownloadUrl {
    <#
    .SYNOPSIS
        Construct the GTNH Maven download URL for a github mod.
    .DESCRIPTION
        GTNH Maven URL pattern:
        https://nexus.gtnewhorizons.com/repository/public/com/github/GTNewHorizons/{ModName}/{Version}/{ModName}-{Version}.jar
    #>
    param(
        [Parameter(Mandatory)][string]$ModName,
        [Parameter(Mandatory)][string]$Version
    )

    return "$($script:GtnhMavenBase)/$ModName/$Version/${ModName}-${Version}.jar"
}

function Get-ExpectedModFileName {
    <#
    .SYNOPSIS
        Get the expected jar filename for a mod from the manifest.
    #>
    param(
        [Parameter(Mandatory)][string]$ModName,
        [Parameter(Mandatory)][string]$Version
    )

    return "${ModName}-${Version}.jar"
}

function Compare-ModsWithManifest {
    <#
    .SYNOPSIS
        Compare current mods/ folder contents against the manifest.
    .DESCRIPTION
        Scans the mods/ directory and compares against the manifest to determine
        which mods need to be downloaded, which are up-to-date, and which should
        be removed. Respects custom mods and override mods from config.
    .PARAMETER Manifest
        The parsed manifest object.
    .PARAMETER InstancePath
        Path to the game instance.
    .PARAMETER Target
        'server' or 'client' - determines which side mods to include.
    .PARAMETER State
        Current nightly state (previously installed mods tracking).
    .PARAMETER Config
        The config PSCustomObject (for custom/override mods).
    .OUTPUTS
        PSCustomObject with ToDownload, ToRemove, Unchanged, Expected, Skipped.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Manifest,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [PSCustomObject]$State,
        [PSCustomObject]$Config
    )

    $modsDir = Join-Path $instancePath 'mods'
    if (-not (Test-Path -LiteralPath $modsDir)) {
        New-Item -Path $modsDir -ItemType Directory -Force | Out-Null
    }

    # ── Build protected file lists (custom mods + override mods) ──────────────
    $customMods = @()
    $overrideMods = @()
    if ($Config) {
        $customMods = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
        $overrideMods = @($Target -eq 'server' ? ($Config.OverrideServerMods ?? @()) : ($Config.OverrideClientMods ?? @()))
    }

    # Build a set of protected BASE NAMES (custom mods that should never be removed)
    # Using base names instead of exact filenames handles the case where a user
    # manually updates their custom mod (e.g., MyMod-1.0.jar -> MyMod-1.1.jar)
    $protectedBaseNames = @{}
    $protectedFiles = @{}
    foreach ($cm in $customMods) {
        $protectedFiles[$cm] = 'custom'
        $baseName = Get-ModBaseName -FileName $cm
        $protectedBaseNames[$baseName] = 'custom'
    }

    # Build a set of overridden mod base names (mods the user replaces with their own version)
    $overriddenBaseNames = @{}
    $overrideSkippedMods = @()  # Track which manifest mods were skipped due to override
    foreach ($om in $overrideMods) {
        $baseName = Get-ModBaseName -FileName $om
        $overriddenBaseNames[$baseName] = $om
        $protectedFiles[$om] = 'override'
        $protectedBaseNames[$baseName] = 'override'
    }

    # ── Build the expected mod list from manifest (filter by side) ─────────────
    $expectedMods = @{}
    $skippedMods = @()
    $side = $Target.ToUpper()

    # Process github_mods
    foreach ($prop in $Manifest.github_mods.PSObject.Properties) {
        $modName = $prop.Name
        $modInfo = $prop.Value
        $modSide = $modInfo.side.ToUpper()

        # Include if BOTH, matches target side, or BOTH_JAVA9 (special lwjgl3ify case)
        if ($modSide -eq 'BOTH' -or $modSide -eq $side -or $modSide -eq 'BOTH_JAVA9') {
            # Check if this mod is overridden by the user
            $expectedFileName = Get-ExpectedModFileName -ModName $modName -Version $modInfo.version
            $modBaseName = Get-ModBaseName -FileName $expectedFileName
            if ($overriddenBaseNames.ContainsKey($modBaseName)) {
                $skippedMods += $modName
                # Track the version conflict for user notification
                $overrideSkippedMods += [PSCustomObject]@{
                    ModName     = $modName
                    PackVersion = $modInfo.version
                    YourFile    = $overriddenBaseNames[$modBaseName]
                }
                Write-Log "[NIGHTLY] Skipping overridden mod: $modName (user has: $($overriddenBaseNames[$modBaseName]))"
                continue
            }

            $expectedMods[$modName] = @{
                Version  = $modInfo.version
                FileName = $expectedFileName
                Source   = 'maven'
                Side     = $modSide
            }
        }
    }

    # Process external_mods — these come from the release zip (Step 9), not Maven.
    # They're tracked in Expected so we know what should be present, but NOT downloaded in Step 8.
    # Caedis downloads them from its own assets DB, but for us the release zip is the source.
    if ($Manifest.external_mods) {
        foreach ($prop in $Manifest.external_mods.PSObject.Properties) {
            $modName = $prop.Name
            $modInfo = $prop.Value
            $modSide = $modInfo.side.ToUpper()

            if ($modSide -eq 'BOTH' -or $modSide -eq $side -or $modSide -eq 'BOTH_JAVA9') {
                $expectedMods[$modName] = @{
                    Version  = $modInfo.version
                    FileName = $null  # Filename unknown — comes from release zip with unpredictable naming
                    Source   = 'external'
                    Side     = $modSide
                }
            }
        }
    }

    # ── Scan current mods/ directory ──────────────────────────────────────────
    $currentJars = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue)
    # Also check mods/1.7.10/ subfolder (coremods)
    $subModsDir = Join-Path $modsDir '1.7.10'
    if (Test-Path -LiteralPath $subModsDir) {
        $currentJars += @(Get-ChildItem -LiteralPath $subModsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue)
    }

    # Build lookup of current files
    $currentModFiles = @{}
    foreach ($jar in $currentJars) {
        $currentModFiles[$jar.Name] = $jar.FullName
    }

    # ── Determine downloads and removals ──────────────────────────────────────
    $toDownload = @()
    $unchanged = @()
    $toRemove = @()

    # Check which manifest mods need downloading
    foreach ($modName in $expectedMods.Keys) {
        $modEntry = $expectedMods[$modName]

        # External mods come from the release zip in Step 9, not Maven
        if ($modEntry.Source -eq 'external') { continue }

        $expectedFile = $modEntry.FileName
        if ($currentModFiles.ContainsKey($expectedFile)) {
            $unchanged += $modName
        }
        else {
            $toDownload += @{
                ModName  = $modName
                Version  = $modEntry.Version
                FileName = $expectedFile
                Url      = Get-MavenDownloadUrl -ModName $modName -Version $modEntry.Version
            }
        }
    }

    # Determine which existing jars to remove (old versions of managed mods)
    # Only the CURRENT expected files should be kept. External mods are excluded
    # since we don't know their filenames (they come from the zip with unpredictable names).
    $currentExpectedFiles = @{}
    foreach ($modName in $expectedMods.Keys) {
        if ($expectedMods[$modName].Source -ne 'external' -and $expectedMods[$modName].FileName) {
            $currentExpectedFiles[$expectedMods[$modName].FileName] = $true
        }
    }

    # Pre-compute base name -> expected filename lookup for O(1) removal detection
    # (avoids O(n*m) nested loop with 300+ mods on each side)
    $expectedBaseNameLookup = @{}
    foreach ($modName in $expectedMods.Keys) {
        if ($expectedMods[$modName].Source -eq 'external') { continue }
        if (-not $expectedMods[$modName].FileName) { continue }
        $baseName = Get-ModBaseName -FileName $expectedMods[$modName].FileName
        $expectedBaseNameLookup[$baseName] = $expectedMods[$modName].FileName
    }

    foreach ($jar in $currentJars) {
        $jarName = $jar.Name

        # Never remove protected files (custom mods, override mods) — match by base name
        # so that version-bumped custom mods are still protected
        if ($protectedFiles.ContainsKey($jarName)) {
            continue
        }
        $jarBaseName = Get-ModBaseName -FileName $jarName
        if ($protectedBaseNames.ContainsKey($jarBaseName)) {
            continue
        }

        # Skip if this is a currently-expected file (correct version already present)
        if ($currentExpectedFiles.ContainsKey($jarName)) {
            continue
        }

        # Check if it's an old version of a manifest mod using pre-computed base name lookup (O(1))
        if ($expectedBaseNameLookup.ContainsKey($jarBaseName)) {
            $expectedFile = $expectedBaseNameLookup[$jarBaseName]
            if ($jarName -ne $expectedFile) {
                $toRemove += $jar.FullName
            }
        }
    }

    # Remove jars from mods that were in the previous state but are no longer in manifest
    if ($State -and $State.ManifestMods) {
        foreach ($prop in $State.ManifestMods.PSObject.Properties) {
            $oldFileName = $prop.Value
            $oldModName = $prop.Name
            # Don't remove if it's protected or still expected
            if ($protectedFiles.ContainsKey($oldFileName)) { continue }
            if ($expectedMods.ContainsKey($oldModName)) { continue }
            if ($currentModFiles.ContainsKey($oldFileName)) {
                $toRemove += $currentModFiles[$oldFileName]
            }
        }
    }

    return [PSCustomObject]@{
        ToDownload       = $toDownload
        ToRemove         = @($toRemove | Select-Object -Unique)
        Unchanged        = $unchanged
        Expected         = $expectedMods
        Skipped          = $skippedMods
        OverrideConflicts = $overrideSkippedMods
    }
}

function Invoke-NightlyModSync {
    <#
    .SYNOPSIS
        Download new/updated mods and remove old ones based on manifest diff.
    .DESCRIPTION
        Compares the manifest against current mods, downloads missing/updated
        mods in parallel using PowerShell 7's ForEach-Object -Parallel, and
        removes old versions. Respects custom mods and override mods.
    .PARAMETER Manifest
        The parsed manifest object.
    .PARAMETER InstancePath
        Path to the game instance.
    .PARAMETER Target
        'server' or 'client'.
    .PARAMETER State
        Current nightly state.
    .PARAMETER Config
        The config PSCustomObject.
    .OUTPUTS
        PSCustomObject with Success, Downloaded, Removed, Unchanged, InstalledMods.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Manifest,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [PSCustomObject]$State,
        [PSCustomObject]$Config,
        [PSCustomObject]$PrecomputedDiff
    )

    $modsDir = Join-Path $instancePath 'mods'
    if (-not (Test-Path -LiteralPath $modsDir)) {
        New-Item -Path $modsDir -ItemType Directory -Force | Out-Null
    }

    # Use precomputed diff if available, otherwise compute fresh
    $diff = if ($PrecomputedDiff) { $PrecomputedDiff } else {
        Compare-ModsWithManifest -Manifest $Manifest -InstancePath $instancePath `
            -Target $Target -State $State -Config $Config
    }

    $downloadCount = $diff.ToDownload.Count
    $removeCount = $diff.ToRemove.Count
    $unchangedCount = $diff.Unchanged.Count
    $skippedCount = $diff.Skipped.Count

    Write-Info "Mod sync plan: $downloadCount to download, $removeCount to remove, $unchangedCount unchanged"
    if ($skippedCount -gt 0) {
        Write-Info "  ($skippedCount mod(s) skipped - overridden by user)"
    }

    # Remove old mods first
    $actualRemoved = 0
    if ($removeCount -gt 0) {
        foreach ($filePath in $diff.ToRemove) {
            if (-not (Test-Path -LiteralPath $filePath)) { continue }
            try {
                Remove-Item -LiteralPath $filePath -Force
                $actualRemoved++
                Write-Log "[NIGHTLY] Removed old mod: $(Split-Path -Leaf $filePath)"
            }
            catch {
                Write-Warn "Could not remove: $(Split-Path -Leaf $filePath) - $($_.Exception.Message)"
            }
        }
        if ($actualRemoved -gt 0) {
            Write-Info "Removed $actualRemoved old mod(s)."
        }
    }

    # Download new/updated mods
    $successCount = 0
    $failCount = 0

    if ($downloadCount -eq 0) {
        Write-Success "All mods are up to date."
    }
    else {
        Write-Info "Downloading $downloadCount mod(s)..."
        Write-Host ""

        $totalToDownload = $downloadCount
        $downloadStartTime = [System.Diagnostics.Stopwatch]::StartNew()

        # Use parallel downloads for speed (PS7 ForEach-Object -Parallel)
        # Each download tries: Maven then GitHub releases, with 2 retries per source
        # After download, validates the file is a valid jar (zip magic bytes PK + minimum size)
        $downloadResults = $diff.ToDownload | ForEach-Object -ThrottleLimit $script:MaxParallelDownloads -Parallel {
            $mod = $_
            $destPath = Join-Path $using:modsDir $mod.FileName
            $mavenUrl = $mod.Url
            $ghUrl = "https://github.com/GTNewHorizons/$($mod.ModName)/releases/download/$($mod.Version)/$($mod.FileName)"
            $maxRetries = 2
            $lastError = $null

            # Helper: validate downloaded file is a real jar (zip format)
            $validateJar = {
                param($path)
                if (-not (Test-Path -LiteralPath $path)) { return $false }
                $info = Get-Item -LiteralPath $path
                # Minimum size check (a valid mod jar is at least 1KB)
                if ($info.Length -lt 1024) { return $false }
                # Check zip magic bytes (PK = 0x50 0x4B)
                try {
                    $bytes = [byte[]]::new(4)
                    $fs = [System.IO.File]::OpenRead($path)
                    $fs.Read($bytes, 0, 4) | Out-Null
                    $fs.Dispose()
                    return ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
                }
                catch { return $false }
            }

            # Try each source with retries
            $urls = @($mavenUrl, $ghUrl)
            foreach ($url in $urls) {
                for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
                    $httpClient = $null
                    try {
                        if ($attempt -gt 0) {
                            [System.Threading.Thread]::Sleep(1000 * $attempt)  # Backoff: 1s, 2s
                        }
                        $httpClient = [System.Net.Http.HttpClient]::new()
                        $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
                        $httpClient.Timeout = [TimeSpan]::FromMinutes(5)

                        $responseBytes = $httpClient.GetByteArrayAsync($url).Result
                        [System.IO.File]::WriteAllBytes($destPath, $responseBytes)

                        # Validate the downloaded file
                        if (& $validateJar $destPath) {
                            # SHA1 checksum verification (Maven provides .sha1 files)
                            $sha1Valid = $true
                            try {
                                $sha1Url = "${url}.sha1"
                                $sha1Response = $httpClient.GetStringAsync($sha1Url).Result
                                if ($sha1Response -and $sha1Response.Length -ge 40) {
                                    $expectedHash = ($sha1Response.Trim() -split '\s')[0].ToLower()
                                    # Use .NET SHA1 directly (Get-FileHash may not be available in parallel runspace)
                                    $sha1 = [System.Security.Cryptography.SHA1]::Create()
                                    $fileBytes = [System.IO.File]::ReadAllBytes($destPath)
                                    $hashBytes = $sha1.ComputeHash($fileBytes)
                                    $actualHash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
                                    $sha1.Dispose()
                                    if ($expectedHash -ne $actualHash) {
                                        $sha1Valid = $false
                                        $lastError = "SHA1 mismatch: expected $expectedHash, got $actualHash"
                                        try { Remove-Item -LiteralPath $destPath -Force } catch {}
                                    }
                                }
                            } catch {
                                # SHA1 file not available — skip verification (not all sources provide it)
                            }
                            if ($sha1Valid) {
                                return @{ ModName = $mod.ModName; FileName = $mod.FileName; Success = $true; Error = $null }
                            }
                        }
                        else {
                            # File is invalid (HTML error page, truncated, etc.)
                            $lastError = "Downloaded file is not a valid jar (corrupted or redirect page)"
                            try { Remove-Item -LiteralPath $destPath -Force } catch {}
                        }
                    }
                    catch {
                        $lastError = $_.Exception.Message
                    }
                    finally {
                        if ($httpClient) { try { $httpClient.Dispose() } catch {} }
                    }
                }
            }

            # All attempts exhausted
            # Clean up any invalid file left behind
            if (Test-Path -LiteralPath $destPath) {
                try { Remove-Item -LiteralPath $destPath -Force } catch {}
            }
            return @{ ModName = $mod.ModName; FileName = $mod.FileName; Version = $mod.Version; Success = $false; Error = $lastError }
        }

        # Process results and show progress
        $failedMods = @()

        foreach ($result in $downloadResults) {
            if ($result.Success) {
                $successCount++
            }
            else {
                $failCount++
                $failedMods += $result
            }

            # Progress bar with ETA
            $progress = $successCount + $failCount
            $percent = [math]::Floor(($progress / $totalToDownload) * 100)
            $bar = ('█' * [math]::Floor($percent / 2)).PadRight(50, '░')
            $eta = ''
            if ($progress -gt 0 -and $progress -lt $totalToDownload) {
                $elapsed = $downloadStartTime.Elapsed.TotalSeconds
                $rate = $progress / $elapsed
                $remaining = ($totalToDownload - $progress) / $rate
                if ($remaining -lt 60) {
                    $eta = " ~$([math]::Ceiling($remaining))s"
                } else {
                    $eta = " ~$([math]::Floor($remaining / 60))m$([math]::Ceiling($remaining % 60))s"
                }
            }
            $statusLine = "  [$bar] ${percent}%  ${progress}/${totalToDownload}${eta}"
            Write-Host "`r$($statusLine.PadRight(80))" -NoNewline -ForegroundColor Gray
        }

        # Clear the progress bar line and move to next line
        Write-Host "`r$(' ' * 85)`r" -NoNewline
        Write-Host ""

        # Log all results (parallel blocks can't access Write-Log)
        if ($successCount -gt 0) {
            Write-Log "[NIGHTLY] Parallel download: $successCount mod(s) succeeded"
        }
        if ($failCount -gt 0) {
            foreach ($failed in $failedMods) {
                Write-Log "[NIGHTLY] Download failed: $($failed.ModName) v$($failed.Version) - $($failed.Error)"
            }
        }

        if ($failCount -gt 0) {
            Write-Warn "$failCount mod(s) failed from Maven. Retrying from GitHub..."
            Write-Host ""
            # Fallback: use gtnh-assets.json browser_download_url (same as Caedis)
            $fallbackAssets = $null
            try {
                $fallbackAssets = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/GTNewHorizons/DreamAssemblerXXL/refs/heads/master/gtnh-assets.json' -UserAgent 'GTNH-Updater-Script' -TimeoutSec 30 -ErrorAction Stop
            } catch { }

            foreach ($failed in $failedMods) {
                $ghUrl = $null
                if ($fallbackAssets) {
                    $assetMod = $fallbackAssets.mods | Where-Object { $_.name -eq $failed.ModName } | Select-Object -First 1
                    if ($assetMod) {
                        $assetVer = $assetMod.versions | Where-Object { $_.version_tag -eq $failed.Version } | Select-Object -First 1
                        if ($assetVer -and $assetVer.browser_download_url) {
                            $ghUrl = $assetVer.browser_download_url
                        }
                    }
                }
                # Also try constructing GitHub URL directly if assets lookup failed
                if (-not $ghUrl) {
                    $ghUrl = "https://github.com/GTNewHorizons/$($failed.ModName)/releases/download/$($failed.Version)/$($failed.FileName)"
                }

                Write-Log "[NIGHTLY] GitHub fallback for $($failed.ModName): $ghUrl"
                $httpClient = $null
                try {
                    $httpClient = [System.Net.Http.HttpClient]::new()
                    $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
                    $httpClient.Timeout = [TimeSpan]::FromMinutes(2)
                    $modBytes = $httpClient.GetByteArrayAsync($ghUrl).Result
                    if ($modBytes -and $modBytes.Length -gt 1024) {
                        $destPath = Join-Path $modsDir $failed.FileName
                        [System.IO.File]::WriteAllBytes($destPath, $modBytes)
                        $successCount++
                        $failCount--
                        Write-Success "$($failed.ModName) (GitHub fallback)"
                    } else {
                        Write-Warn "$($failed.ModName): download too small ($($modBytes.Length) bytes)"
                    }
                }
                catch {
                    Write-Warn "$($failed.ModName): $($_.Exception.Message)"
                }
                finally {
                    if ($httpClient) { try { $httpClient.Dispose() } catch {} }
                }
            }
            Write-Host ""
        }

        if ($successCount -gt 0) {
            Write-Success "Downloaded $successCount mod(s) successfully."
        }
        if ($failCount -gt 0) {
            Write-Warn "$failCount mod(s) could not be downloaded from any source."
        }

        # Only fail the entire sync if ALL downloads failed
        if ($failCount -gt 0 -and $successCount -eq 0) {
            return [PSCustomObject]@{
                Success       = $false
                Downloaded    = 0
                Removed       = $actualRemoved
                Unchanged     = $unchangedCount
                InstalledMods = @{}
            }
        }
    }

    # ── Update lwjgl3ify forgePatches + Prism libraries ──────────────────────
    # lwjgl3ify publishes extra assets:
    #   - SERVER: forgePatches jar goes to server root as "lwjgl3ify-forgePatches.jar"
    #   - CLIENT: a multimc.zip is extracted to the instance root (parent of .minecraft)
    #             which contains libraries/ and patches/ folders Prism needs
    if ($diff.Expected.ContainsKey('lwjgl3ify')) {
        $lwjglVersion = $diff.Expected['lwjgl3ify'].Version

        if ($Target -eq 'server') {
            # Server: download forgePatches and place as lwjgl3ify-forgePatches.jar (no version in name)
            $forgePatchesUrl = "https://nexus.gtnewhorizons.com/service/rest/v1/search/assets/download?repository=public&name=lwjgl3ify&maven.extension=jar&maven.classifier=forgePatches&version=$lwjglVersion"
            $forgePatchesDest = Join-Path $instancePath 'lwjgl3ify-forgePatches.jar'

            Write-Info "Updating lwjgl3ify forgePatches for server..."
            $httpClient = $null
            try {
                $httpClient = [System.Net.Http.HttpClient]::new()
                $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
                $httpClient.Timeout = [TimeSpan]::FromMinutes(2)
                $patchBytes = $httpClient.GetByteArrayAsync($forgePatchesUrl).Result
                [System.IO.File]::WriteAllBytes($forgePatchesDest, $patchBytes)

                if ((Get-Item -LiteralPath $forgePatchesDest).Length -gt 1024) {
                    Write-Success "Updated server forgePatches for lwjgl3ify $lwjglVersion"
                }
                else {
                    Write-Warn "forgePatches download appears invalid."
                }
            }
            catch {
                Write-Warn "Could not update server forgePatches: $($_.Exception.Message)"
            }
            finally {
                if ($httpClient) { try { $httpClient.Dispose() } catch {} }
            }
        }
        else {
            # Client: download multimc.zip and extract to instance root (parent of .minecraft)
            # This zip contains mmc-pack.json, libraries/, and patches/ that Prism/MultiMC needs.
            # The Caedis updater (extractZip) deletes existing directories before extracting
            # to ensure a clean slate — no stale files from previous versions remain.
            #
            # Instance root detection: if ClientInstancePath IS the .minecraft folder,
            # the instance root is its parent. If it's the instance root directly
            # (no .minecraft subfolder), patches/libraries live at the same level.
            $instanceRoot = if ((Split-Path -Leaf $instancePath) -eq '.minecraft') {
                Split-Path -Parent $instancePath
            } else {
                $instancePath
            }
            $multimcZipUrl = "https://nexus.gtnewhorizons.com/service/rest/v1/search/assets/download?repository=public&name=lwjgl3ify&maven.extension=zip&maven.classifier=multimc&version=$lwjglVersion"
            $multimcZipPath = Join-Path $script:TempDir "lwjgl3ify-${lwjglVersion}-multimc.zip"

            Write-Info "Updating lwjgl3ify Prism/MultiMC libraries..."
            Write-Log "[NIGHTLY] lwjgl3ify client update: instancePath=$instancePath"
            Write-Log "[NIGHTLY] lwjgl3ify client update: instanceRoot=$instanceRoot (leaf=$(Split-Path -Leaf $instancePath))"
            $httpClient = $null
            try {
                $httpClient = [System.Net.Http.HttpClient]::new()
                $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
                $httpClient.Timeout = [TimeSpan]::FromMinutes(2)
                $zipBytes = $httpClient.GetByteArrayAsync($multimcZipUrl).Result
                [System.IO.File]::WriteAllBytes($multimcZipPath, $zipBytes)

                if ((Get-Item -LiteralPath $multimcZipPath).Length -gt 1024) {
                    # Safety check: if patches/ already exists and has >20 files, we're
                    # pointing at the wrong directory (likely Prism's global meta cache).
                    $existingPatchDir = Join-Path $instanceRoot 'patches'
                    if (Test-Path -LiteralPath $existingPatchDir) {
                        $existingPatchCount = @(Get-ChildItem -LiteralPath $existingPatchDir -File -ErrorAction SilentlyContinue).Count
                        if ($existingPatchCount -gt 20) {
                            Write-Warn "patches/ at '$instanceRoot' contains $existingPatchCount files!"
                            Write-Warn "This looks like Prism's global meta, not the instance root. Skipping extraction."
                            Write-Log "[NIGHTLY] ABORT: patches/ has $existingPatchCount files at $instanceRoot"
                            Remove-Item -LiteralPath $multimcZipPath -Force -ErrorAction SilentlyContinue
                            throw "Instance root appears incorrect"
                        }
                    }

                    # Extract to instance root. Instead of deleting entire directories
                    # (which is dangerous if instanceRoot is wrong), we:
                    # 1. Remove only the specific files the zip will replace
                    # 2. Extract new files with overwrite
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($multimcZipPath)

                    try {
                    # Collect directory names from the zip
                    $zipDirNames = @()
                    foreach ($entry in $zip.Entries) {
                        if ([string]::IsNullOrEmpty($entry.Name) -and $entry.FullName.EndsWith('/')) {
                            $zipDirNames += $entry.FullName.TrimEnd('/')
                        }
                    }

                    # For each directory the zip contains, clear its contents
                    # (removes old-version files like lwjgl3ify-3.0.15-forgePatches.jar)
                    foreach ($dirName in $zipDirNames) {
                        $destDir = Join-Path $instanceRoot $dirName
                        if (Test-Path -LiteralPath $destDir) {
                            Get-ChildItem -LiteralPath $destDir -Force | Remove-Item -Recurse -Force
                            Write-Log "[NIGHTLY] Cleaned contents of: $dirName/"
                        } else {
                            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                        }
                    }

                    # Extract all file entries
                    foreach ($entry in $zip.Entries) {
                        if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                        $destFile = Join-Path $instanceRoot $entry.FullName
                        $destDir = Split-Path -Parent $destFile
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                        }
                        $entryStream = $entry.Open()
                        $fileStream = [System.IO.File]::Create($destFile)
                        $entryStream.CopyTo($fileStream)
                        $fileStream.Dispose()
                        $entryStream.Dispose()
                    }
                    } finally {
                        $zip.Dispose()
                    }

                    # Remove any old lwjgl3ify forgePatches jars that don't match current version
                    $libDir = Join-Path $instanceRoot 'libraries'
                    if (Test-Path -LiteralPath $libDir) {
                        $oldPatches = Get-ChildItem -LiteralPath $libDir -Filter 'lwjgl3ify-*-forgePatches.jar' |
                            Where-Object { $_.Name -ne "lwjgl3ify-${lwjglVersion}-forgePatches.jar" }
                        foreach ($old in $oldPatches) {
                            Remove-Item -LiteralPath $old.FullName -Force
                            Write-Log "[NIGHTLY] Removed old forgePatches: $($old.Name)"
                        }
                    }

                    Write-Success "Updated Prism libraries for lwjgl3ify $lwjglVersion"
                    # Log what was extracted for debugging
                    $patchDir = Join-Path $instanceRoot 'patches'
                    if (Test-Path -LiteralPath $patchDir) {
                        $patchFiles = @(Get-ChildItem -LiteralPath $patchDir -File -ErrorAction SilentlyContinue)
                        Write-Log "[NIGHTLY] patches/ contains $($patchFiles.Count) file(s): $($patchFiles.Name -join ', ')"
                    } else {
                        Write-Log "[NIGHTLY] WARNING: patches/ directory does not exist after extraction!"
                    }
                    $mmcPack = Join-Path $instanceRoot 'mmc-pack.json'
                    if (Test-Path -LiteralPath $mmcPack) {
                        Write-Log "[NIGHTLY] mmc-pack.json exists ($((Get-Item -LiteralPath $mmcPack).Length) bytes)"
                    } else {
                        Write-Log "[NIGHTLY] WARNING: mmc-pack.json does not exist after extraction!"
                    }
                }
                else {
                    Write-Warn "multimc.zip download appears invalid."
                }

                Remove-Item -LiteralPath $multimcZipPath -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Warn "Could not update Prism libraries: $($_.Exception.Message)"
                Write-Warn "You may need to manually update from the lwjgl3ify release."
            }
            finally {
                if ($httpClient) { try { $httpClient.Dispose() } catch {} }
            }
        }
    }

    # Build installed mods tracking map (modName -> fileName)
    $installedMods = @{}
    foreach ($modName in $diff.Expected.Keys) {
        if ($diff.Expected[$modName].FileName) {
            $installedMods[$modName] = $diff.Expected[$modName].FileName
        }
    }

    return [PSCustomObject]@{
        Success       = $true
        Downloaded    = $successCount
        Removed       = $actualRemoved
        Unchanged     = $unchangedCount
        InstalledMods = $installedMods
    }
}


# ── Config Sync Functions ─────────────────────────────────────────────────────

function Invoke-NightlyConfigSync {
    <#
    .SYNOPSIS
        Download and extract configs from the nightly release zip.
    .DESCRIPTION
        Downloads the release zip for the config tag, extracts the config/
        directory from it, and replaces the instance's config/ folder.
        Also extracts scripts/ and resources/ if present in the zip.
        External mods (non-Maven mods) are also extracted from the zip's mods/ folder.
    .PARAMETER ConfigTag
        The config version tag (release tag name).
    .PARAMETER InstancePath
        Path to the game instance.
    .PARAMETER ReleaseInfo
        Release info object with ZipUrl.
    .PARAMETER Manifest
        The parsed manifest object (used to identify Maven mods to skip from the zip).
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigTag,
        [Parameter(Mandatory)][string]$InstancePath,
        [PSCustomObject]$ReleaseInfo,
        [PSCustomObject]$Manifest
    )

    if (-not $ReleaseInfo -or [string]::IsNullOrEmpty($ReleaseInfo.ZipUrl)) {
        Write-Warn "No release zip URL available for config sync."
        return $false
    }

    $zipUrl = $ReleaseInfo.ZipUrl
    $zipName = if ($ReleaseInfo.ZipName) { $ReleaseInfo.ZipName } else { "${ConfigTag}.zip" }
    $zipPath = Join-Path $script:TempDir $zipName
    $extractDir = Join-Path $script:TempDir "config-extract-$ConfigTag"

    # Ensure temp dir exists
    if (-not (Test-Path -LiteralPath $script:TempDir)) {
        New-Item -Path $script:TempDir -ItemType Directory -Force | Out-Null
    }

    # Download the release zip
    Write-Info "Downloading config pack: $zipName"
    $downloaded = Invoke-FileDownload -Url $zipUrl -OutPath $zipPath -Description "config pack ($ConfigTag)"

    if (-not $downloaded) {
        Write-Err "Failed to download config pack."
        return $false
    }

    # Validate the downloaded file is a real zip (not an HTML error page or truncated file)
    try {
        $zipBytes = [byte[]]::new(4)
        $fs = [System.IO.File]::OpenRead($zipPath)
        $fs.Read($zipBytes, 0, 4) | Out-Null
        $fs.Dispose()
        if ($zipBytes[0] -ne 0x50 -or $zipBytes[1] -ne 0x4B) {
            Write-Err "Downloaded config pack is not a valid zip file (may be an error page)."
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    catch {
        Write-Err "Could not validate config pack: $($_.Exception.Message)"
        return $false
    }

    # Save a copy as the config baseline for future config diff scans (avoids re-downloading)
    $baselinePath = Join-Path $InstancePath '.gtnh-config-baseline.zip'
    try {
        Copy-Item -LiteralPath $zipPath -Destination $baselinePath -Force
        Write-Log "[NIGHTLY] Config baseline saved: $baselinePath"
    } catch {
        Write-Log "[NIGHTLY] Could not save config baseline: $($_.Exception.Message)"
        # Non-fatal - config diff will fall back to downloading
    }

    # Extract the zip
    Write-Info "Extracting configs..."
    try {
        if (Test-Path -LiteralPath $extractDir) {
            $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Remove-Item -LiteralPath $extractDir -Recurse -Force
            $ProgressPreference = $oldProgress
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
    }
    catch {
        Write-Err "Failed to extract config pack: $($_.Exception.Message)"
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Find the content root in the extracted zip
    # The zip may have a top-level wrapper folder or content directly at root
    # Strategy: prefer the path that has BOTH config/ AND mods/ with actual content
    $contentRoot = $extractDir
    $directConfig = Join-Path $extractDir 'config'
    $directMods = Join-Path $extractDir 'mods'

    # Check if top-level has config/ with real content AND mods/ with jars
    $topLevelHasMods = (Test-Path -LiteralPath $directMods) -and
        @(Get-ChildItem -LiteralPath $directMods -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count -gt 0

    if ((Test-Path -LiteralPath $directConfig) -and $topLevelHasMods) {
        # Top level has both config and mods — use it directly
        $contentRoot = $extractDir
    } else {
        # Check one level deep for a wrapper folder with the real content
        $subDirs = Get-ChildItem -LiteralPath $extractDir -Directory -ErrorAction SilentlyContinue
        foreach ($sub in $subDirs) {
            $nestedConfig = Join-Path $sub.FullName 'config'
            $nestedMods = Join-Path $sub.FullName 'mods'
            if ((Test-Path -LiteralPath $nestedConfig) -and (Test-Path -LiteralPath $nestedMods)) {
                $contentRoot = $sub.FullName
                break
            }
            # Fall back to just config/ if no mods/ found anywhere
            if ((Test-Path -LiteralPath $nestedConfig) -and $contentRoot -eq $extractDir -and -not (Test-Path -LiteralPath $directConfig)) {
                $contentRoot = $sub.FullName
            }
        }
        # If we still haven't found a better root but top-level has config/, use it
        if ($contentRoot -eq $extractDir -and -not (Test-Path -LiteralPath $directConfig)) {
            # No config found anywhere
            $contentRoot = $extractDir
        }
    }

    $configSource = Join-Path $contentRoot 'config'
    $scriptsSource = Join-Path $contentRoot 'scripts'
    $resourcesSource = Join-Path $contentRoot 'resources'
    $modsSource = Join-Path $contentRoot 'mods'
    Write-Log "[NIGHTLY] Config sync contentRoot: $contentRoot"

    if (-not (Test-Path -LiteralPath $configSource)) {
        Write-Warn "No config/ directory found in release zip. Checking for mods only..."
        # Still try to extract external mods if present (skip Maven mods)
        if (Test-Path -LiteralPath $modsSource) {
            $instanceModsDir = Join-Path $InstancePath 'mods'
            if (-not (Test-Path -LiteralPath $instanceModsDir)) {
                New-Item -Path $instanceModsDir -ItemType Directory -Force | Out-Null
            }
            $externalJars = Get-ChildItem -LiteralPath $modsSource -Filter '*.jar' -File -ErrorAction SilentlyContinue

            # Build Maven mod prefixes to skip
            $mavenPrefixes = @()
            if ($Manifest -and $Manifest.github_mods) {
                foreach ($prop in $Manifest.github_mods.PSObject.Properties) {
                    $mavenPrefixes += "$($prop.Name)-"
                }
            }

            $extCopied = 0
            foreach ($jar in $externalJars) {
                $skip = $false
                foreach ($prefix in $mavenPrefixes) {
                    if ($jar.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $skip = $true; break
                    }
                }
                if ($skip) { continue }
                Copy-Item -LiteralPath $jar.FullName -Destination (Join-Path $instanceModsDir $jar.Name) -Force
                $extCopied++
            }
            if ($extCopied -gt 0) {
                Write-Info "Copied $extCopied external mod(s) from release zip (no configs in this release)."
            }
        }
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        # Return true since we handled what was available — configs just weren't in this zip
        return $true
    }

    # Replace instance config/
    $instanceConfigDir = Join-Path $InstancePath 'config'
    try {
        if (Test-Path -LiteralPath $instanceConfigDir) {
            $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Remove-Item -LiteralPath $instanceConfigDir -Recurse -Force
            $ProgressPreference = $oldProgress
        }
        Copy-Item -LiteralPath $configSource -Destination $instanceConfigDir -Recurse -Force
        Write-Success "Configs updated from $ConfigTag."
    }
    catch {
        Write-Err "Failed to copy configs: $($_.Exception.Message)"
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Copy scripts/ if present
    if (Test-Path -LiteralPath $scriptsSource) {
        $instanceScriptsDir = Join-Path $InstancePath 'scripts'
        try {
            if (Test-Path -LiteralPath $instanceScriptsDir) {
                $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                Remove-Item -LiteralPath $instanceScriptsDir -Recurse -Force
                $ProgressPreference = $oldProgress
            }
            Copy-Item -LiteralPath $scriptsSource -Destination $instanceScriptsDir -Recurse -Force
            Write-Info "Scripts updated."
        }
        catch {
            Write-Warn "Could not update scripts: $($_.Exception.Message)"
        }
    }

    # Copy resources/ if present
    if (Test-Path -LiteralPath $resourcesSource) {
        $instanceResourcesDir = Join-Path $InstancePath 'resources'
        try {
            if (Test-Path -LiteralPath $instanceResourcesDir) {
                $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                Remove-Item -LiteralPath $instanceResourcesDir -Recurse -Force
                $ProgressPreference = $oldProgress
            }
            Copy-Item -LiteralPath $resourcesSource -Destination $instanceResourcesDir -Recurse -Force
            Write-Info "Resources updated."
        }
        catch {
            Write-Warn "Could not update resources: $($_.Exception.Message)"
        }
    }

    # Copy external mods from the zip's mods/ folder.
    # IMPORTANT: Only copy mods that are NOT in the github_mods manifest (those were
    # already downloaded from Maven in Step 8 with the correct nightly versions).
    # The release zip may contain ALL mods, but we only want the external/non-Maven ones.
    Write-Log "[NIGHTLY] Checking for external mods at: $modsSource (exists: $(Test-Path -LiteralPath $modsSource))"
    if (Test-Path -LiteralPath $modsSource) {
        $instanceModsDir = Join-Path $InstancePath 'mods'
        if (-not (Test-Path -LiteralPath $instanceModsDir)) {
            New-Item -Path $instanceModsDir -ItemType Directory -Force | Out-Null
        }
        $externalJars = @(Get-ChildItem -LiteralPath $modsSource -Filter '*.jar' -File -ErrorAction SilentlyContinue)
        Write-Log "[NIGHTLY] Found $($externalJars.Count) jar(s) in release zip mods/"

        # Build a set of Maven mod name prefixes to avoid overwriting them
        # Maven mods are named "<ModName>-<version>.jar" so we check if the jar
        # starts with any known github_mod name followed by a dash
        $mavenModPrefixes = @()
        if ($Manifest -and $Manifest.github_mods) {
            foreach ($prop in $Manifest.github_mods.PSObject.Properties) {
                $mavenModPrefixes += "$($prop.Name)-"
            }
        }

        $copiedCount = 0
        $skippedMavenCount = 0
        foreach ($jar in $externalJars) {
            # Skip jars that match a Maven mod name (already downloaded with correct version)
            $isMavenMod = $false
            foreach ($prefix in $mavenModPrefixes) {
                if ($jar.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isMavenMod = $true
                    break
                }
            }
            if ($isMavenMod) {
                $skippedMavenCount++
                continue
            }

            $destJar = Join-Path $instanceModsDir $jar.Name
            try {
                Copy-Item -LiteralPath $jar.FullName -Destination $destJar -Force
                $copiedCount++
            }
            catch {
                Write-Warn "Could not copy external mod: $($jar.Name)"
            }
        }
        if ($copiedCount -gt 0) {
            Write-Info "Copied $copiedCount external mod(s) from release zip."
        }
        if ($skippedMavenCount -gt 0) {
            Write-Log "[NIGHTLY] Skipped $skippedMavenCount Maven mod(s) from zip (already downloaded with correct nightly versions)"
        }

        # Also check mods/1.7.10/ subfolder for coremods
        $subModsSource = Join-Path $modsSource '1.7.10'
        if (Test-Path -LiteralPath $subModsSource) {
            $instanceSubMods = Join-Path $instanceModsDir '1.7.10'
            if (-not (Test-Path -LiteralPath $instanceSubMods)) {
                New-Item -Path $instanceSubMods -ItemType Directory -Force | Out-Null
            }
            $subJars = Get-ChildItem -LiteralPath $subModsSource -Filter '*.jar' -File -ErrorAction SilentlyContinue
            foreach ($jar in $subJars) {
                try {
                    Copy-Item -LiteralPath $jar.FullName -Destination (Join-Path $instanceSubMods $jar.Name) -Force
                }
                catch {
                    Write-Warn "Could not copy coremod: $($jar.Name)"
                }
            }
        }
    }

    # Clean up temp files
    $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    $ProgressPreference = $oldProgress
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    return $true
}

# ── State Management Functions ────────────────────────────────────────────────

function Read-NightlyState {
    <#
    .SYNOPSIS
        Read the nightly updater state file from the instance.
    .DESCRIPTION
        The state file tracks what version is installed, which mods were placed
        by the updater (for diff/removal), and the last update timestamp.
    .PARAMETER InstancePath
        Path to the game instance.
    .OUTPUTS
        PSCustomObject with state data, or $null if no state file exists.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath
    )

    $statePath = Join-Path $InstancePath $script:NightlyStateFileName
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-Log "[WARN] Nightly state file is empty, treating as no state."
            return $null
        }
        return $content | ConvertFrom-Json
    }
    catch {
        Write-Log "[WARN] Could not read nightly state: $($_.Exception.Message)"
        return $null
    }
}

function Save-NightlyState {
    <#
    .SYNOPSIS
        Write the nightly updater state file to the instance atomically.
    .DESCRIPTION
        Uses write-to-temp-then-rename to prevent corruption on interrupted writes.
    .PARAMETER InstancePath
        Path to the game instance.
    .PARAMETER State
        Hashtable or PSCustomObject with state data to save.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)]$State
    )

    $statePath = Join-Path $InstancePath $script:NightlyStateFileName
    $tempPath = "${statePath}.tmp"
    try {
        $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8 -Force
        Move-Item -LiteralPath $tempPath -Destination $statePath -Force
        Write-Log "[NIGHTLY] State saved: $statePath"
    }
    catch {
        Write-Warn "Could not save update state: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $tempPath) {
            try { Remove-Item -LiteralPath $tempPath -Force } catch {}
        }
    }
}

# ── UI Helper Functions ───────────────────────────────────────────────────────

function Show-NightlyUpdatePlan {
    <#
    .SYNOPSIS
        Display the update plan with color-coded mod diff and ask for confirmation.
    .OUTPUTS
        $true if user confirms, $false if cancelled.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][string]$VersionLabel,
        [string]$CurrentVersion,
        [PSCustomObject]$Manifest,
        [bool]$IsTransition = $false,
        [PSCustomObject]$ModDiff
    )

    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
    Write-Host "Update Plan" -NoNewline -ForegroundColor Cyan
    Write-Host "                                                 │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Target:   " -NoNewline -ForegroundColor Gray
    Write-Host "$($Target.ToUpper())" -ForegroundColor White
    Write-Host "  Channel:  " -NoNewline -ForegroundColor Gray
    Write-Host "$($Channel.ToUpper())" -ForegroundColor Cyan
    Write-Host "  Version:  " -NoNewline -ForegroundColor Gray
    Write-Host "$(if ($CurrentVersion) { $CurrentVersion } else { '?' })" -NoNewline -ForegroundColor Yellow
    Write-Host "  ->  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$VersionLabel" -ForegroundColor Green
    Write-Host "  Instance: " -NoNewline -ForegroundColor Gray
    Write-Host "$InstancePath" -ForegroundColor DarkGray

    if ($Manifest) {
        $githubModCount = @($Manifest.github_mods.PSObject.Properties).Count
        $externalModCount = if ($Manifest.external_mods) { @($Manifest.external_mods.PSObject.Properties).Count } else { 0 }
        $totalModCount = $githubModCount + $externalModCount
        Write-Host "  Mods:     " -NoNewline -ForegroundColor Gray
        Write-Host "$githubModCount github + $externalModCount external = $totalModCount total" -ForegroundColor White
    }

    # Show custom/override mod counts
    $customMods = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
    $overrideMods = @($Target -eq 'server' ? ($Config.OverrideServerMods ?? @()) : ($Config.OverrideClientMods ?? @()))
    if ($customMods.Count -gt 0 -or $overrideMods.Count -gt 0) {
        Write-Host "  Custom:   " -NoNewline -ForegroundColor Gray
        $parts = @()
        if ($customMods.Count -gt 0) { $parts += "$($customMods.Count) custom" }
        if ($overrideMods.Count -gt 0) { $parts += "$($overrideMods.Count) override" }
        Write-Host ($parts -join ', ') -ForegroundColor Cyan
    }

    # ── Show color-coded mod diff (like stable engine's preview) ──────────────
    if ($ModDiff) {
        $downloadCount = $ModDiff.ToDownload.Count
        $removeCount = $ModDiff.ToRemove.Count
        $unchangedCount = $ModDiff.Unchanged.Count
        $skippedCount = $ModDiff.Skipped.Count

        # Calculate truly removed count (excluding mods that are just being updated)
        $updatingBaseNames = @{}
        foreach ($mod in $ModDiff.ToDownload) {
            $baseName = Get-ModBaseName -FileName $mod.FileName
            $updatingBaseNames[$baseName] = $true
        }
        $trulyRemovedCount = 0
        foreach ($filePath in $ModDiff.ToRemove) {
            $fn = Split-Path -Leaf $filePath
            $baseName = Get-ModBaseName -FileName $fn
            if (-not $updatingBaseNames.ContainsKey($baseName)) { $trulyRemovedCount++ }
        }

        Write-Host ""
        Write-Host "  Changes:  " -NoNewline -ForegroundColor Gray
        $changeParts = @()
        if ($downloadCount -gt 0) { $changeParts += "$downloadCount updated" }
        if ($trulyRemovedCount -gt 0) { $changeParts += "$trulyRemovedCount removed" }
        $changeParts += "$unchangedCount unchanged"
        if ($skippedCount -gt 0) { $changeParts += "$skippedCount skipped (override)" }
        Write-Host ($changeParts -join ', ') -ForegroundColor White

        # Show updated mods (version changes)
        if ($downloadCount -gt 0) {
            Write-Host ""
            Write-Host "  Mods to update ($downloadCount):" -ForegroundColor Cyan
            foreach ($mod in ($ModDiff.ToDownload | Sort-Object { $_.ModName })) {
                Write-Host "    + " -NoNewline -ForegroundColor Green
                Write-Host "$($mod.ModName)" -NoNewline -ForegroundColor White
                Write-Host " -> $($mod.Version)" -ForegroundColor DarkGray
            }
        }

        # Show removed mods (exclude mods that are just being updated to a new version)
        if ($removeCount -gt 0) {
            # Build a set of base names being updated so we can exclude them from "removed"
            $updatingBaseNames = @{}
            foreach ($mod in $ModDiff.ToDownload) {
                $baseName = Get-ModBaseName -FileName $mod.FileName
                $updatingBaseNames[$baseName] = $true
            }

            # Filter to only truly removed mods (base name not in the download list)
            $trulyRemoved = @()
            foreach ($filePath in $ModDiff.ToRemove) {
                $fileName = Split-Path -Leaf $filePath
                $baseName = Get-ModBaseName -FileName $fileName
                if (-not $updatingBaseNames.ContainsKey($baseName)) {
                    $trulyRemoved += $filePath
                }
            }

            if ($trulyRemoved.Count -gt 0) {
                Write-Host ""
                Write-Host "  Mods removed from pack ($($trulyRemoved.Count)):" -ForegroundColor Red
                $sortedTrulyRemoved = @($trulyRemoved | Sort-Object)
                for ($i = 0; $i -lt $sortedTrulyRemoved.Count; $i++) {
                    $fileName = Split-Path -Leaf $sortedTrulyRemoved[$i]
                    Write-Host "    $($i + 1). $fileName" -ForegroundColor Red
                }

                # ── Interactive custom mod marking ────────────────────────────
                Write-Host ""
                Write-Host "  Any of these your custom mods? (preserved during updates)" -ForegroundColor Gray
                $markInput = (Read-UserInput "Mark as custom (numbers comma-separated, 'a' for all, Enter to skip)").Trim()
                if ($markInput) {
                    $sortedRemoved = $sortedTrulyRemoved
                    $indicesToMark = @()
                    if ($markInput -ieq 'a') {
                        $indicesToMark = 0..($sortedRemoved.Count - 1)
                    } else {
                        foreach ($part in ($markInput -split ',')) {
                            $num = $part.Trim() -as [int]
                            if ($null -ne $num -and $num -ge 1 -and $num -le $sortedRemoved.Count) {
                                $indicesToMark += ($num - 1)
                            }
                        }
                    }

                    if ($indicesToMark.Count -gt 0) {
                        $customList = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
                        $markedFiles = @()
                        foreach ($idx in $indicesToMark) {
                            $markedFile = Split-Path -Leaf $sortedRemoved[$idx]
                            if ($markedFile -notin $customList) {
                                $customList += $markedFile
                                $markedFiles += $markedFile
                            }
                        }

                        # ── Custom mod conflict warning ───────────────────────
                        # Warn if any marked mods are actually pack mods (they won't receive updates)
                        if ($markedFiles.Count -gt 0 -and $ModDiff) {
                            $manifestBaseNames = @{}
                            foreach ($mod in $ModDiff.ToDownload) {
                                $manifestBaseNames[(Get-ModBaseName -FileName $mod.FileName)] = $mod.ModName
                            }
                            # Also check unchanged mods (they're in the manifest too)
                            if ($ModDiff.Expected) {
                                foreach ($modName in $ModDiff.Expected.Keys) {
                                    if ($ModDiff.Expected[$modName].FileName) {
                                        $manifestBaseNames[(Get-ModBaseName -FileName $ModDiff.Expected[$modName].FileName)] = $modName
                                    }
                                }
                            }

                            $conflicts = @()
                            foreach ($mf in $markedFiles) {
                                $mfBase = Get-ModBaseName -FileName $mf
                                if ($manifestBaseNames.ContainsKey($mfBase)) {
                                    $conflicts += @{ File = $mf; PackMod = $manifestBaseNames[$mfBase] }
                                }
                            }

                            if ($conflicts.Count -gt 0) {
                                Write-Host ""
                                Write-Warn "These mods are part of the pack and won't receive updates if marked as custom:"
                                foreach ($c in $conflicts) {
                                    Write-Info "  - $($c.File) (pack mod: $($c.PackMod))"
                                }
                                Write-Info "Use 'Override Mods' in Settings instead if you want to pin a specific version."
                                Write-Log "[NIGHTLY] Custom mod conflict warning: $($conflicts.Count) pack mod(s) being marked as custom"
                                if (-not (Confirm-Action "Mark them as custom anyway?")) {
                                    $markedFiles = @($markedFiles | Where-Object {
                                        $base = Get-ModBaseName -FileName $_
                                        -not $manifestBaseNames.ContainsKey($base)
                                    })
                                    # Rebuild customList without conflicting entries
                                    $customList = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
                                    foreach ($mf in $markedFiles) {
                                        if ($mf -notin $customList) {
                                            $customList += $mf
                                        }
                                    }
                                }
                            }
                        }

                        if ($markedFiles.Count -gt 0) {
                            if ($Target -eq 'server') {
                                $Config.CustomServerMods = $customList
                            } else {
                                $Config.CustomClientMods = $customList
                            }
                            Save-Config -Config $Config
                            Write-Success "Marked $($markedFiles.Count) mod(s) as custom."
                            # Remove marked mods from trulyRemoved so they don't show as removals
                            $trulyRemoved = @($trulyRemoved | Where-Object {
                                (Split-Path -Leaf $_) -notin $markedFiles
                            })
                        }
                    }
                }
            }
        }

        # Show override mod conflicts (pack has newer version, user keeping theirs)
        if ($ModDiff.OverrideConflicts -and $ModDiff.OverrideConflicts.Count -gt 0) {
            Write-Host ""
            Write-Host "  Override mods (keeping yours, pack has newer):" -ForegroundColor DarkYellow
            foreach ($conflict in $ModDiff.OverrideConflicts) {
                Write-Host "    ~ " -NoNewline -ForegroundColor DarkYellow
                Write-Host "$($conflict.YourFile)" -NoNewline -ForegroundColor White
                Write-Host " (pack: $($conflict.ModName) $($conflict.PackVersion))" -ForegroundColor DarkGray
            }
        }

        if ($downloadCount -eq 0 -and $removeCount -eq 0) {
            Write-Host ""
            Write-Host "  All mods are already up to date." -ForegroundColor Green
            Write-Host "  Configs will still be synced to $VersionLabel." -ForegroundColor Gray
        }
    }
    elseif ($IsTransition) {
        Write-Host ""
        Write-Host "  [!] FIRST-TIME TRANSITION: Clean install required" -ForegroundColor Yellow
        Write-Host "  Stable and $Channel use different mod versions that can't coexist." -ForegroundColor Gray
        Write-Host "  mods/, config/, and scripts/ will be replaced with $Channel versions." -ForegroundColor Gray
        Write-Host "  Your custom mods, user files, and settings are preserved automatically." -ForegroundColor Gray
        Write-Host "  A rollback snapshot is saved in case you want to go back." -ForegroundColor Gray
    }

    Write-Host ""

    # ── Search in update plan ─────────────────────────────────────────────────
    if ($ModDiff) {
        $downloadCount = $ModDiff.ToDownload.Count
        # Recompute trulyRemoved for search (accounts for custom marking above)
        $searchUpdatingBaseNames = @{}
        foreach ($mod in $ModDiff.ToDownload) {
            $baseName = Get-ModBaseName -FileName $mod.FileName
            $searchUpdatingBaseNames[$baseName] = $true
        }
        # Also exclude newly-marked custom mods from search results
        $searchCustomBaseNames = @{}
        $searchCustomList = @($Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @()))
        foreach ($cm in $searchCustomList) {
            $searchCustomBaseNames[(Get-ModBaseName -FileName $cm)] = $true
        }
        $searchTrulyRemoved = @()
        foreach ($filePath in $ModDiff.ToRemove) {
            $fn = Split-Path -Leaf $filePath
            $baseName = Get-ModBaseName -FileName $fn
            if (-not $searchUpdatingBaseNames.ContainsKey($baseName) -and -not $searchCustomBaseNames.ContainsKey($baseName)) {
                $searchTrulyRemoved += $filePath
            }
        }
        $totalChanges = $downloadCount + $searchTrulyRemoved.Count
        if ($totalChanges -gt 20) {
            Write-Host "  Type a mod name to search, or press Enter to continue:" -ForegroundColor Gray
            $searchTerm = (Read-UserInput "Search").Trim()
            if ($searchTerm) {
                Write-Host ""
                Write-Host "  Results for '$searchTerm':" -ForegroundColor White
                foreach ($mod in ($ModDiff.ToDownload | Sort-Object { $_.ModName })) {
                    if ($mod.ModName -ilike "*$searchTerm*") {
                        Write-Host "    + $($mod.ModName) -> $($mod.Version)" -ForegroundColor Green
                    }
                }
                foreach ($filePath in ($searchTrulyRemoved | Sort-Object)) {
                    $fileName = Split-Path -Leaf $filePath
                    if ($fileName -ilike "*$searchTerm*") {
                        Write-Host "    - $fileName" -ForegroundColor Red
                    }
                }
            }
            Write-Host ""
        }
    }

    return (Confirm-Action "Proceed with update?" -DefaultYes)
}

function Invoke-NightlyRollback {
    <#
    .SYNOPSIS
        Offer and perform rollback from snapshot after a failed update.
    #>
    param(
        [string]$RollbackDir,
        [Parameter(Mandatory)][string]$InstancePath,
        [string[]]$FoldersToSnapshot
    )

    if (-not $RollbackDir -or -not (Test-Path -LiteralPath $RollbackDir)) {
        return
    }

    Write-Host ""
    Write-Host "  A rollback snapshot was saved before the update." -ForegroundColor Yellow
    Write-Host ""
    if (Confirm-Action "Restore mods/ and config/ to their pre-update state?") {
        try {
            foreach ($folder in $FoldersToSnapshot) {
                $sourcePath = Join-Path $RollbackDir $folder
                if (Test-Path -LiteralPath $sourcePath) {
                    $destPath = Join-Path $InstancePath $folder

                    # Check if this is a selective snapshot (mods/ only has specific files)
                    # vs a full snapshot (has the complete folder contents).
                    # For selective mods/ snapshots: restore individual files, don't wipe the folder.
                    $isSelectiveMods = ($folder -eq 'mods') -and
                        (Test-Path -LiteralPath (Join-Path $RollbackDir '.selective-snapshot'))

                    if ($isSelectiveMods) {
                        # Selective: restore snapshotted files (old versions) and remove
                        # any new files that were downloaded during the failed update
                        $snapshotFiles = Get-ChildItem -LiteralPath $sourcePath -Filter '*.jar' -File -ErrorAction SilentlyContinue
                        $snapshotFileNames = @{}
                        foreach ($sf in $snapshotFiles) {
                            $snapshotFileNames[$sf.Name] = $true
                            Copy-Item -LiteralPath $sf.FullName -Destination (Join-Path $destPath $sf.Name) -Force
                        }

                        # Remove newly-downloaded mods that weren't in the snapshot
                        # (these are the new versions that replaced the old ones)
                        $preUpdateFileList = Join-Path $RollbackDir '.mods-before-update.txt'
                        if (Test-Path -LiteralPath $preUpdateFileList) {
                            $originalFiles = @(Get-Content -LiteralPath $preUpdateFileList)
                            $currentFiles = Get-ChildItem -LiteralPath $destPath -Filter '*.jar' -File -ErrorAction SilentlyContinue
                            foreach ($cf in $currentFiles) {
                                if ($cf.Name -notin $originalFiles -and -not $snapshotFileNames.ContainsKey($cf.Name)) {
                                    Remove-Item -LiteralPath $cf.FullName -Force -ErrorAction SilentlyContinue
                                }
                            }
                        }

                        Write-Info "  Restored: $folder/ ($($snapshotFiles.Count) file(s))"
                    }
                    else {
                        # Full: wipe and replace entirely (original behavior)
                        if (Test-Path -LiteralPath $destPath) {
                            Remove-Item -LiteralPath $destPath -Recurse -Force
                        }
                        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
                        Write-Info "  Restored: $folder/"
                    }
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

# ── Legacy Compatibility ──────────────────────────────────────────────────────
# Keep Get-LatestNightlyUpdater and Invoke-NightlyUpdaterJar as stubs so that
# any external callers don't break. They now just return success/redirect.

function Get-LatestNightlyUpdater {
    <#
    .SYNOPSIS
        Legacy stub - no longer downloads the Caedis binary.
    .DESCRIPTION
        The native engine no longer needs an external binary. Returns the script's
        own path as a non-null, valid-path sentinel so any callers that check with
        Test-Path or null-check won't break.
    #>
    param([PSCustomObject]$Config)
    # Return a real path that exists so Test-Path checks pass
    return $MyInvocation.ScriptName
}

function Invoke-NightlyUpdaterJar {
    <#
    .SYNOPSIS
        Legacy stub - no longer used.
    .DESCRIPTION
        The native Invoke-NightlyUpdate handles everything directly.
        Kept for backward compatibility only. Always returns $true.
    #>
    param(
        [string]$JavaPath,
        [Parameter(Mandatory=$false)][string]$JarPath,
        [Parameter(Mandatory=$false)][string]$Channel,
        [Parameter(Mandatory=$false)][hashtable]$Targets
    )
    Write-Log "[NIGHTLY] Invoke-NightlyUpdaterJar called (deprecated stub). Returning success."
    return $true
}
