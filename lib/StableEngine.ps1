# ============================================================================
# Group 10: Stable Update Engine - Orchestrate full stable channel updates
# ============================================================================
# Functions:
#   Invoke-StableUpdate      - Full stable update flow with preview-first:
#                               version check -> download -> staging extract ->
#                               color-coded mod comparison -> custom mod marking ->
#                               deletion summary -> confirmation -> apply -> verify
#   Move-StagingToInstance   - Move staging folder content to instance path,
#                               handling nested folder structure
#   Invoke-DeleteFolders     - Delete specified folders based on target type
#
# The stable update follows the official GTNH wiki procedure with a full
# preview-first approach. Every update shows the complete color-coded mod
# comparison before applying. Safety-first: backup warnings, user confirmations,
# file preservation, and post-update verification at every step.
# ============================================================================

function Invoke-StableUpdate {
    <#
    .SYNOPSIS
        Orchestrate the full stable update flow with preview-first for a given target.
    .DESCRIPTION
        Steps:
          1. Query latest version (GitHub API with fallback)
          2. Compare with installed, skip if current (unless force)
          3. Check cache / download zip
          4. Extract to staging folder (reuse if exists)
          5. Find mods in staging (3-level-deep search)
          6. Show full color-coded mod comparison (added/removed/updated/custom)
          7. Interactive custom mod marking (numbered list)
          8. Show deletion summary with folder list
          9. Final confirmation: [A] Apply  [O] Open staging  [C] Cancel
         10. If Apply: preserve files, delete old folders, move staging to instance,
             restore preserved files, restore custom mods, apply config patches,
             verify, record history
         11. Clean up staging and temp folders
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER Release
        Optional pre-fetched release object (from Get-WebsiteReleases, etc.).
        If provided, skips the version fetch step and uses this release directly.
    .PARAMETER ChannelLabel
        Optional channel label for history recording. Defaults to 'stable'.
    .PARAMETER WebsiteReleases
        Optional array of all website releases (from Get-WebsiteReleases) used
        for position-based downgrade detection within the same base version.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [PSCustomObject]$Release,
        [string]$ChannelLabel = 'stable',
        [array]$WebsiteReleases
    )

    $instancePath = $Target -eq 'server' ? $Config.ServerPath : $Config.ClientInstancePath

    # Initialize cleanup variables upfront so finally blocks are safe
    $customModTempDir = $null
    $overrideModTempDir = $null
    $preserveTempDir = $null
    $rollbackDir = $null
    $stagingDir = $null
    $zipPath = $null

    if ([string]::IsNullOrEmpty($instancePath)) {
        Write-Err "No $Target path configured. Run setup wizard first."
        return
    }

    if (-not (Test-Path -LiteralPath $instancePath)) {
        Write-Err "$Target path does not exist: $instancePath"
        return
    }

    Write-Header "$($ChannelLabel.Substring(0,1).ToUpper() + $ChannelLabel.Substring(1)) Update - $($Target.ToUpper())"

    # ── Step 1: Query latest version ──────────────────────────────────────────
    Write-Step "Checking for latest $ChannelLabel release..."

    if ($Release) {
        $release = $Release
    }
    else {
        $release = Get-LatestStableRelease -PackType ($Config.JavaVersion ?? 'java17')
        if (-not $release) {
            Write-Info "Primary API failed, trying fallback..."
            $release = Get-LatestStableReleaseFallback -PackType ($Config.JavaVersion ?? 'java17')
        }
    }

    if (-not $release) {
        Write-Err "Could not determine latest version."
        Write-Info "Check your internet connection and try again."
        return
    }

    $latestVersion = $release.Version
    Write-Info "Latest $ChannelLabel version: $latestVersion"

    # ── Step 2: Compare with installed version ────────────────────────────────
    Write-Step "Comparing versions..."

    $installedVersion = $Target -eq 'server' ? $Config.InstalledServerVersion : $Config.InstalledClientVersion

    # ── Channel switch warning: nightly -> zip-based release ─────────────────
    # Nightlies use JAR-based updates, website releases use zip-based updates.
    # Only warn when the target base version is clearly older than the nightly
    # base version. Same-base or newer-base transitions are fine (the user is
    # moving to a release cut from the same or newer code).
    if ($installedVersion -and $installedVersion -match 'nightly') {
        $nightlyBase = $null
        if ($installedVersion -match '^(\d+\.\d+\.\d+)') {
            $nightlyBase = $Matches[1]
        }

        $targetBase = $latestVersion
        if ($latestVersion -match '^(\d+\.\d+\.\d+)') {
            $targetBase = $Matches[1]
        }

        $isClearDowngrade = $false
        if ($nightlyBase -and $targetBase) {
            try {
                if ([version]$targetBase -lt [version]$nightlyBase) {
                    $isClearDowngrade = $true
                }
            } catch {}
        }

        if ($isClearDowngrade) {
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║  DOWNGRADE WARNING                                          ║" -ForegroundColor Red
            Write-Host "  ║                                                              ║" -ForegroundColor Red
            Write-Host "  ║  You are on a newer dev build. Going back to an older        ║" -ForegroundColor Red
            Write-Host "  ║  release can CORRUPT your world and break saves.             ║" -ForegroundColor Red
            Write-Host "  ║                                                              ║" -ForegroundColor Red
            Write-Host "  ║  Only do this with a backup from BEFORE you switched         ║" -ForegroundColor Red
            Write-Host "  ║  to daily/experimental.                                      ║" -ForegroundColor Red
            Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
            Write-Warn "Current: $installedVersion"
            Write-Warn "Target:  $latestVersion ($ChannelLabel)"
            Write-Host ""
            if (-not (Confirm-Action "I understand the risk. Proceed with downgrade?")) {
                Write-Info "Update cancelled."
                return
            }
        }
    }

    # ── Downgrade check: picking an older zip-based version ───────────────────
    # Covers stable->older-stable, stable->older-beta, beta->older-beta, etc.
    if ($installedVersion -and -not ($installedVersion -match 'nightly')) {
        $installedBase = $installedVersion
        if ($installedVersion -match '^(\d+\.\d+\.\d+)') {
            $installedBase = $Matches[1]
        }
        $targetBase = $latestVersion
        if ($latestVersion -match '^(\d+\.\d+\.\d+)') {
            $targetBase = $Matches[1]
        }

        $isOlderVersion = $false
        try {
            $instVer = [version]$installedBase
            $targVer = [version]$targetBase
            if ($targVer -lt $instVer) {
                $isOlderVersion = $true
            } elseif ($targVer -eq $instVer) {
                # Same base: check if going from stable to beta (e.g., 2.8.0 -> 2.8.0-beta-4)
                $installedIsBeta = $installedVersion -match '[-_](beta|rc)'
                $targetIsBeta = $latestVersion -match '[-_](beta|rc)'
                if (-not $installedIsBeta -and $targetIsBeta) {
                    $isOlderVersion = $true
                }
                elseif ($installedIsBeta -and $targetIsBeta -and $WebsiteReleases) {
                    # Both are beta/RC with the same base: use page position
                    # Lower index = newer on the version history page
                    $installedIdx = -1
                    $targetIdx = -1
                    for ($ri = 0; $ri -lt $WebsiteReleases.Count; $ri++) {
                        if ($WebsiteReleases[$ri].Version -eq $installedVersion) { $installedIdx = $ri }
                        if ($WebsiteReleases[$ri].Version -eq $latestVersion) { $targetIdx = $ri }
                    }
                    # If installed is at a lower index (newer) than target, it's a downgrade
                    if ($installedIdx -ge 0 -and $targetIdx -ge 0 -and $targetIdx -gt $installedIdx) {
                        $isOlderVersion = $true
                    }
                }
            }
        } catch {
            # Version parsing failed - log it but don't block the update
            Write-Log "[WARN] Version comparison failed: $($_.Exception.Message) (installed=$installedVersion, target=$latestVersion)"
        }

        if ($isOlderVersion) {
            Write-Host ""
            Write-Warn "You are selecting an older version than what is installed."
            Write-Warn "Current: $installedVersion"
            Write-Warn "Target:  $latestVersion"
            Write-Host ""
            Write-Info "Going to an older version can break saves if the world was"
            Write-Info "loaded on the newer version. Make sure you have a backup."
            Write-Host ""
            if (-not (Confirm-Action "Continue with older version?")) {
                Write-Info "Update cancelled."
                return
            }
        }
    }

    if ($installedVersion -eq $latestVersion) {
        Write-Success "Already up to date (v$latestVersion)."
        Write-Host ""
        Write-Info "If you're having issues, you can re-install the same version."
        if (-not (Confirm-Action "Re-install v$latestVersion?")) {
            Write-Info "Update cancelled."
            return
        }
        Write-Info "Proceeding with forced re-install."
    } else {
        if ($installedVersion) {
            Write-Info "Installed: $installedVersion -> New: $latestVersion"
        } else {
            Write-Info "No installed version recorded. Installing $latestVersion."
        }
    }

    # ── Pre-update confirmation: show update plan ──────────────────────────────
    $confirmed = Show-UpdatePlan -Config $Config -Target $Target -Version $latestVersion -Channel $ChannelLabel -InstancePath $instancePath
    if (-not $confirmed) {
        Write-Info "Update cancelled."
        return
    }

    # ── Step 3: Check cache / download zip ────────────────────────────────────
    Write-Step "Preparing download..."

    $zipUrl = $Target -eq 'server' ? $release.ServerZipUrl : $release.ClientZipUrl
    $zipName = $Target -eq 'server' ? $release.ServerZipName : $release.ClientZipName

    if (-not $zipUrl) {
        Write-Err "No $Target zip URL found in release $latestVersion."
        return
    }

    # Ensure temp directory exists
    $tempDir = $script:TempDir
    if (-not (Test-Path -LiteralPath $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }

    $zipPath = Join-Path $tempDir $zipName

    # Pre-flight disk space check (GTNH zips are typically 400-500 MB)
    try {
        $freeSpaceGB = $null
        if ($IsWindows) {
            $driveRoot = [System.IO.Path]::GetPathRoot($tempDir)
            $freeSpaceGB = [math]::Round(([System.IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace / 1GB, 2)
        } else {
            $dfOutput = df -B1 $tempDir 2>/dev/null | Select-Object -Last 1
            if ($dfOutput -match '\s(\d+)\s+\d+%\s') {
                $freeSpaceGB = [math]::Round([long]$Matches[1] / 1GB, 2)
            }
        }
        if ($freeSpaceGB -and $freeSpaceGB -lt 1.5) {
            Write-Warn "Low disk space: ${freeSpaceGB} GB free (need ~1.5 GB for download + extraction)"
            if (-not (Confirm-Action "Continue anyway?")) {
                Write-Info "Update cancelled."
                return
            }
        }
    } catch {
        Write-Log "[WARN] Could not check disk space: $($_.Exception.Message)"
    }

    # Download (checks cache automatically)
    $downloaded = Invoke-FileDownload -Url $zipUrl -OutPath $zipPath -Description "$Target pack zip"
    if (-not $downloaded) {
        Write-Err "Download failed. Update cancelled."
        Write-Info "Check your internet connection. If the problem persists, try clearing the cache in Settings."
        return
    }

    # Verify download integrity if hash is available
    # Try to fetch .sha256 sidecar file from the same directory
    $hashUrl = "${zipUrl}.sha256"
    $expectedHash = $null
    try {
        $hashResponse = Invoke-WebRequest -Uri $hashUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($hashResponse -and $hashResponse.Content) {
            # Hash files typically contain "hash  filename" or just the hash
            $hashContent = $hashResponse.Content.Trim()
            if ($hashContent -match '^([a-fA-F0-9]{64})') {
                $expectedHash = $Matches[1]
            }
        }
    }
    catch {
        $errStatus = $null
        if ($_.Exception.Response) { $errStatus = [int]$_.Exception.Response.StatusCode }
        if ($errStatus -eq 404 -or $errStatus -eq 403) {
            # No hash file available - that's fine, skip verification
            Write-Log "[INTEGRITY] No .sha256 sidecar found for $zipName (HTTP $errStatus)"
        } else {
            # Unexpected error - warn the user but don't block the update
            Write-Warn "Could not fetch integrity hash for $zipName - update will proceed unverified."
            Write-Log "[INTEGRITY] Hash fetch error for $zipName`: $($_.Exception.Message)"
        }
    }

    $integrityResult = Test-FileIntegrity -FilePath $zipPath -ExpectedHash $expectedHash
    if ($integrityResult -eq $false) {
        Write-Err "Downloaded file failed integrity check. It may be corrupted."
        Write-Info "Try clearing the cache (Settings > Backups and cache) and downloading again."
        # Remove the bad file from cache and temp
        $cachedBad = Join-Path $script:CacheDir $zipName
        if (Test-Path -LiteralPath $cachedBad) {
            try { Remove-Item -LiteralPath $cachedBad -Force } catch {}
        }
        if (Test-Path -LiteralPath $zipPath) {
            try { Remove-Item -LiteralPath $zipPath -Force } catch {}
        }
        return
    }

    # ── Step 4: Extract to staging folder ─────────────────────────────────────
    Write-Step "Extracting to staging folder..."

    $stagingDir = Join-Path $script:ScriptDir "staging-${Target}-${latestVersion}"

    if (Test-Path -LiteralPath $stagingDir) {
        Write-Info "Staging folder already exists: staging-${Target}-${latestVersion}"
        Write-Info "Using existing extraction."
    } else {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stagingDir, $true)
            Write-Success "Extracted to: staging-${Target}-${latestVersion}/"
        }
        catch {
            Write-Err "Extraction failed: $($_.Exception.Message)"
            Write-Info "If this keeps happening, try clearing the download cache in Settings."
            Write-Log "[ERROR] Staging extraction failed: $($_.Exception.ToString())"
            if (Test-Path -LiteralPath $stagingDir) {
                Remove-Item -LiteralPath $stagingDir -Recurse -Force
            }
            # Remove potentially corrupted file from cache and temp
            $cachedCorrupt = Join-Path $script:CacheDir $zipName
            if (Test-Path -LiteralPath $cachedCorrupt) {
                try { Remove-Item -LiteralPath $cachedCorrupt -Force; Write-Info "Removed cached file (may be corrupted): $zipName" } catch {}
            }
            if (Test-Path -LiteralPath $zipPath) {
                try { Remove-Item -LiteralPath $zipPath -Force } catch {}
            }
            return
        }
    }

    # ── Config diff detection (if previous pack zip is cached) ────────────────
    if ($installedVersion) {
        $prevRelease = $script:CachedWebsiteReleases | Where-Object { $_.Version -eq $installedVersion } | Select-Object -First 1
        $prevZipName = $null
        if ($prevRelease) {
            $prevZipName = $Target -eq 'server' ? $prevRelease.ServerZipName : $prevRelease.ClientZipName
        }
        $prevZipCached = $prevZipName ? (Get-CachedFile -FileName $prevZipName) : $null

        if ($prevZipCached) {
            Invoke-ConfigDiffDetection `
                -BaselineZipPath $prevZipCached `
                -InstancePath    $instancePath `
                -StagingZipPath  $zipPath `
                -Config          $Config `
                -Target          $Target | Out-Null
        } else {
            Write-Info "Previous pack zip not cached — config change detection skipped."
        }
    }

    # ── Step 5: Find mods in staging ──────────────────────────────────────────
    Write-Step "Analyzing mod changes..."

    $stagingModsPath = $null
    $searchRoot = $stagingDir

    # Try direct mods/ first
    $candidate = Join-Path $searchRoot 'mods'
    if (Test-Path -LiteralPath $candidate) {
        $stagingModsPath = $candidate
    } else {
        # Search up to 3 levels deep for a mods/ folder with JARs
        $found = Get-ChildItem -LiteralPath $searchRoot -Directory -Recurse -Depth 3 -Filter 'mods' -ErrorAction SilentlyContinue |
            Where-Object { (Get-ChildItem -LiteralPath $_.FullName -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count -gt 0 } |
            Select-Object -First 1
        if ($found) {
            $stagingModsPath = $found.FullName
        }
    }

    if ($stagingModsPath) {
        Write-Info "Found new pack mods at: $($stagingModsPath.Replace($stagingDir, 'staging/'))"
    }

    $newJars = @()
    if ($stagingModsPath -and (Test-Path -LiteralPath $stagingModsPath)) {
        $newJars = @(Get-ChildItem -LiteralPath $stagingModsPath -Filter '*.jar' -File)
    }

    $currentJars = @()
    $currentModsPath = Join-Path $instancePath 'mods'
    if (Test-Path -LiteralPath $currentModsPath) {
        $currentJars = @(Get-ChildItem -LiteralPath $currentModsPath -Filter '*.jar' -File)
    }

    # ── Step 6: Show full color-coded mod comparison ──────────────────────────
    Write-Host ""
    Write-Header "Mod Comparison"

    Write-Info "Current: $($currentJars.Count) mods | New pack: $($newJars.Count) mods"

    # Build base name maps for comparison
    $currentBaseMap = @{}
    foreach ($jar in $currentJars) {
        $base = Get-ModBaseName -FileName $jar.Name
        $currentBaseMap[$base] = $jar.Name
    }

    $newBaseMap = @{}
    foreach ($jar in $newJars) {
        $base = Get-ModBaseName -FileName $jar.Name
        $newBaseMap[$base] = $jar.Name
    }

    # Get custom mods list from config
    $savedCustomMods = $Target -eq 'server' ? ($Config.CustomServerMods ?? @()) : ($Config.CustomClientMods ?? @())
    $customBaseNames = @{}
    foreach ($mod in $savedCustomMods) {
        $customBaseNames[(Get-ModBaseName -FileName $mod)] = $true
    }

    # Get override mods list from config
    $savedOverrideMods = $Target -eq 'server' ? ($Config.OverrideServerMods ?? @()) : ($Config.OverrideClientMods ?? @())
    $overrideBaseNames = @{}
    foreach ($mod in $savedOverrideMods) {
        $overrideBaseNames[(Get-ModBaseName -FileName $mod)] = $mod
    }

    # Categorize mods
    $added = @()
    $removed = @()
    $updated = @()
    $custom = @()
    $overrideConflicts = @()  # override mods where pack also has a version

    foreach ($base in $newBaseMap.Keys) {
        if (-not $currentBaseMap.ContainsKey($base)) {
            $added += $newBaseMap[$base]
        }
        elseif ($currentBaseMap[$base] -ne $newBaseMap[$base]) {
            if ($overrideBaseNames.ContainsKey($base)) {
                # Override mod — pack has a different version, needs user decision
                $overrideConflicts += [PSCustomObject]@{
                    YourVersion = $overrideBaseNames[$base]
                    PackVersion = $newBaseMap[$base]
                    Base        = $base
                }
            } else {
                $updated += [PSCustomObject]@{ Old = $currentBaseMap[$base]; New = $newBaseMap[$base] }
            }
        }
    }

    foreach ($base in $currentBaseMap.Keys) {
        if (-not $newBaseMap.ContainsKey($base)) {
            if ($customBaseNames.ContainsKey($base)) {
                $custom += $currentBaseMap[$base]
            } else {
                $removed += $currentBaseMap[$base]
            }
        }
    }

    # Helper: display a list with pagination for large sets
    $pageSize = 30
    $showList = {
        param([array]$Items, [string]$Prefix, [string]$Color)
        if ($Items.Count -le $pageSize) {
            foreach ($item in $Items) {
                Write-Host "    ${Prefix} $item" -ForegroundColor $Color
            }
        } else {
            for ($p = 0; $p -lt $Items.Count; $p += $pageSize) {
                $end = [math]::Min($p + $pageSize, $Items.Count)
                for ($j = $p; $j -lt $end; $j++) {
                    Write-Host "    ${Prefix} $($Items[$j])" -ForegroundColor $Color
                }
                if ($end -lt $Items.Count) {
                    Write-Host "    ... ($end of $($Items.Count) shown, press Enter for more)" -ForegroundColor DarkGray
                    Read-Host | Out-Null
                }
            }
        }
    }

    # Display results
    if ($added.Count -gt 0) {
        Write-Host ""
        Write-Host "  New mods added to pack ($($added.Count)):" -ForegroundColor Green
        & $showList ($added | Sort-Object) '+' 'Green'
    }

    if ($removed.Count -gt 0) {
        Write-Host ""
        Write-Host "  Mods not in new pack ($($removed.Count)):" -ForegroundColor Red
        $sortedRemoved = @($removed | Sort-Object)
        $tagWidth = "[$($sortedRemoved.Count)]".Length
        for ($i = 0; $i -lt $sortedRemoved.Count; $i++) {
            $tag = "[$($i + 1)]".PadLeft($tagWidth)
            Write-Host "    $tag $($sortedRemoved[$i])" -ForegroundColor Red
        }

        # ── Step 7: Interactive custom mod marking ────────────────────────────
        Write-Host ""
        Write-Host "  $('-' * 56)" -ForegroundColor DarkGray
        Write-Host "  Any of these your custom mods?" -ForegroundColor White
        Write-Host "  Custom mods are preserved during updates." -ForegroundColor Gray
        Write-Host "  $('-' * 56)" -ForegroundColor DarkGray
        $markInput = (Read-UserInput "Mark custom mods (numbers separated by commas, 'a' for all, or Enter to skip)").Trim()

        if ($markInput) {
            $newCustom = @()
            if ($markInput -eq 'a' -or $markInput -eq 'A') {
                $newCustom = $sortedRemoved
            } else {
                foreach ($part in ($markInput -split ',')) {
                    $idx = 0
                    if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $sortedRemoved.Count) {
                        $newCustom += $sortedRemoved[$idx - 1]
                    }
                }
            }

            if ($newCustom.Count -gt 0) {
                # Add to config's custom mods list (avoid duplicates by base name)
                $existingBaseNames = @{}
                foreach ($mod in $savedCustomMods) {
                    $existingBaseNames[(Get-ModBaseName -FileName $mod)] = $true
                }

                $addedCount = 0
                foreach ($mod in $newCustom) {
                    $base = Get-ModBaseName -FileName $mod
                    if (-not $existingBaseNames.ContainsKey($base)) {
                        $savedCustomMods += $mod
                        $existingBaseNames[$base] = $true
                        $addedCount++
                        Write-Host "    * Marked as custom: $mod" -ForegroundColor Cyan
                    } else {
                        Write-Info "    Already in custom list: $mod"
                    }
                }

                if ($addedCount -gt 0) {
                    if ($Target -eq 'server') {
                        $Config.CustomServerMods = $savedCustomMods
                    } else {
                        $Config.CustomClientMods = $savedCustomMods
                    }
                    Save-Config -Config $Config
                    Write-Success "$addedCount mod(s) added to your $Target custom mods list."

                    # Move newly marked mods into the custom list for display
                    $custom += $newCustom
                    $removed = @($sortedRemoved | Where-Object { $_ -notin $newCustom })
                }
            }
        }
    }

    if ($updated.Count -gt 0) {
        Write-Host ""
        Write-Host "  Mods updated (version change) ($($updated.Count)):" -ForegroundColor Cyan
        $sortedUpdated = @($updated | Sort-Object { $_.New })
        if ($sortedUpdated.Count -le $pageSize) {
            foreach ($entry in $sortedUpdated) {
                Write-Host "    ~ " -NoNewline -ForegroundColor DarkYellow
                Write-Host "$($entry.Old)" -NoNewline -ForegroundColor DarkGray
                Write-Host " -> " -NoNewline -ForegroundColor Gray
                Write-Host "$($entry.New)" -ForegroundColor White
            }
        } else {
            for ($p = 0; $p -lt $sortedUpdated.Count; $p += $pageSize) {
                $end = [math]::Min($p + $pageSize, $sortedUpdated.Count)
                for ($j = $p; $j -lt $end; $j++) {
                    Write-Host "    ~ " -NoNewline -ForegroundColor DarkYellow
                    Write-Host "$($sortedUpdated[$j].Old)" -NoNewline -ForegroundColor DarkGray
                    Write-Host " -> " -NoNewline -ForegroundColor Gray
                    Write-Host "$($sortedUpdated[$j].New)" -ForegroundColor White
                }
                if ($end -lt $sortedUpdated.Count) {
                    Write-Host "    ... ($end of $($sortedUpdated.Count) shown, press Enter for more)" -ForegroundColor DarkGray
                    Read-Host | Out-Null
                }
            }
        }
    }

    if ($custom.Count -gt 0) {
        Write-Host ""
        Write-Host "  Your custom mods (will be preserved) ($($custom.Count)):" -ForegroundColor Cyan
        & $showList ($custom | Sort-Object) '*' 'Cyan'
    }

    # ── Override mod conflicts ────────────────────────────────────────────────
    $keepOverrides = $false
    if ($overrideConflicts.Count -gt 0) {
        Write-Host ""
        Write-Host "  Override mods — pack has a different version ($($overrideConflicts.Count)):" -ForegroundColor Magenta
        foreach ($oc in $overrideConflicts) {
            Write-Host "    ~ Your version: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($oc.YourVersion)" -NoNewline -ForegroundColor Magenta
            Write-Host "  |  Pack version: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($oc.PackVersion)" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Keep your versions? " -NoNewline -ForegroundColor White
        Write-Host "[Y] Keep mine  [N] Use pack versions" -ForegroundColor DarkGray
        $overrideChoice = (Read-Host).Trim()
        $keepOverrides = $overrideChoice -notmatch '^[Nn]$'
        if ($keepOverrides) {
            Write-Info "  Your override versions will be restored after update."
        } else {
            Write-Info "  Pack versions will be used."
        }
    }

    if ($added.Count -eq 0 -and $removed.Count -eq 0 -and $updated.Count -eq 0 -and $custom.Count -eq 0 -and $overrideConflicts.Count -eq 0) {
        Write-Host ""
        Write-Info "No mod differences detected."
    }

    Write-Host ""
    $diff = $newJars.Count - $currentJars.Count
    $diffLabel = $diff -gt 0 ? "+$diff" : "$diff"
    Write-Info "Summary: $($added.Count) added, $($removed.Count) removed, $($updated.Count) updated, $($custom.Count) custom$(if ($overrideConflicts.Count -gt 0) { ", $($overrideConflicts.Count) override" })  (net: $diffLabel)"

    # Offer search if there are many mods
    $totalChanges = $added.Count + $removed.Count + $updated.Count + $custom.Count
    if ($totalChanges -gt 20) {
        Write-Host ""
        Write-Host "  Type a mod name to search, or press Enter to continue: " -NoNewline -ForegroundColor DarkGray
        $searchTerm = (Read-Host).Trim()
        if ($searchTerm) {
            Write-Host ""
            Write-Host "  Search results for '$searchTerm':" -ForegroundColor White
            $anyFound = $false
            foreach ($mod in ($added | Sort-Object)) {
                if ($mod -ilike "*$searchTerm*") {
                    Write-Host "    + $mod" -ForegroundColor Green
                    $anyFound = $true
                }
            }
            foreach ($mod in ($removed | Sort-Object)) {
                if ($mod -ilike "*$searchTerm*") {
                    Write-Host "    - $mod" -ForegroundColor Red
                    $anyFound = $true
                }
            }
            foreach ($entry in $updated) {
                if ($entry.Old -ilike "*$searchTerm*" -or $entry.New -ilike "*$searchTerm*") {
                    Write-Host "    ~ " -NoNewline -ForegroundColor DarkYellow
                    Write-Host "$($entry.Old) -> $($entry.New)" -ForegroundColor White
                    $anyFound = $true
                }
            }
            foreach ($mod in ($custom | Sort-Object)) {
                if ($mod -ilike "*$searchTerm*") {
                    Write-Host "    * $mod" -ForegroundColor Cyan
                    $anyFound = $true
                }
            }
            if (-not $anyFound) {
                Write-Info "  No mods matching '$searchTerm'."
            }
            Write-Host ""
        }
    }

    # ── Stale custom mod check ────────────────────────────────────────────────
    # Re-check here so the user can fix issues before committing to the update.
    if ($savedCustomMods.Count -gt 0 -and (Test-Path -LiteralPath $currentModsPath)) {
        $localBaseNames = @{}
        foreach ($jar in (Get-ChildItem -LiteralPath $currentModsPath -Filter '*.jar' -File)) {
            $localBaseNames[(Get-ModBaseName -FileName $jar.Name)] = $jar.Name
        }
        $staleEntries = @()
        foreach ($tracked in $savedCustomMods) {
            $base = Get-ModBaseName -FileName $tracked
            if (-not $localBaseNames.ContainsKey($base)) {
                $staleEntries += $tracked
            } elseif ($tracked -ne $localBaseNames[$base]) {
                $staleEntries += $tracked  # filename changed (version bump)
            }
        }
        if ($staleEntries.Count -gt 0) {
            Write-Host ""
            Write-Host "  $('-' * 56)" -ForegroundColor DarkGray
            Write-Warn "$($staleEntries.Count) custom mod(s) have stale entries (missing or renamed):"
            foreach ($s in $staleEntries) { Write-Host "    - $s" -ForegroundColor DarkYellow }
            Write-Host "  These will NOT be preserved unless fixed." -ForegroundColor DarkYellow
            Write-Host "  $('-' * 56)" -ForegroundColor DarkGray
            Write-Host ""
            Write-MenuOption "F" "Auto-fix now (update filenames / remove missing)"
            Write-MenuOption "K" "Continue anyway"
            $staleChoice = Read-MenuChoice "Choose"
            if ($staleChoice -eq 'F' -or $staleChoice -eq 'f') {
                $newList = @($savedCustomMods)
                foreach ($s in $staleEntries) {
                    $base = Get-ModBaseName -FileName $s
                    if ($localBaseNames.ContainsKey($base) -and $localBaseNames[$base] -ne $s) {
                        # Rename to current filename
                        $newList = @($newList | ForEach-Object { if ($_ -eq $s) { $localBaseNames[$base] } else { $_ } })
                        Write-Info "  Updated: $s -> $($localBaseNames[$base])"
                    } else {
                        # Remove missing entry
                        $newList = @($newList | Where-Object { $_ -ne $s })
                        Write-Info "  Removed: $s"
                    }
                }
                $savedCustomMods = $newList
                if ($Target -eq 'server') { $Config.CustomServerMods = $newList } else { $Config.CustomClientMods = $newList }
                Save-Config -Config $Config
                Write-Success "Custom mods list updated."
            }
        }
    }

    # ── Step 8: Show deletion summary with folder list ────────────────────────
    $foldersToDelete = $Target -eq 'server' ? $script:ServerFoldersToDelete : $script:ClientFoldersToDelete
    $javaVersion = $Config.JavaVersion ?? 'java17'

    Write-Host ""
    Write-Warn "Folders to delete:"
    foreach ($folder in $foldersToDelete) {
        $folderPath = Join-Path $instancePath $folder
        if (Test-Path -LiteralPath $folderPath) {
            Write-Info "  - $folder/"
        }
    }

    if ($javaVersion -eq 'java17') {
        if ($Target -eq 'server') {
            foreach ($file in $script:ServerJava17FilesToDelete) {
                Write-Info "  - $file"
            }
        } else {
            foreach ($item in $script:ClientJava17InstanceRootItems) {
                Write-Info "  - $item (instance root)"
            }
        }
    }

    # ── Step 9: Final confirmation loop ───────────────────────────────────────
    Write-Host ""
    Write-Info "Staging folder: $stagingDir"
    Write-Host ""
    Write-MenuOption -Key 'A' -Description 'Apply update'
    Write-MenuOption -Key 'O' -Description 'Open staging in file manager'
    Write-MenuOption -Key 'C' -Description 'Cancel'

    $applyUpdate = $false
    while ($true) {
        $choice = Read-MenuChoice 'Choose an option'

        switch ($choice.ToUpper()) {
            'A' {
                $applyUpdate = $true
                break
            }
            'O' {
                Open-FolderInFileManager -Path $stagingDir
                Write-Info "Opened in file manager. Choose again when ready."
            }
            'C' {
                Write-Info "Update cancelled. Staging folder preserved at: $stagingDir"
                # Clean up the temp zip (already cached; no need to keep the temp copy)
                if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
                    try { Remove-Item -LiteralPath $zipPath -Force } catch {}
                }
                return
            }
            default {
                Write-Warn "Invalid option. Use [A], [O], or [C]."
            }
        }
        if ($applyUpdate) { break }
    }

    # ── APPLY UPDATE ──────────────────────────────────────────────────────────
    Write-Header "Applying Update"

    $totalSteps = 9
    $customModsToRestore = $savedCustomMods

    # ── Backup custom mods to temp ────────────────────────────────────────────
    Write-Step "Step 1/$totalSteps`: Backing up custom mods..."

    $customModTempDir = Join-Path $tempDir 'custom-mods'
    if (Test-Path -LiteralPath $customModTempDir) {
        Remove-Item -LiteralPath $customModTempDir -Recurse -Force
    }

    # Also back up override mods to temp (they'll be deleted with mods/ folder)
    $overrideModTempDir = Join-Path $tempDir 'override-mods'
    if (Test-Path -LiteralPath $overrideModTempDir) {
        Remove-Item -LiteralPath $overrideModTempDir -Recurse -Force
    }
    if ($keepOverrides -and $overrideConflicts.Count -gt 0 -and (Test-Path -LiteralPath $currentModsPath)) {
        New-Item -Path $overrideModTempDir -ItemType Directory -Force | Out-Null
        foreach ($oc in $overrideConflicts) {
            $src = Join-Path $currentModsPath $oc.YourVersion
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $overrideModTempDir $oc.YourVersion) -Force
            }
        }
    }

    if ($customModsToRestore.Count -gt 0 -and (Test-Path -LiteralPath $currentModsPath)) {
        New-Item -Path $customModTempDir -ItemType Directory -Force | Out-Null

        # Build list of current mods not in the new pack (candidates for replacement)
        $currentJarFiles = @(Get-ChildItem -LiteralPath $currentModsPath -Filter '*.jar' -File)
        $configChanged = $false

        foreach ($modFile in @($customModsToRestore)) {
            $modPath = Join-Path $currentModsPath $modFile
            if (Test-Path -LiteralPath $modPath) {
                Copy-Item -LiteralPath $modPath -Destination (Join-Path $customModTempDir $modFile) -Force
            } else {
                # Stale entry - file not found in mods folder
                Write-Host ""
                Write-Warn "Custom mod not found: $modFile"
                Write-Host ""
                Write-MenuOption "1" "Remove from custom mods list"
                Write-MenuOption "2" "Pick replacement from current mods"
                Write-MenuOption "S" "Skip (keep in list for now)"

                $staleChoice = Read-MenuChoice "Choose"

                switch ($staleChoice) {
                    '1' {
                        $customModsToRestore = @($customModsToRestore | Where-Object { $_ -ne $modFile })
                        $configChanged = $true
                        Write-Info "  Removed '$modFile' from custom mods list."
                    }
                    '2' {
                        # Show current mods that aren't in the new pack as candidates
                        # Candidates: mods not in the new pack (likely custom). Fall back to all if needed.
                        $candidates = @()
                        if ($stagingModsPath) {
                            $newBaseNamesForPick = @{}
                            foreach ($jar in (Get-ChildItem -LiteralPath $stagingModsPath -Filter '*.jar' -File)) {
                                $newBaseNamesForPick[(Get-ModBaseName -FileName $jar.Name)] = $true
                            }
                            $candidates = @($currentJarFiles | Where-Object {
                                -not $newBaseNamesForPick.ContainsKey((Get-ModBaseName -FileName $_.Name))
                            } | ForEach-Object { $_.Name } | Sort-Object)
                            if ($candidates.Count -eq 0) {
                                Write-Info "  (All current mods appear to be pack mods - showing full list)"
                                $candidates = @($currentJarFiles | ForEach-Object { $_.Name } | Sort-Object)
                            }
                        } else {
                            Write-Info "  (Staging unavailable - showing all current mods)"
                            $candidates = @($currentJarFiles | ForEach-Object { $_.Name } | Sort-Object)
                        }
                        if ($candidates.Count -eq 0) {
                            $candidates = @($currentJarFiles | ForEach-Object { $_.Name } | Sort-Object)
                        }

                        Write-Host ""
                        Write-Info "Pick the replacement mod:"
                        $tagWidth = "[$($candidates.Count)]".Length
                        for ($i = 0; $i -lt $candidates.Count; $i++) {
                            $tag = "[$($i + 1)]".PadLeft($tagWidth)
                            Write-Host "    $tag $($candidates[$i])" -ForegroundColor Cyan
                        }
                        Write-Host ""
                        $pickChoice = Read-MenuChoice "Enter number"
                        $pickIdx = 0
                        if ([int]::TryParse($pickChoice, [ref]$pickIdx) -and $pickIdx -ge 1 -and $pickIdx -le $candidates.Count) {
                            $replacement = $candidates[$pickIdx - 1]
                            $customModsToRestore = @($customModsToRestore | Where-Object { $_ -ne $modFile })
                            $customModsToRestore += $replacement
                            $configChanged = $true

                            $replacementPath = Join-Path $currentModsPath $replacement
                            if (Test-Path -LiteralPath $replacementPath) {
                                Copy-Item -LiteralPath $replacementPath -Destination (Join-Path $customModTempDir $replacement) -Force
                                Write-Success "  Replaced '$modFile' with '$replacement'"
                            }
                        } else {
                            Write-Warn "  Invalid selection. Skipping."
                        }
                    }
                    default {
                        Write-Info "  Keeping '$modFile' in list (will skip backup)."
                    }
                }
            }
        }

        # Save config if custom mods list changed
        if ($configChanged) {
            if ($Target -eq 'server') {
                $Config.CustomServerMods = $customModsToRestore
            } else {
                $Config.CustomClientMods = $customModsToRestore
            }
            Save-Config -Config $Config
            Write-Info "  Custom mods list updated."
        }
    } else {
        Write-Info "No custom mods to back up."
    }

    # ── Preserve files ────────────────────────────────────────────────────────
    Write-Step "Step 2/$totalSteps`: Preserving critical files..."

    $preserveTempDir = Join-Path $tempDir 'preserved'
    if (Test-Path -LiteralPath $preserveTempDir) {
        Remove-Item -LiteralPath $preserveTempDir -Recurse -Force
    }

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
    # ── Script-level backup (if enabled) ──────────────────────────────────────
    $backupOk = Invoke-FullInstanceBackup -Config $Config -InstancePath $instancePath -Target $Target -Silent
    if ($backupOk -eq $false) {
        Write-Err "Backup failed. Update cancelled for safety."
        Write-Info "Fix the backup issue or disable backups in Settings, then try again."
        # Clean up temp dirs before aborting
        Remove-TempDir $customModTempDir
        Remove-TempDir $preserveTempDir
        return
    }

    # ── POINT OF NO RETURN ────────────────────────────────────────────────────
    # Always save a lightweight rollback snapshot for quick recovery on failure.
    # This is fast and small (just the folders being deleted), so always worth doing.
    $rollbackDir = Save-RollbackSnapshot -InstancePath $instancePath -Target $Target
    if (-not $rollbackDir) {
        Write-Warn "Could not save rollback snapshot. If the update fails, you will need to restore manually."
        if (-not (Confirm-Action "Continue without rollback safety net?")) {
            Write-Info "Update cancelled."
            # Clean up temp dirs
            Remove-TempDir $customModTempDir
            Remove-TempDir $preserveTempDir
            return
        }
    }

    $postDeletion = $false
    $updateSucceeded = $false

    try {
        # ── Delete folders ────────────────────────────────────────────────────
        # Note: Save-RollbackSnapshot already MOVED these folders out (for speed).
        # Invoke-DeleteFolders handles any stragglers (Java17 files, edge cases).
        Write-Step "Step 3/$totalSteps`: Cleaning old pack files..."
        $postDeletion = $true

        Invoke-DeleteFolders -InstancePath $instancePath -Target $Target -JavaVersion $javaVersion

        # ── Move staging to instance ──────────────────────────────────────────
        Write-Step "Step 4/$totalSteps`: Installing new pack from staging..."

        Move-StagingToInstance -StagingDir $stagingDir -DestinationPath $instancePath -Target $Target -JavaVersion $javaVersion

        # ── Restore preserved files ───────────────────────────────────────────
        Write-Step "Step 5/$totalSteps`: Restoring preserved files..."

        Invoke-RestoreFiles -InstancePath $instancePath -Target $Target -TempDir $preserveTempDir

        # ── Restore custom mods ───────────────────────────────────────────────
        Write-Step "Step 6/$totalSteps`: Restoring custom mods..."

        if ($customModsToRestore.Count -gt 0 -and (Test-Path -LiteralPath $customModTempDir)) {
            $modsDir = Join-Path $instancePath 'mods'
            if (-not (Test-Path -LiteralPath $modsDir)) {
                New-Item -Path $modsDir -ItemType Directory -Force | Out-Null
            }
            $restoredCount = 0
            foreach ($modFile in $customModsToRestore) {
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

        # ── Restore override mods (if user chose to keep their versions) ──────
        if ($keepOverrides -and $overrideConflicts.Count -gt 0 -and (Test-Path -LiteralPath $overrideModTempDir)) {
            $modsDir = Join-Path $instancePath 'mods'
            $overrideRestoredCount = 0
            foreach ($oc in $overrideConflicts) {
                $yourSource = Join-Path $overrideModTempDir $oc.YourVersion
                if (Test-Path -LiteralPath $yourSource) {
                    # Remove the pack's version first
                    $packDest = Join-Path $modsDir $oc.PackVersion
                    if (Test-Path -LiteralPath $packDest) {
                        Remove-Item -LiteralPath $packDest -Force
                    }
                    Copy-Item -LiteralPath $yourSource -Destination (Join-Path $modsDir $oc.YourVersion) -Force
                    $overrideRestoredCount++
                }
            }
            if ($overrideRestoredCount -gt 0) {
                Write-Success "Restored $overrideRestoredCount override mod(s)."
            }
        }

        # ── Apply config patches ──────────────────────────────────────────────
        Write-Step "Step 7/$totalSteps`: Applying config patches..."

        Invoke-ConfigPatches -Config $Config -InstancePath $instancePath -Target $Target

        # ── Run verification ──────────────────────────────────────────────────
        Write-Step "Step 8/$totalSteps`: Running verification..."

        Invoke-Verification -InstancePath $instancePath -Target $Target

        # ── Record history, update installed version ──────────────────────────
        Write-Step "Step 9/$totalSteps`: Recording update..."

        $historyDetails = "+$($added.Count) -$($removed.Count) ~$($updated.Count)"
        Add-UpdateHistoryEntry -Config $Config -Version $latestVersion -Channel $ChannelLabel -Target $Target -Details $historyDetails

        if ($Target -eq 'server') {
            $Config.InstalledServerVersion = $latestVersion
        } else {
            $Config.InstalledClientVersion = $latestVersion
        }
        Save-Config -Config $Config

        $updateSucceeded = $true

        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║  Update complete!                                           ║" -ForegroundColor Green
        Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        Write-Host "  $Target updated to " -NoNewline -ForegroundColor Gray
        Write-Host "v$latestVersion" -ForegroundColor Green
        Write-Host "  Channel: $ChannelLabel" -ForegroundColor Gray
        Write-Host ""
        $openLabel = if ($IsWindows) { "Open $Target folder in Explorer" } else { "Open $Target folder in file manager" }
        Write-MenuOption "O" $openLabel
        Write-MenuOption "Enter" "Return to main menu"
        $postChoice = Read-MenuChoice "Choose"
        if ($postChoice -eq 'O' -or $postChoice -eq 'o') {
            try { Open-FolderInFileManager -Path $instancePath } catch { Write-Warn "Could not open folder: $($_.Exception.Message)" }
        }
    }
    catch {
        if ($postDeletion) {
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║  CRITICAL: Update failed after folders were deleted!        ║" -ForegroundColor Red
            Write-Host "  ║                                                             ║" -ForegroundColor Red
            $errMsg = $_.Exception.Message ?? 'Unknown error'
            $errLines = @()
            # Wrap message into 49-char chunks so the box border stays aligned
            for ($ci = 0; $ci -lt $errMsg.Length; $ci += 49) {
                $errLines += $errMsg.Substring($ci, [Math]::Min(49, $errMsg.Length - $ci)).PadRight(49)
            }
            if ($errLines.Count -eq 0) { $errLines = @('Unknown error'.PadRight(49)) }
            foreach ($eLine in $errLines) {
                Write-Host "  ║  Error: $eLine║" -ForegroundColor Red
            }
            Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
            Write-Log "[CRITICAL] Post-deletion failure: $($_.Exception.ToString())"

            # Offer automatic rollback if snapshot exists
            if ($rollbackDir -and (Test-Path -LiteralPath $rollbackDir)) {
                Write-Host "  A rollback snapshot was saved before the update." -ForegroundColor Yellow
                Write-Host ""
                if (Confirm-Action "Attempt automatic rollback to pre-update state?") {
                    $rollbackOk = Invoke-RollbackFromSnapshot -RollbackDir $rollbackDir -InstancePath $instancePath -Target $Target
                    if ($rollbackOk) {
                        Write-Success "Instance rolled back successfully."
                    } else {
                        Write-Err "Automatic rollback failed. Restore from your backup."
                    }
                } else {
                    Write-Warn "Restore from your backup to recover."
                }
            } else {
                Write-Warn "No rollback snapshot available. Restore from your backup."
            }
        } else {
            Write-Err "Update failed: $($_.Exception.Message)"
            Write-Log "[ERROR] Stable update failed: $($_.Exception.ToString())"
        }
    }
    finally {
        # Clean up temp dirs always
        Remove-TempDir $customModTempDir
        Remove-TempDir $overrideModTempDir
        Remove-TempDir $preserveTempDir
        # Clean up staging folder on success only; keep on failure/cancel
        if ($updateSucceeded) {
            Remove-TempDir $stagingDir
            Write-Info "Staging folder cleaned up."
        }
        # Clean up rollback snapshot on success (not needed anymore)
        if ($updateSucceeded) { Remove-TempDir $rollbackDir }
        # Clean up temp zip file (already cached by Invoke-FileDownload)
        if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
            try { Remove-Item -LiteralPath $zipPath -Force } catch {}
        }
    }
}

function Move-StagingToInstance {
    <#
    .SYNOPSIS
        Move staging folder content to the instance path.
    .DESCRIPTION
        Handles the nested folder structure from the zip extraction:
        - If staging has a single root folder containing pack content, flatten it.
        - For client targets, handle .minecraft subfolder and instance-root items
          (libraries/, patches/, mmc-pack.json) at the parent of DestinationPath.
        - Moves all content from the resolved content root into DestinationPath.
    .PARAMETER StagingDir
        Path to the staging folder (staging-X.Y.Z/).
    .PARAMETER DestinationPath
        The directory to move content into (instance root for server, .minecraft for client).
    .PARAMETER Target
        The target type: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][string]$StagingDir,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [string]$JavaVersion = 'java17'
    )
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    }

    # Determine the actual content root within staging
    # Handles single-nested (common) and double-nested (rare, some zip tools) structures
    $contentRoot = $StagingDir
    $maxDepth = 3  # Safety limit to prevent infinite loops on weird zips
    for ($flattenPass = 0; $flattenPass -lt $maxDepth; $flattenPass++) {
        $topItems = Get-ChildItem -LiteralPath $contentRoot
        if ($topItems.Count -ne 1 -or -not $topItems[0].PSIsContainer) { break }

        # Single folder - check if it contains pack content
        $singleDir = $topItems[0].FullName
        $hasPackContent = (Test-Path -LiteralPath (Join-Path $singleDir 'mods')) -or
                          (Test-Path -LiteralPath (Join-Path $singleDir 'config')) -or
                          (Test-Path -LiteralPath (Join-Path $singleDir '.minecraft'))
        if ($hasPackContent) {
            $contentRoot = $singleDir
            Write-Info "  Flattening wrapper folder: $($topItems[0].Name)"
        } else {
            break  # Single folder but no pack content - stop
        }
    }

    # For client zips, the content might be inside a .minecraft subfolder
    $dotMinecraft = Join-Path $contentRoot '.minecraft'
    if (Test-Path -LiteralPath $dotMinecraft) {
        # Move instance-root items to parent of DestinationPath
        $instanceRoot = Split-Path -Parent $DestinationPath

        if ($JavaVersion -eq 'java17') {
            foreach ($item in $script:ClientJava17InstanceRootItems) {
                $srcItem = Join-Path $contentRoot $item
                if (Test-Path -LiteralPath $srcItem) {
                    $destItem = Join-Path $instanceRoot $item
                    if (Test-Path -LiteralPath $destItem) {
                        Remove-Item -LiteralPath $destItem -Recurse -Force
                    }
                    Move-Item -LiteralPath $srcItem -Destination $destItem -Force
                    Write-Info "  Moved to instance root: $item"
                }
            }
        }

        # Use .minecraft as the content root for the destination
        $contentRoot = $dotMinecraft
    }

    # Move content root items into destination
    $moveErrors = @()
    Get-ChildItem -LiteralPath $contentRoot | ForEach-Object {
        $destPath = Join-Path $DestinationPath $_.Name
        try {
            if (Test-Path -LiteralPath $destPath) {
                Remove-Item -LiteralPath $destPath -Recurse -Force
            }
            Move-Item -LiteralPath $_.FullName -Destination $destPath -Force -ErrorAction Stop
        }
        catch {
            $moveErrors += $_.Name
            Write-Log "[ERROR] Failed to move '$($_.Name)': $($_.Exception.Message)"
        }
    }
    if ($moveErrors.Count -gt 0) {
        Write-Warn "$($moveErrors.Count) item(s) failed to move: $($moveErrors -join ', ')"
        throw "Pack installation incomplete - $($moveErrors.Count) item(s) failed to move."
    }

    Write-Success "Pack installed to: $DestinationPath"

    # For client without .minecraft in zip, still check for instance-root items
    if ($Target -eq 'client' -and $JavaVersion -eq 'java17') {
        $instanceRoot = Split-Path -Parent $DestinationPath

        foreach ($item in $script:ClientJava17InstanceRootItems) {
            $extractedItem = Join-Path $DestinationPath $item
            if (Test-Path -LiteralPath $extractedItem) {
                $destItem = Join-Path $instanceRoot $item
                if (Test-Path -LiteralPath $destItem) {
                    Remove-Item -LiteralPath $destItem -Recurse -Force
                }
                Move-Item -LiteralPath $extractedItem -Destination $destItem -Force
                Write-Info "  Moved to instance root: $item"
            }
        }
    }
}

