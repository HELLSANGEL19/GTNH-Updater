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
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $instancePath = $Target -eq 'server' ? $Config.ServerPath : $Config.ClientInstancePath

    # Initialize cleanup variables upfront so finally blocks are safe
    $customModTempDir = $null
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

    Write-Header "Stable Update - $($Target.ToUpper())"

    # ── Step 1: Query latest version ──────────────────────────────────────────
    Write-Step "Checking for latest stable release..."

    $release = Get-LatestStableRelease -PackType ($Config.JavaVersion ?? 'java17')
    if (-not $release) {
        Write-Info "Primary API failed, trying fallback..."
        $release = Get-LatestStableReleaseFallback -PackType ($Config.JavaVersion ?? 'java17')
    }

    if (-not $release) {
        Write-Err "Could not determine latest version."
        Write-Info "Check your internet connection and try again."
        return
    }

    $latestVersion = $release.Version
    Write-Info "Latest stable version: $latestVersion"

    # ── Step 2: Compare with installed version ────────────────────────────────
    Write-Step "Comparing versions..."

    $installedVersion = $Target -eq 'server' ? $Config.InstalledServerVersion : $Config.InstalledClientVersion

    # Check for dangerous downgrade: daily/experimental -> stable
    if ($installedVersion -and $installedVersion -match 'nightly') {
        # Extract the base version from the nightly tag (e.g., "2.9.0" from "2.9.0-nightly-2026-04-29")
        $nightlyBase = $null
        if ($installedVersion -match '^(\d+\.\d+\.\d+)') {
            $nightlyBase = $Matches[1]
        }

        # Compare: if the stable version is the same base or older, this is a downgrade
        $isDowngrade = $false
        if ($nightlyBase) {
            try {
                $nightlyVer = [version]$nightlyBase
                $stableVer = [version]$latestVersion
                if ($stableVer -lt $nightlyVer) {
                    $isDowngrade = $true
                }
            } catch {
                # Version parsing failed, assume downgrade if nightly base matches
                if ($nightlyBase -eq $latestVersion) {
                    $isDowngrade = $true
                }
            }
        }

        if ($isDowngrade) {
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║  DOWNGRADE WARNING                                          ║" -ForegroundColor Red
            Write-Host "  ║                                                              ║" -ForegroundColor Red
            Write-Host "  ║  You are on a dev build. Going back to an older stable       ║" -ForegroundColor Red
            Write-Host "  ║  release can CORRUPT your world and break saves.             ║" -ForegroundColor Red
            Write-Host "  ║                                                              ║" -ForegroundColor Red
            Write-Host "  ║  Only do this with a backup from BEFORE you switched         ║" -ForegroundColor Red
            Write-Host "  ║  to daily/experimental.                                      ║" -ForegroundColor Red
            Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
            Write-Warn "Current: $installedVersion"
            Write-Warn "Target:  $latestVersion (stable)"
            Write-Host ""
            if (-not (Confirm-Action "I understand the risk. Proceed with downgrade?")) {
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
        $hashResponse = Invoke-WebRequest -Uri $hashUrl -UseBasicParsing -ErrorAction SilentlyContinue
        if ($hashResponse -and $hashResponse.Content) {
            # Hash files typically contain "hash  filename" or just the hash
            $hashContent = $hashResponse.Content.Trim()
            if ($hashContent -match '^([a-fA-F0-9]{64})') {
                $expectedHash = $Matches[1]
            }
        }
    }
    catch {
        # No hash file available, that's fine
        Write-Log "[INTEGRITY] No .sha256 sidecar found for $zipName"
    }

    $integrityResult = Test-FileIntegrity -FilePath $zipPath -ExpectedHash $expectedHash
    if ($integrityResult -eq $false) {
        Write-Err "Downloaded file failed integrity check. It may be corrupted."
        Write-Info "Try clearing the cache (Settings > Backups and cache) and downloading again."
        # Remove the bad file from cache too
        $cachedBad = Join-Path $script:CacheDir $zipName
        if (Test-Path -LiteralPath $cachedBad) {
            try { Remove-Item -LiteralPath $cachedBad -Force } catch {}
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
            # Remove potentially corrupted file from cache
            $cachedCorrupt = Join-Path $script:CacheDir $zipName
            if (Test-Path -LiteralPath $cachedCorrupt) {
                try {
                    Remove-Item -LiteralPath $cachedCorrupt -Force
                    Write-Info "Removed cached file (may be corrupted): $zipName"
                }
                catch {}
            }
            return
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

    # Categorize mods
    $added = @()
    $removed = @()
    $updated = @()
    $custom = @()

    foreach ($base in $newBaseMap.Keys) {
        if (-not $currentBaseMap.ContainsKey($base)) {
            $added += $newBaseMap[$base]
        }
        elseif ($currentBaseMap[$base] -ne $newBaseMap[$base]) {
            $updated += [PSCustomObject]@{ Old = $currentBaseMap[$base]; New = $newBaseMap[$base] }
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
        Write-Host "  Any of these your custom mods? They'll be preserved during updates." -ForegroundColor White
        Write-Host "  Enter numbers separated by commas (e.g., 1,3,5), 'a' for all, or Enter to skip: " -NoNewline -ForegroundColor White
        $markInput = (Read-Host).Trim()

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
        Write-Host "  Mods updated (version change) ($($updated.Count)):" -ForegroundColor Yellow
        $sortedUpdated = @($updated | Sort-Object { $_.New })
        if ($sortedUpdated.Count -le $pageSize) {
            foreach ($entry in $sortedUpdated) {
                Write-Host "    ~ $($entry.Old) -> $($entry.New)" -ForegroundColor Yellow
            }
        } else {
            for ($p = 0; $p -lt $sortedUpdated.Count; $p += $pageSize) {
                $end = [math]::Min($p + $pageSize, $sortedUpdated.Count)
                for ($j = $p; $j -lt $end; $j++) {
                    Write-Host "    ~ $($sortedUpdated[$j].Old) -> $($sortedUpdated[$j].New)" -ForegroundColor Yellow
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

    if ($added.Count -eq 0 -and $removed.Count -eq 0 -and $updated.Count -eq 0 -and $custom.Count -eq 0) {
        Write-Host ""
        Write-Info "No mod differences detected."
    }

    Write-Host ""
    $diff = $newJars.Count - $currentJars.Count
    $diffLabel = $diff -gt 0 ? "+$diff" : "$diff"
    Write-Info "Summary: $($added.Count) added, $($removed.Count) removed, $($updated.Count) updated, $($custom.Count) custom  (net: $diffLabel)"

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
                if ($mod -like "*$searchTerm*") {
                    Write-Host "    + $mod" -ForegroundColor Green
                    $anyFound = $true
                }
            }
            foreach ($mod in ($removed | Sort-Object)) {
                if ($mod -like "*$searchTerm*") {
                    Write-Host "    - $mod" -ForegroundColor Red
                    $anyFound = $true
                }
            }
            foreach ($entry in $updated) {
                if ($entry.Old -like "*$searchTerm*" -or $entry.New -like "*$searchTerm*") {
                    Write-Host "    ~ $($entry.Old) -> $($entry.New)" -ForegroundColor Yellow
                    $anyFound = $true
                }
            }
            foreach ($mod in ($custom | Sort-Object)) {
                if ($mod -like "*$searchTerm*") {
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
    Write-MenuOption -Key 'O' -Description 'Open staging in Explorer'
    Write-MenuOption -Key 'C' -Description 'Cancel'

    $applyUpdate = $false
    while ($true) {
        $choice = Read-MenuChoice 'Choose an option'

        switch ($choice.ToUpper()) {
            'A' {
                # Show backup warning before applying
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
                if (-not (Confirm-Action "Ready to apply? Instance is backed up and server is stopped?")) {
                    Write-Info "Waiting. Choose again when ready."
                    continue
                }
                $applyUpdate = $true
                break
            }
            'O' {
                Start-Process explorer.exe -ArgumentList "`"$stagingDir`""
                Write-Info "Opened in Explorer. Choose again when ready."
            }
            'C' {
                Write-Info "Update cancelled. Staging folder preserved at: $stagingDir"
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

    $totalSteps = 7
    $customModsToRestore = $savedCustomMods

    # ── Backup custom mods to temp ────────────────────────────────────────────
    Write-Step "Step 1/$totalSteps`: Backing up custom mods..."

    $customModTempDir = Join-Path $tempDir 'custom-mods'
    if (Test-Path -LiteralPath $customModTempDir) {
        Remove-Item -LiteralPath $customModTempDir -Recurse -Force
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
                        $candidates = @()
                        if ($stagingModsPath) {
                            $newBaseNamesForPick = @{}
                            foreach ($jar in (Get-ChildItem -LiteralPath $stagingModsPath -Filter '*.jar' -File)) {
                                $newBaseNamesForPick[(Get-ModBaseName -FileName $jar.Name)] = $true
                            }
                            $candidates = @($currentJarFiles | Where-Object {
                                -not $newBaseNamesForPick.ContainsKey((Get-ModBaseName -FileName $_.Name))
                            } | ForEach-Object { $_.Name } | Sort-Object)
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
            if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
                try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
            }
            if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
                try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
            }
            return
        }
    }
    # ── Script-level backup (if enabled) ──────────────────────────────────────
    $backupOk = Invoke-ScriptBackup -Config $Config -InstancePath $instancePath -Target $Target
    if ($backupOk -eq $false) {
        Write-Err "Backup failed. Update cancelled for safety."
        Write-Info "Fix the backup issue or disable backups in Settings, then try again."
        # Clean up temp dirs before aborting
        if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
            try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
        }
        if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
            try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
        }
        return
    }

    # ── POINT OF NO RETURN ────────────────────────────────────────────────────
    # Save a rollback snapshot so we can recover if the update fails mid-way
    $rollbackDir = Save-RollbackSnapshot -InstancePath $instancePath -Target $Target
    if (-not $rollbackDir) {
        Write-Warn "Could not save rollback snapshot. If the update fails, you will need your backup."
        if (-not (Confirm-Action "Continue without rollback safety net?")) {
            Write-Info "Update cancelled."
            # Clean up temp dirs
            if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
                try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
            }
            if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
                try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
            }
            return
        }
    }

    $postDeletion = $false
    $updateSucceeded = $false

    try {
        # ── Delete folders ────────────────────────────────────────────────────
        Write-Step "Step 3/$totalSteps`: Deleting old pack files..."
        $postDeletion = $true

        Invoke-DeleteFolders -InstancePath $instancePath -Target $Target -JavaVersion $javaVersion

        # ── Move staging to instance ──────────────────────────────────────────
        Write-Step "Step 4/$totalSteps`: Installing new pack from staging..."

        Move-StagingToInstance -StagingDir $stagingDir -DestinationPath $instancePath -Target $Target

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

        # ── Apply config patches ──────────────────────────────────────────────
        Write-Step "Step 7/$totalSteps`: Applying config patches..."

        Invoke-ConfigPatches -Config $Config -InstancePath $instancePath -Target $Target

        # ── Run verification ──────────────────────────────────────────────────
        Write-Step "Running verification..."

        Invoke-Verification -InstancePath $instancePath -Target $Target

        # ── Record history, update installed version ──────────────────────────
        Write-Step "Recording update..."

        $historyDetails = "+$($added.Count) -$($removed.Count) ~$($updated.Count)"
        Add-UpdateHistoryEntry -Config $Config -Version $latestVersion -Channel 'stable' -Target $Target -Details $historyDetails

        if ($Target -eq 'server') {
            $Config.InstalledServerVersion = $latestVersion
        } else {
            $Config.InstalledClientVersion = $latestVersion
        }
        Save-Config -Config $Config

        $updateSucceeded = $true

        Write-Host ""
        Write-Success "Stable update complete! $Target updated to v$latestVersion."
    }
    catch {
        if ($postDeletion) {
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║  CRITICAL: Update failed after folders were deleted!        ║" -ForegroundColor Red
            Write-Host "  ║                                                             ║" -ForegroundColor Red
            Write-Host "  ║  Error: $(($_.Exception.Message ?? 'Unknown error').PadRight(49).Substring(0,49))║" -ForegroundColor Red
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
        if ($customModTempDir -and (Test-Path -LiteralPath $customModTempDir)) {
            try { Remove-Item -LiteralPath $customModTempDir -Recurse -Force } catch {}
        }
        if ($preserveTempDir -and (Test-Path -LiteralPath $preserveTempDir)) {
            try { Remove-Item -LiteralPath $preserveTempDir -Recurse -Force } catch {}
        }
        # Clean up staging folder on success only; keep on failure/cancel
        if ($updateSucceeded -and (Test-Path -LiteralPath $stagingDir)) {
            try { Remove-Item -LiteralPath $stagingDir -Recurse -Force } catch {}
            Write-Info "Staging folder cleaned up."
        }
        # Clean up rollback snapshot on success (not needed anymore)
        if ($updateSucceeded -and $rollbackDir -and (Test-Path -LiteralPath $rollbackDir)) {
            try { Remove-Item -LiteralPath $rollbackDir -Recurse -Force } catch {}
        }
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
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    }

    # Determine the actual content root within staging
    $contentRoot = $StagingDir
    $topItems = Get-ChildItem -LiteralPath $StagingDir
    if ($topItems.Count -eq 1 -and $topItems[0].PSIsContainer) {
        # Single root folder in staging - check if it contains pack content
        $singleDir = $topItems[0].FullName
        $hasPackContent = (Test-Path -LiteralPath (Join-Path $singleDir 'mods')) -or
                          (Test-Path -LiteralPath (Join-Path $singleDir 'config')) -or
                          (Test-Path -LiteralPath (Join-Path $singleDir '.minecraft'))
        if ($hasPackContent) {
            $contentRoot = $singleDir
            Write-Info "  Staging has root folder: $($topItems[0].Name) - flattening."
        }

        # For client zips, the content might be inside a .minecraft subfolder
        $dotMinecraft = Join-Path $contentRoot '.minecraft'
        if (Test-Path -LiteralPath $dotMinecraft) {
            # Move instance-root items to parent of DestinationPath
            $instanceRoot = Split-Path -Parent $DestinationPath

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

            # Use .minecraft as the content root for the destination
            $contentRoot = $dotMinecraft
        }
    }

    # Move content root items into destination
    Get-ChildItem -LiteralPath $contentRoot | ForEach-Object {
        $destPath = Join-Path $DestinationPath $_.Name
        if (Test-Path -LiteralPath $destPath) {
            Remove-Item -LiteralPath $destPath -Recurse -Force
        }
        Move-Item -LiteralPath $_.FullName -Destination $destPath -Force
    }

    Write-Success "Pack installed to: $DestinationPath"

    # For client without .minecraft in zip, still check for instance-root items
    if ($Target -eq 'client') {
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
