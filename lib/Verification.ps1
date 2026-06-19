# ============================================================================
# Group 13: Post-Update Verification - Validate instance integrity after update
# ============================================================================
# Functions:
#   Invoke-Verification  - Check critical directories and files exist after update
#
# Checks performed:
#   - mods/, config/, libraries/ directories exist
#   - Mod count (warn if < 50 JARs)
#   - GregTech JAR present (core mod)
#   - Duplicate mods (same base name, different versions)
#   - Target-specific: JourneyMapServer (server), options.txt (client)
# ============================================================================

function Invoke-Verification {
    <#
    .SYNOPSIS
        Run post-update verification checks on an instance.
    .DESCRIPTION
        Checks that critical directories exist, counts mods (warns if < 50),
        verifies GregTech JAR is present, and checks target-specific files.
        Displays results via Write-Success for passes and Write-Warn for issues.
    .PARAMETER InstancePath
        The root path of the instance (server root or .minecraft for client).
    .PARAMETER Target
        The target type: 'server' or 'client'.
    .PARAMETER Quick
        If set, skips the deep mod-ID jar scan (faster for frequent daily updates).
        Still performs filename-based duplicate detection.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target,
        [switch]$Quick
    )

    $allPassed = $true
    $warnings = @()

    # Check mods/ directory exists
    $modsPath = Join-Path $InstancePath 'mods'
    if (-not (Test-Path -LiteralPath $modsPath)) {
        $warnings += "mods/ directory is MISSING"
        $allPassed = $false
    }

    # Check config/ directory exists
    $configPath = Join-Path $InstancePath 'config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $warnings += "config/ directory is MISSING"
        $allPassed = $false
    }

    # Check libraries/ directory exists
    # For client, libraries/ is at the Prism instance root (parent of .minecraft)
    if ($Target -eq 'client') {
        $clientInstanceRoot = if ((Split-Path -Leaf $InstancePath) -eq '.minecraft') {
            Split-Path -Parent $InstancePath
        } else {
            $InstancePath
        }
        $librariesPath = Join-Path $clientInstanceRoot 'libraries'
    } else {
        $librariesPath = Join-Path $InstancePath 'libraries'
    }
    if (-not (Test-Path -LiteralPath $librariesPath)) {
        $warnings += "libraries/ directory is MISSING"
        $allPassed = $false
    }

    # Count .jar files in mods/
    $modCount = 0
    if (Test-Path -LiteralPath $modsPath) {
        $modCount = (Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File).Count
        if ($modCount -lt 50) {
            $warnings += "Only $modCount mods found (GTNH typically has 250+). Update may be incomplete."
            $allPassed = $false
        }
    }

    # Check for GregTech JAR
    if (Test-Path -LiteralPath $modsPath) {
        $gregTechJar = Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File |
            Where-Object { $_.Name -like '*gregtech*' -or $_.Name -like '*GT5*' }
        if (-not $gregTechJar) {
            $warnings += "GregTech JAR NOT found - this may not be a valid GTNH instance"
            $allPassed = $false
        }
    }

    # Target-specific checks
    if ($Target -eq 'server') {
        $journeyMapServer = Join-Path $InstancePath 'config' 'JourneyMapServer'
        if (-not (Test-Path -LiteralPath $journeyMapServer)) {
            # Not a failure — created on first server start
            Write-Log "[VERIFY] config/JourneyMapServer not present (generated on first start)"
        }
    } else {
        $optionsFile = Join-Path $InstancePath 'options.txt'
        if (-not (Test-Path -LiteralPath $optionsFile)) {
            # Not a failure — created on first client launch
            Write-Log "[VERIFY] options.txt not present (generated on first launch)"
        }
    }

    # Check for duplicate mods (same base name, different versions)
    if (Test-Path -LiteralPath $modsPath) {
        $modJars = Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File
        $baseNameMap = @{}  # baseName -> list of filenames

        foreach ($jar in $modJars) {
            $baseName = Get-ModBaseName -FileName $jar.Name
            if (-not $baseNameMap.ContainsKey($baseName)) {
                $baseNameMap[$baseName] = @()
            }
            $baseNameMap[$baseName] += $jar.Name
        }

        $duplicates = $baseNameMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

        # Second pass: fuzzy matching to catch naming convention differences
        # (e.g., "Steve-s-Factory-Manager" vs "StevesFactoryManager", "SleepingBags" vs "sleepingbag")
        $fuzzyMap = @{}  # normalized name -> list of filenames
        foreach ($jar in $modJars) {
            $baseName = Get-ModBaseName -FileName $jar.Name
            # Handle possessives: 's, -s- (Steve's → Steves, Steve-s- → Steves)
            $fuzzyName = $baseName -replace "['']s\b", 's'
            $fuzzyName = $fuzzyName -replace '-s-', 's'
            # Aggressively normalize: remove spaces, hyphens, underscores, dots, plus signs
            $fuzzyName = ($fuzzyName -replace '[\s\-_\.+]', '').ToLower()
            # Strip trailing 's' for plural normalization (SleepingBags → sleepingbag)
            # Only strip if preceded by a letter that commonly forms plurals (not 'ss', 'ps', 'ns', 'us')
            if ($fuzzyName.Length -gt 5 -and $fuzzyName.EndsWith('s') -and $fuzzyName -notmatch '(ss|ps|ns|us|is|as)$') {
                $fuzzyName = $fuzzyName.Substring(0, $fuzzyName.Length - 1)
            }
            if (-not $fuzzyMap.ContainsKey($fuzzyName)) {
                $fuzzyMap[$fuzzyName] = @()
            }
            $fuzzyMap[$fuzzyName] += $jar.Name
        }
        $fuzzyDuplicates = $fuzzyMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

        # Merge: use fuzzy results (superset of exact results)
        $allDuplicates = if ($fuzzyDuplicates) { $fuzzyDuplicates } else { $duplicates }

        if ($allDuplicates) {
            $dupCount = @($allDuplicates).Count
            $warnings += "Found $dupCount mod(s) with multiple versions:"
            foreach ($dup in $allDuplicates) {
                $files = $dup.Value | Sort-Object
                $warnings += "    * $($files -join ', ')"
            }
            $warnings += "Multiple versions of the same mod will crash the game. Remove the older version(s)."
            $allPassed = $false
        }
    }

    # Check for zero-byte (corrupted) jar files
    if (Test-Path -LiteralPath $modsPath) {
        $emptyJars = Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File | Where-Object { $_.Length -eq 0 }
        if ($emptyJars) {
            $warnings += "Found $($emptyJars.Count) empty/corrupted JAR file(s):"
            foreach ($ej in $emptyJars) {
                $warnings += "    * $($ej.Name) (0 bytes)"
            }
            $warnings += "These will cause class-not-found errors. Delete and re-download them."
            $allPassed = $false
        }
    }

    # Deep duplicate check: read mod IDs from mcmod.info inside jars
    # This catches cases where filenames are completely different but the mod ID is the same
    # Skipped in Quick mode (nightly updates where the updater controls all mods)
    if (-not $Quick -and (Test-Path -LiteralPath $modsPath)) {
        $modIdMap = @{}  # modId -> list of filenames
        $modJarsForId = Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File | Where-Object { $_.Length -gt 0 }
        foreach ($jar in $modJarsForId) {
            $zip = $null
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
                $mcmodEntry = $zip.Entries | Where-Object { $_.FullName -eq 'mcmod.info' } | Select-Object -First 1
                if ($mcmodEntry) {
                    $reader = [System.IO.StreamReader]::new($mcmodEntry.Open())
                    $content = $reader.ReadToEnd()
                    $reader.Dispose()
                    # Extract modid values (simple regex -- mcmod.info is JSON-like)
                    $modIds = [regex]::Matches($content, '"modid"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.ToLower() }
                    foreach ($modId in $modIds) {
                        if (-not $modIdMap.ContainsKey($modId)) { $modIdMap[$modId] = @() }
                        $modIdMap[$modId] += $jar.Name
                    }
                }
            } catch {
                # Skip jars that can't be read (corrupted, not a zip, etc.)
            } finally {
                if ($zip) { try { $zip.Dispose() } catch {} }
            }
        }
        $idDuplicates = $modIdMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
        if ($idDuplicates) {
            $idDupCount = @($idDuplicates).Count
            $warnings += "Found $idDupCount mod ID(s) present in multiple JARs:"
            foreach ($dup in $idDuplicates) {
                $warnings += "    * Mod ID '$($dup.Key)': $($dup.Value -join ', ')"
            }
            $warnings += "Duplicate mod IDs will crash the game. Remove the older version(s)."
            $allPassed = $false
        }
    }

    # Check for jars in mods/1.7.10/ that also exist in mods/ (cross-folder duplicates)
    if (Test-Path -LiteralPath $modsPath) {
        $subModsPath = Join-Path $modsPath '1.7.10'
        if (Test-Path -LiteralPath $subModsPath) {
            $mainMods = @(Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File | ForEach-Object { $_.Name })
            $subMods = @(Get-ChildItem -LiteralPath $subModsPath -Filter '*.jar' -File)
            $crossDupes = @()
            foreach ($subMod in $subMods) {
                $subBase = (Get-ModBaseName -FileName $subMod.Name) -replace "['']s\b", 's'
                $subBase = ($subBase -replace '-s-', 's') -replace '[\s\-_\.+]', ''
                $subBase = $subBase.ToLower()
                if ($subBase.Length -gt 5 -and $subBase.EndsWith('s') -and $subBase -notmatch '(ss|ps|ns|us|is|as)$') { $subBase = $subBase.Substring(0, $subBase.Length - 1) }
                foreach ($mainMod in $mainMods) {
                    $mainBase = (Get-ModBaseName -FileName $mainMod) -replace "['']s\b", 's'
                    $mainBase = ($mainBase -replace '-s-', 's') -replace '[\s\-_\.+]', ''
                    $mainBase = $mainBase.ToLower()
                    if ($mainBase.Length -gt 5 -and $mainBase.EndsWith('s') -and $mainBase -notmatch '(ss|ps|ns|us|is|as)$') { $mainBase = $mainBase.Substring(0, $mainBase.Length - 1) }
                    if ($subBase -eq $mainBase) {
                        $crossDupes += "$($subMod.Name) (mods/1.7.10/) conflicts with $mainMod (mods/)"
                        break
                    }
                }
            }
            if ($crossDupes.Count -gt 0) {
                $warnings += "Found $($crossDupes.Count) cross-folder duplicate(s):"
                foreach ($cd in $crossDupes) {
                    $warnings += "    * $cd"
                }
                $allPassed = $false
            }
        }
    }

    # Log all results regardless of pass/fail
    Write-Log "[VERIFY] Target=$Target, Passed=$allPassed, ModCount=$modCount, Warnings=$($warnings.Count)"
    foreach ($w in $warnings) { Write-Log "[VERIFY] $w" }

    # Display: single line if all passed, full details if issues found
    if ($allPassed) {
        Write-Success "Verification passed ($modCount mods, no issues)"
    } else {
        Write-Host ""
        Write-Warn "Verification found issues:"
        foreach ($w in $warnings) {
            if ($w -match '^\s{4}\*') {
                Write-Host "  $w" -ForegroundColor DarkYellow
            } elseif ($w -match '^(Multiple versions|Duplicate mod IDs|These will cause|Remove the older)') {
                Write-Info "  $w"
            } else {
                Write-Warn $w
            }
        }
        Write-Host ""
    }
}