function Invoke-DeleteFolders {
    <#
    .SYNOPSIS
        Delete specified folders based on target type and Java version.
    .DESCRIPTION
        Server: delete config/, libraries/, mods/, resources/, scripts/ from InstancePath.
          If java17, also delete lwjgl3ify-forgePatches.jar, java9args.txt,
          startserver-java9.bat, startserver-java9.sh.
        Client: delete config/, mods/, serverutilities/, resources/, scripts/ from
          InstancePath (.minecraft). If java17, also delete libraries/, patches/,
          mmc-pack.json at the PARENT of InstancePath (Prism instance root).
        Displays each folder/file as deleted. Skips if doesn't exist.
    .PARAMETER InstancePath
        The root path of the instance (server root or .minecraft for client).
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER JavaVersion
        The Java version: 'java17' or 'java8'.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [Parameter(Mandatory)][string]$JavaVersion
    )

    $foldersToDelete = $Target -eq 'server' ? $script:ServerFoldersToDelete : $script:ClientFoldersToDelete

    foreach ($folder in $foldersToDelete) {
        $folderPath = Join-Path $InstancePath $folder
        if (Test-Path -LiteralPath $folderPath) {
            try {
                Remove-Item -LiteralPath $folderPath -Recurse -Force
            }
            catch {
                Write-Err "Failed to delete $folder/: $($_.Exception.Message)"
                throw
            }
        }
    }

    # Java 17+ specific deletions
    if ($JavaVersion -eq 'java17') {
        if ($Target -eq 'server') {
            foreach ($file in $script:ServerJava17FilesToDelete) {
                $filePath = Join-Path $InstancePath $file
                if (Test-Path -LiteralPath $filePath) {
                    try {
                        Remove-Item -LiteralPath $filePath -Force
                    }
                    catch {
                        Write-Err "Failed to delete $file`: $($_.Exception.Message)"
                        throw
                    }
                }
            }
        } else {
            $instanceRoot = Split-Path -Parent $InstancePath
            foreach ($item in $script:ClientJava17InstanceRootItems) {
                $itemPath = Join-Path $instanceRoot $item
                if (Test-Path -LiteralPath $itemPath) {
                    try {
                        Remove-Item -LiteralPath $itemPath -Recurse -Force
                    }
                    catch {
                        Write-Err "Failed to delete $item at instance root: $($_.Exception.Message)"
                        throw
                    }
                }
            }
        }
    }
}
