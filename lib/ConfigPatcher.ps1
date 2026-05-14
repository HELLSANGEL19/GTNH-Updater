# ============================================================================
# Group 9: Config Patcher - Apply key-value patches to Forge .cfg and .properties
# ============================================================================
# Functions:
#   Set-ConfigValue         - Read a config file, find matching key, replace value
#   Invoke-ConfigPatches    - Apply all patches for a given target sequentially
#   Test-ConfigPatches      - Read-only: display current vs. patched values
#   Invoke-ConfigBrowse     - Interactive browser: pick a .cfg file, key, and value
#   Invoke-ConfigPatchMenu  - Sub-menu for managing patches
#
# Forge .cfg format: B:key=value, I:key=value, S:key=value, D:key=value
# .properties format: key=value
# Path normalization: forward slashes replaced with backslashes before opening.
# ============================================================================

function Find-KeyInLines {
    <#
    .SYNOPSIS
        Find the line index of a key within an optional section. Returns -1 if not found.
    .PARAMETER Lines
        Array of file lines to search.
    .PARAMETER Key
        The config key (already regex-escaped by caller if needed).
    .PARAMETER Section
        Optional section name to scope the search.
    #>
    param(
        [string[]]$Lines,
        [Parameter(Mandatory)][string]$Key,
        [string]$Section = ''
    )

    # Handle empty file content gracefully
    if (-not $Lines -or $Lines.Count -eq 0 -or ($Lines.Count -eq 1 -and [string]::IsNullOrWhiteSpace($Lines[0]))) {
        return -1
    }

    $escapedKey = [regex]::Escape($Key)
    $pattern = "^\s*${escapedKey}\s*="
    $currentSection = ''
    $inTargetSection = [string]::IsNullOrEmpty($Section)
    $depth = 0  # brace nesting depth within the current section

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]

        # Skip comment lines — they shouldn't affect section tracking or key matching
        if ($line -match '^\s*[#/]') { continue }

        if ($line -match '^\s*"?([^"{}=#]+)"?\s*\{') {
            $depth++
            # Only update section tracking at depth 1 (top-level sections)
            if ($depth -eq 1) {
                $currentSection = $Matches[1].Trim()
                if (-not [string]::IsNullOrEmpty($Section)) {
                    $inTargetSection = $currentSection -eq $Section
                }
            }
        }
        elseif ($line -match '^\s*\}' -and -not [string]::IsNullOrEmpty($Section)) {
            if ($depth -gt 0) { $depth-- }
            # Only reset section tracking when we close a top-level section
            if ($depth -eq 0) {
                $inTargetSection = $false
                $currentSection = ''
            }
        }
        if ($inTargetSection -and $line -match $pattern) {
            return $i
        }
    }
    return -1
}

function Set-ConfigValue {
    <#
    .SYNOPSIS
        Read a config file, find the line matching the key, replace the value.
    .DESCRIPTION
        Normalizes the file path (replaces / with \), builds the full path from
        InstancePath + FilePath, reads all lines, finds the matching key using
        regex, replaces the value portion after =, and writes back.
        Supports Forge .cfg format (B:key=value, I:key=value, etc.) and
        .properties format (key=value).
        When Section is specified, only matches the key within that section block.
    .PARAMETER FilePath
        Relative path from instance root to the config file.
    .PARAMETER Key
        The config key including type prefix for Forge files (e.g., B:pollution).
    .PARAMETER Value
        The value to set.
    .PARAMETER InstancePath
        The root path of the instance.
    .PARAMETER Section
        Optional section name to scope the key match (for files with duplicate keys
        in different sections).
    .OUTPUTS
        $true if the key was found and patched, $false otherwise.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$InstancePath,
        [string]$Section = ''
    )

    # Normalize path separators to platform convention
    $normalizedPath = $FilePath -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString()
    $fullPath = Join-Path $InstancePath $normalizedPath

    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-Warn "Config file not found: $normalizedPath"
        return $false
    }

    try {
        $lines = @(Get-Content -LiteralPath $fullPath -Encoding UTF8)

        $i = Find-KeyInLines -Lines $lines -Key $Key -Section $Section
        $found = $i -ge 0

        if ($found) {
            # Preserve leading whitespace
            $leadingWhitespace = if ($lines[$i] -match '^(\s*)') { $Matches[1] } else { '' }
            $lines[$i] = "${leadingWhitespace}${Key}=${Value}"
        }

        if ($found) {
            Set-Content -LiteralPath $fullPath -Value $lines -Encoding UTF8 -Force
            return $true
        } else {
            $sectionNote = $Section ? " in section '$Section'" : ''
            Write-Warn "Key '$Key' not found${sectionNote} in: $normalizedPath"
            return $false
        }
    }
    catch {
        Write-Err "Failed to patch config file '$normalizedPath': $($_.Exception.Message)"
        Write-Log "[ERROR] Config patch failed: $($_.Exception.ToString())"
        return $false
    }
}

function Invoke-ConfigPatches {
    <#
    .SYNOPSIS
        Validate and apply all config patches for the given target.
    .DESCRIPTION
        First validates all patches (checks file exists, key exists in file).
        Reports any issues and lets the user skip broken patches or cancel.
        Then applies valid patches via Set-ConfigValue.
    .PARAMETER Config
        The config PSCustomObject containing ConfigPatches array.
    .PARAMETER InstancePath
        The root path of the instance.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $patches = $Config.ConfigPatches | Where-Object {
        $_.Target -eq $Target -or $_.Target -eq 'both'
    }

    if (-not $patches -or @($patches).Count -eq 0) {
        Write-Info "No config patches configured for $Target."
        return
    }

    $patchList = @($patches)

    # ── Pre-flight validation ─────────────────────────────────────────────────
    $validPatches = @()
    $issues = @()

    foreach ($patch in $patchList) {
        $normalizedPath = $patch.FilePath -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString()
        $fullPath = Join-Path $InstancePath $normalizedPath
        $desc = $patch.Description ? " ($($patch.Description))" : ''

        if (-not (Test-Path -LiteralPath $fullPath)) {
            $issues += [PSCustomObject]@{
                Patch   = $patch
                Problem = "File not found: $($patch.FilePath)"
            }
            continue
        }

        # Check if the key exists in the file
        try {
            $lines = @(Get-Content -LiteralPath $fullPath -Encoding UTF8)
            $sectionParam = if ($patch.PSObject.Properties.Name -contains 'Section' -and -not [string]::IsNullOrEmpty($patch.Section)) { $patch.Section } else { '' }
            $keyFound = (Find-KeyInLines -Lines $lines -Key $patch.Key -Section $sectionParam) -ge 0
            Write-Log "[PATCH-PREFLIGHT] File: $($patch.FilePath) | Key: $($patch.Key) | Section: '$sectionParam' | Lines: $($lines.Count) | Found: $keyFound"

            if (-not $keyFound) {
                $sectionNote = $sectionParam ? " in section '$sectionParam'" : ''
                $issues += [PSCustomObject]@{
                    Patch   = $patch
                    Problem = "Key '$($patch.Key)' not found${sectionNote} in $($patch.FilePath)"
                }
                continue
            }
        }
        catch {
            $issues += [PSCustomObject]@{
                Patch   = $patch
                Problem = "Cannot read file: $($_.Exception.Message)"
            }
            Write-Log "[PATCH-PREFLIGHT] EXCEPTION for $($patch.FilePath): $($_.Exception.Message)"
            continue
        }

        $validPatches += $patch
    }

    # Report issues if any
    if ($issues.Count -gt 0) {
        Write-Warn "$($issues.Count) patch(es) have issues:"
        foreach ($issue in $issues) {
            $desc = $issue.Patch.Description ? " ($($issue.Patch.Description))" : ''
            Write-Host "    - $($issue.Problem)$desc" -ForegroundColor DarkYellow
        }
        Write-Host ""
        if ($validPatches.Count -gt 0) {
            Write-Info "$($validPatches.Count) valid patch(es) will still be applied."
            Write-Info "Fix or remove broken patches in Settings > Config Patches."
        } else {
            Write-Warn "No valid patches to apply."
            return
        }
    }

    # ── Apply valid patches ───────────────────────────────────────────────────
    if ($validPatches.Count -eq 0) {
        return
    }

    Write-Info "Applying $($validPatches.Count) patch(es)..."

    foreach ($patch in $validPatches) {
        $patchParams = @{
            FilePath     = $patch.FilePath
            Key          = $patch.Key
            Value        = $patch.Value
            InstancePath = $InstancePath
        }
        if ($patch.Section) {
            $patchParams['Section'] = $patch.Section
        }
        $result = Set-ConfigValue @patchParams
        $desc = $patch.Description ? " ($($patch.Description))" : ''
        if ($result) {
            Write-Info "  Patched: $($patch.FilePath) -> $($patch.Key)=$($patch.Value)$desc"
            Write-Log "[PATCH] Applied: $($patch.FilePath) | $($patch.Key)=$($patch.Value)"
        } else {
            Write-Warn "  Failed: $($patch.FilePath) -> $($patch.Key)$desc"
            Write-Log "[PATCH] Failed: $($patch.FilePath) | $($patch.Key)"
        }
    }
}

function Test-ConfigPatches {
    <#
    .SYNOPSIS
        Read-only mode: display current vs. patched values without modifying files.
    .DESCRIPTION
        Same filter as Invoke-ConfigPatches but only reads files and shows what
        would change. Does not write anything.
    .PARAMETER Config
        The config PSCustomObject containing ConfigPatches array.
    .PARAMETER InstancePath
        The root path of the instance.
    .PARAMETER Target
        The target type: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $patches = $Config.ConfigPatches | Where-Object {
        $_.Target -eq $Target -or $_.Target -eq 'both'
    }

    if (-not $patches -or @($patches).Count -eq 0) {
        Write-Info "No config patches configured for $Target."
        return
    }

    Write-Header "Config Patch Test ($Target)"

    foreach ($patch in $patches) {
        $normalizedPath = $patch.FilePath -replace '[/\\]', [IO.Path]::DirectorySeparatorChar.ToString()
        $fullPath = Join-Path $InstancePath $normalizedPath

        Write-Info "File: $($patch.FilePath)"
        Write-Info "Key:  $($patch.Key)"

        if (-not (Test-Path -LiteralPath $fullPath)) {
            Write-Warn "  File not found - cannot test."
            Write-Host ""
            continue
        }

        $lines = @(Get-Content -LiteralPath $fullPath -Encoding UTF8)
        $currentValue = '(not found)'
        $idx = Find-KeyInLines -Lines $lines -Key $patch.Key -Section ($patch.Section ?? '')
        if ($idx -ge 0) {
            $currentValue = ($lines[$idx] -split '=', 2)[1].Trim()
        }
        Write-Info "  Would be: $($patch.Key)=$($patch.Value)"
        $desc = $patch.Description ? "  ($($patch.Description))" : ''
        if ($desc) { Write-Info $desc }
        Write-Host ""
    }
}

function Invoke-ConfigBrowse {
    <#
    .SYNOPSIS
        Interactive browser: pick a .cfg file, then pick a key, then set a value.
    .DESCRIPTION
        Scans the config/ folder of the specified instance for .cfg files,
        lets the user pick one, parses it for key=value lines, lets the user
        pick a key, shows the current value, and asks for the new value.
        Returns a patch object or $null if cancelled.
    .PARAMETER InstancePath
        The root path of the instance to browse.
    .OUTPUTS
        PSCustomObject with FilePath, Key, Value, Description - or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath
    )

    $configDir = Join-Path $InstancePath 'config'
    if (-not (Test-Path -LiteralPath $configDir)) {
        Write-Err "Config folder not found: $configDir"
        Write-Info "Make sure the instance path points to a valid GTNH installation."
        return $null
    }

    # Step 1: List .cfg files
    Write-Header "Browse Config Files"

    $cfgFiles = @(Get-ChildItem -LiteralPath $configDir -Include '*.cfg', '*.properties' -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $rel = $_.FullName.Substring($InstancePath.Length).TrimStart('\', '/')
            [PSCustomObject]@{
                RelativePath = $rel
                FullPath     = $_.FullName
                Name         = $_.Name
            }
        })

    # Also check for server.properties at instance root
    $serverProps = Join-Path $InstancePath 'server.properties'
    if (Test-Path -LiteralPath $serverProps) {
        $alreadyIncluded = $cfgFiles | Where-Object { $_.FullPath -eq $serverProps }
        if (-not $alreadyIncluded) {
            $cfgFiles = @([PSCustomObject]@{
                RelativePath = 'server.properties'
                FullPath     = $serverProps
                Name         = 'server.properties'
            }) + $cfgFiles
        }
    }

    if ($cfgFiles.Count -eq 0) {
        Write-Warn "No .cfg files found in config folder."
        return $null
    }

    # Show paginated list with search
    $pageSize = 20
    $page = 0
    $searchFilter = ''
    $filtered = $cfgFiles

    while ($true) {
        if ($searchFilter) {
            $filtered = @($cfgFiles | Where-Object { $_.RelativePath -like "*$searchFilter*" })
        } else {
            $filtered = $cfgFiles
        }

        $totalPages = [math]::Max(1, [math]::Ceiling($filtered.Count / $pageSize))
        if ($page -ge $totalPages) { $page = 0 }
        $startIdx = $page * $pageSize
        $endIdx = [math]::Min($startIdx + $pageSize, $filtered.Count) - 1

        if ($searchFilter) {
            Write-Host "  Search: " -NoNewline -ForegroundColor Gray
            Write-Host "$searchFilter" -NoNewline -ForegroundColor Yellow
            Write-Host " ($($filtered.Count) matches)" -ForegroundColor DarkGray
        } else {
            Write-Info "Config files ($($cfgFiles.Count) total):"
        }
        if ($filtered.Count -eq 0) {
            Write-Info "No files match '$searchFilter'."
        } else {
            Write-Host ""
            $tagWidth = "[$($filtered.Count)]".Length
            for ($i = $startIdx; $i -le $endIdx; $i++) {
                $tag = "[$($i + 1)]".PadLeft($tagWidth)
                Write-Host "    $tag $($filtered[$i].RelativePath)" -ForegroundColor Cyan
            }
        }
        Write-Host ""
        Write-MenuOption "/" "Search (e.g. /pollution)"
        if ($searchFilter) { Write-MenuOption "/" "Clear search" }
        if ($totalPages -gt 1) { Write-MenuOption "N/P" "Next/Previous page" }
        Write-MenuOption "Q" "Cancel"

        $fileChoice = Read-MenuChoice "Select file"

        if ($fileChoice -eq 'q' -or $fileChoice -eq 'Q') { return $null }
        if ($fileChoice -eq '/') { $searchFilter = ''; $page = 0; continue }
        if ($fileChoice -match '^/(.+)') { $searchFilter = $Matches[1]; $page = 0; continue }
        if ($fileChoice -eq 'n' -or $fileChoice -eq 'N') {
            if ($page -lt $totalPages - 1) { $page++ }
            continue
        }
        if ($fileChoice -eq 'p' -or $fileChoice -eq 'P') {
            if ($page -gt 0) { $page-- }
            continue
        }

        $fileIdx = 0
        if ([int]::TryParse($fileChoice, [ref]$fileIdx) -and $fileIdx -ge 1 -and $fileIdx -le $filtered.Count) {
            $selectedFile = $filtered[$fileIdx - 1]
            break
        }

        Write-Warn "Invalid selection."
    }

    # Step 2: Parse the selected file for key=value lines
    Write-Header "Keys in: $($selectedFile.RelativePath)"
    Write-Host ""

    $lines = Get-Content -LiteralPath $selectedFile.FullPath -Encoding UTF8
    $keys = @()
    $currentSection = ''
    $depth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Track section headers and closings
        if ($line -match '^\s*"?([^"{}=#]+)"?\s*\{') {
            $depth++
            if ($depth -eq 1) { $currentSection = $Matches[1].Trim() }
        }
        elseif ($line -match '^\s*\}') {
            if ($depth -gt 0) { $depth-- }
            if ($depth -eq 0) { $currentSection = '' }
        }

        # Match key=value lines: B:key=value, I:key=value, S:key=value, or plain key=value (.properties)
        if ($line -match '^\s*([BISD]:[^=]+?)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $keys += [PSCustomObject]@{
                Key     = $key
                Value   = $value
                Section = $currentSection
                Line    = $i + 1
            }
        }
        elseif ($line -match '^\s*([a-zA-Z][\w\-\.]*)\s*=\s*(.*)$' -and $line -notmatch '^\s*#') {
            # Plain key=value (e.g., server.properties format)
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $keys += [PSCustomObject]@{
                Key     = $key
                Value   = $value
                Section = $currentSection
                Line    = $i + 1
            }
        }
    }

    if ($keys.Count -eq 0) {
        Write-Warn "No patchable key=value entries found in this file."
        Write-Info "(Only simple B:/I:/S:/D: key=value lines can be patched.)"
        return $null
    }

    # Show keys grouped by section, paginated with search
    $keyPage = 0
    $keyPageSize = 15
    $keySearchFilter = ''
    $filteredKeys = $keys

    while ($true) {
        if ($keySearchFilter) {
            $filteredKeys = @($keys | Where-Object { $_.Key -like "*$keySearchFilter*" -or $_.Value -like "*$keySearchFilter*" -or $_.Section -like "*$keySearchFilter*" })
        } else {
            $filteredKeys = $keys
        }

        $keyTotalPages = [math]::Max(1, [math]::Ceiling($filteredKeys.Count / $keyPageSize))
        if ($keyPage -ge $keyTotalPages) { $keyPage = 0 }
        $kStart = $keyPage * $keyPageSize
        $kEnd = [math]::Min($kStart + $keyPageSize, $filteredKeys.Count) - 1

        if ($keySearchFilter) {
            Write-Host "  Search: " -NoNewline -ForegroundColor Gray
            Write-Host "$keySearchFilter" -NoNewline -ForegroundColor Yellow
            Write-Host " ($($filteredKeys.Count) matches)" -ForegroundColor DarkGray
        } else {
            Write-Info "Patchable keys ($($keys.Count) total):"
        }
        if ($filteredKeys.Count -eq 0) {
            Write-Info "No keys match '$keySearchFilter'."
        } else {
            Write-Host ""
            $lastSection = ''
            $tagWidth = "[$($filteredKeys.Count)]".Length
            for ($i = $kStart; $i -le $kEnd; $i++) {
                $k = $filteredKeys[$i]
                if ($k.Section -ne $lastSection) {
                    Write-Host "    -- $($k.Section) --" -ForegroundColor DarkGray
                    $lastSection = $k.Section
                }
                $tag = "[$($i + 1)]".PadLeft($tagWidth)
                Write-Host "    $tag " -NoNewline -ForegroundColor White
                Write-Host "$($k.Key)" -NoNewline -ForegroundColor Cyan
                Write-Host " = $($k.Value)" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-MenuOption "/" "Search (e.g. /pollution)"
        if ($keySearchFilter) { Write-MenuOption "/" "Clear search" }
        if ($keyTotalPages -gt 1) { Write-MenuOption "N/P" "Next/Previous page" }
        Write-MenuOption "Q" "Cancel"

        $keyChoice = Read-MenuChoice "Select key"

        if ($keyChoice -eq 'q' -or $keyChoice -eq 'Q') { return $null }
        if ($keyChoice -eq '/') { $keySearchFilter = ''; $keyPage = 0; continue }
        if ($keyChoice -match '^/(.+)') { $keySearchFilter = $Matches[1]; $keyPage = 0; continue }
        if ($keyChoice -eq 'n' -or $keyChoice -eq 'N') {
            if ($keyPage -lt $keyTotalPages - 1) { $keyPage++ }
            continue
        }
        if ($keyChoice -eq 'p' -or $keyChoice -eq 'P') {
            if ($keyPage -gt 0) { $keyPage-- }
            continue
        }

        $keyIdx = 0
        if ([int]::TryParse($keyChoice, [ref]$keyIdx) -and $keyIdx -ge 1 -and $keyIdx -le $filteredKeys.Count) {
            $selectedKey = $filteredKeys[$keyIdx - 1]
            break
        }

        Write-Warn "Invalid selection."
    }

    # Step 3: Show current value and ask for new value
    Write-Host ""
    Write-Host "  Selected: " -NoNewline -ForegroundColor White
    Write-Host "$($selectedKey.Key) = $($selectedKey.Value)" -ForegroundColor Cyan
    Write-Host ""

    # For booleans, offer clear choices
    if ($selectedKey.Key -match '^B:' -and ($selectedKey.Value -eq 'true' -or $selectedKey.Value -eq 'false')) {
        $opposite = $selectedKey.Value -eq 'true' ? 'false' : 'true'
        Write-Info "Patch will re-apply this value after every update."
        Write-Host ""
        Write-Host "  [1] Preserve as $($selectedKey.Value)" -ForegroundColor Yellow
        Write-Host "  [2] Set to $opposite instead" -ForegroundColor Yellow
        Write-Host "  [Q] Cancel" -ForegroundColor Yellow
        $boolChoice = Read-MenuChoice "Choose"
        if ($boolChoice -eq '1') {
            $newValue = $selectedKey.Value
        } elseif ($boolChoice -eq '2') {
            $newValue = $opposite
        } else {
            return $null
        }
    } else {
        Write-Info "Press Enter to preserve current value, or type a new one."
        $newValue = Read-UserInput "Value to enforce after updates" -Default $selectedKey.Value
    }

    if ([string]::IsNullOrEmpty($newValue)) {
        Write-Warn "No value entered. Cancelled."
        return $null
    }

    $desc = Read-UserInput "Description (optional)"

    return [PSCustomObject]@{
        FilePath    = $selectedFile.RelativePath -replace '\\', '/'
        Key         = $selectedKey.Key
        Value       = $newValue
        Description = $desc
        Section     = $selectedKey.Section
    }
}

function Invoke-ConfigPatchMenu {
    <#
    .SYNOPSIS
        Sub-menu for managing config patches: add, delete, test, examples, clear.
    .PARAMETER Config
        The config PSCustomObject to modify.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Config Patch Manager"

        if ($Config.ConfigPatches.Count -gt 0) {
            $tagWidth = "[$($Config.ConfigPatches.Count)]".Length
            for ($i = 0; $i -lt $Config.ConfigPatches.Count; $i++) {
                $p = $Config.ConfigPatches[$i]
                $targetLabel = $p.Target -eq 'both' ? 'server+client' : $p.Target
                $autoLabel   = $p.Source -eq 'auto' ? ' (auto)' : ''
                $tag = "[$($i + 1)]".PadLeft($tagWidth)
                Write-Host "  $tag " -NoNewline -ForegroundColor White
                Write-Host "$($p.Description ?? $p.Key)" -NoNewline -ForegroundColor Cyan
                Write-Host " [$targetLabel]$autoLabel" -ForegroundColor DarkGray
                Write-Host "      $($p.FilePath) | $($p.Key)=$($p.Value)" -ForegroundColor Gray
            }
        } else {
            Write-Info "No patches configured."
        }

        Write-Host ""
        Write-MenuOption -Key 'B' -Description 'Browse config files and pick a key'
        Write-MenuOption -Key 'A' -Description 'Add a patch manually'
        Write-MenuOption -Key 'E' -Description 'Add from common patches'
        if ($Config.ConfigPatches.Count -gt 0) {
            Write-MenuOption -Key 'F' -Description 'Edit a patch'
            Write-MenuOption -Key 'D' -Description 'Delete a patch'
            Write-MenuOption -Key 'T' -Description 'Test patches (read-only preview)'
            Write-MenuOption -Key 'X' -Description 'Export patches to file'
        }
        Write-MenuOption -Key 'I' -Description 'Import patches from file'
        Write-MenuOption -Key 'G' -Description 'Re-scan for config changes (compare your instance against the pack defaults)'
        if ($Config.ConfigPatches.Count -gt 0) {
            Write-MenuOption -Key 'C' -Description 'Clear all patches'
        }
        Write-MenuOption -Key 'R' -Description 'Return to previous menu'

        $choice = Read-MenuChoice -Prompt 'Choose an option'

        switch ($choice.ToUpper()) {
            'B' {
                # Browse config files interactively
                Write-Info "Browse which instance? [1] Server, [2] Client"
                $browseTarget = Read-MenuChoice "Target"
                $browsePath = $browseTarget -eq '1' ? $Config.ServerPath : $Config.ClientInstancePath
                $browseTargetName = $browseTarget -eq '1' ? 'server' : 'client'

                if ([string]::IsNullOrEmpty($browsePath) -or -not (Test-Path -LiteralPath $browsePath)) {
                    Write-Warn "No valid $browseTargetName path configured."
                    continue
                }

                $patch = Invoke-ConfigBrowse -InstancePath $browsePath
                if ($null -ne $patch) {
                    Write-Info "Apply this patch to: [1] Server, [2] Client, [3] Both"
                    $browseTargetChoice = Read-MenuChoice "Target"
                    $browseTargetValue = switch ($browseTargetChoice) {
                        '1' { 'server' }
                        '2' { 'client' }
                        default { 'both' }
                    }
                    $patch | Add-Member -NotePropertyName 'Target' -NotePropertyValue $browseTargetValue -Force

                    $Config.ConfigPatches += $patch
                    Save-Config -Config $Config
                    Write-Success "Patch added: $($patch.Key) = $($patch.Value) [$browseTargetValue]"
                }
                Wait-ForKey
            }
            'A' {
                # Add a new patch
                Write-Header "Add Config Patch"
                Write-Host ""
                Write-Info "Config file path (relative to instance root):"
                Write-Host '  Example: config/GregTech/Pollution.cfg' -ForegroundColor Cyan
                Write-Host '  Example: config/forge.cfg' -ForegroundColor Cyan
                Write-Info "(Config files can be in subfolders like config/GregTech/)"
                $filePath = Read-UserInput -Prompt 'File path'
                if ([string]::IsNullOrWhiteSpace($filePath)) {
                    Write-Warn "File path is required."
                    Wait-ForKey
                    continue
                }

                Write-Info "Config key (everything before the = sign):"
                Write-Host '  Example: B:"Activate Pollution"' -ForegroundColor Cyan
                Write-Host '  Example: I:advancedCokeOvenPollutionAmount' -ForegroundColor Cyan
                Write-Host '  Example: S:explosionPollutionAmount' -ForegroundColor Cyan
                Write-Info "(Include the type prefix B: I: S: D: exactly as shown)"
                $key = Read-UserInput -Prompt 'Key'
                if ([string]::IsNullOrWhiteSpace($key)) {
                    Write-Warn "Key is required."
                    Wait-ForKey
                    continue
                }

                Write-Info "Value to set:"
                Write-Host '  Example: false' -ForegroundColor Cyan
                Write-Host '  Example: 0' -ForegroundColor Cyan
                $value = Read-UserInput -Prompt 'Value'
                if ($null -eq $value -or $value -eq '') {
                    Write-Warn "Value is required (use 'false', '0', or empty string in quotes if needed)."
                    Wait-ForKey
                    continue
                }

                # Validate value matches the key's type prefix
                $typeWarning = $null
                if ($key -match '^B:' -and $value -notin @('true', 'false')) {
                    $typeWarning = "Key has B: prefix (boolean) but value is '$value'. Expected 'true' or 'false'."
                }
                elseif ($key -match '^I:' -and $value -notmatch '^\-?\d+$') {
                    $typeWarning = "Key has I: prefix (integer) but value is '$value'. Expected a whole number."
                }
                elseif ($key -match '^D:' -and $value -notmatch '^\-?\d+(\.\d+)?$') {
                    $typeWarning = "Key has D: prefix (decimal) but value is '$value'. Expected a number."
                }
                if ($typeWarning) {
                    Write-Warn $typeWarning
                    if (-not (Confirm-Action "Use this value anyway?")) {
                        continue
                    }
                }

                Write-Info "Description (optional):"
                $desc = Read-UserInput -Prompt 'Description'

                Write-Info "Target: [1] Server, [2] Client, [3] Both"
                $targetChoice = Read-MenuChoice -Prompt 'Target'
                $target = switch ($targetChoice) {
                    '1' { 'server' }
                    '2' { 'client' }
                    '3' { 'both' }
                    default { 'both' }
                }

                $newPatch = [PSCustomObject]@{
                    FilePath    = $filePath
                    Key         = $key
                    Value       = $value
                    Description = $desc
                    Target      = $target
                }

                $Config.ConfigPatches += $newPatch
                Save-Config -Config $Config
                Write-Success "Patch added."
                Wait-ForKey
            }
            'E' {
                # Config patch template library
                Write-Header "Config Patch Templates"
                Write-Host ""

                $templates = @(
                    [PSCustomObject]@{
                        Name        = 'Disable pollution'
                        FilePath    = 'config/GregTech/Pollution.cfg'
                        Key         = 'B:"Activate Pollution"'
                        Value       = 'false'
                        Description = 'Disable GregTech pollution mechanic entirely'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable all GT machine explosions'
                        FilePath    = 'config/GregTech/GregTech.cfg'
                        Key         = 'B:machineExplosions'
                        Section     = 'machines'
                        Value       = 'false'
                        Description = 'Prevent all GregTech machines from exploding under any condition'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable GT rain/thunder explosions'
                        FilePath    = 'config/GregTech/GregTech.cfg'
                        Key         = 'B:machineRainExplosions'
                        Section     = 'machines'
                        Value       = 'false'
                        Description = 'Machines will not explode when exposed to rain (also set machineThunderExplosions for thunder)'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable GT wrench explosions'
                        FilePath    = 'config/GregTech/GregTech.cfg'
                        Key         = 'B:machineNonWrenchExplosions'
                        Section     = 'machines'
                        Value       = 'false'
                        Description = 'Machines will not explode when broken without a wrench'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable harder mob spawners'
                        FilePath    = 'config/GregTech/GregTech.cfg'
                        Key         = 'B:harderMobSpawner'
                        Section     = 'general'
                        Value       = 'false'
                        Description = 'Mob spawners return to vanilla hardness and blast resistance'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable AE2 channels'
                        FilePath    = 'config/AppliedEnergistics2/AppliedEnergistics2.cfg'
                        Key         = 'B:Channels'
                        Section     = 'networkfeatures'
                        Value       = 'false'
                        Description = 'Remove AE2 channel limits (singleplayer or apply server-side for multiplayer)'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable all special creepers'
                        FilePath    = 'config/SpecialMobs.cfg'
                        Key         = 'B:_special_creepers'
                        Section     = 'creeper_rates'
                        Value       = 'false'
                        Description = 'Prevent special creeper variants (gravel, doom, splitting, etc.) from spawning'
                    }
                    [PSCustomObject]@{
                        Name        = 'Morpheus sleep percentage'
                        FilePath    = 'config/Morpheus.cfg'
                        Key         = 'I:SleeperPerc'
                        Section     = 'settings'
                        Value       = '50'
                        Description = 'Percentage of online players that must sleep to skip night (server only, default 50)'
                    }
                    [PSCustomObject]@{
                        Name        = 'Disable warp environmental effects'
                        FilePath    = 'config/WarpTheory.cfg'
                        Key         = 'B:allowGlobalWarpEffects'
                        Value       = 'false'
                        Description = 'Disables warp-triggered environment effects like livestock rain'
                    }
                    [PSCustomObject]@{
                        Name        = 'Enable borderless fullscreen (Java 17+ only)'
                        FilePath    = 'config/lwjgl3ify.cfg'
                        Key         = 'B:borderless'
                        Value       = 'true'
                        Description = 'Replaces exclusive fullscreen with borderless windowed (requires Java 17+ pack, not Java 8)'
                    }
                )

                $tagWidth = "[$($templates.Count)]".Length
                for ($i = 0; $i -lt $templates.Count; $i++) {
                    $t = $templates[$i]
                    $tag = "[$($i + 1)]".PadLeft($tagWidth)
                    Write-Host "  $tag " -NoNewline -ForegroundColor White
                    Write-Host "$($t.Name)" -ForegroundColor Cyan
                    Write-Host "      $($t.FilePath) | $($t.Key) = $($t.Value)" -ForegroundColor Gray
                }
                Write-Host ""
                Write-MenuOption "A" "Add all templates"
                Write-MenuOption "R" "Return"

                $templateChoice = Read-MenuChoice "Select template number, 'a' for all, or 'r' to return"

                if ($templateChoice -eq 'r' -or $templateChoice -eq 'R') {
                    # Return handled by loop
                }
                elseif ($templateChoice -eq 'a' -or $templateChoice -eq 'A') {
                    $addedTemplateCount = 0
                    foreach ($t in $templates) {
                        # Check for duplicates by file+key
                        $exists = $Config.ConfigPatches | Where-Object {
                            $_.FilePath -eq $t.FilePath -and $_.Key -eq $t.Key
                        }
                        if (-not $exists) {
                            $newPatch = [PSCustomObject]@{
                                FilePath    = $t.FilePath
                                Key         = $t.Key
                                Value       = $t.Value
                                Description = $t.Description
                                Target      = 'both'
                            }
                            if ($t.PSObject.Properties.Name -contains 'Section') {
                                $newPatch | Add-Member -NotePropertyName 'Section' -NotePropertyValue $t.Section
                            }
                            $Config.ConfigPatches += $newPatch
                            $addedTemplateCount++
                        }
                    }
                    if ($addedTemplateCount -gt 0) {
                        Save-Config -Config $Config
                        Write-Success "Added $addedTemplateCount template patch(es)."
                    } else {
                        Write-Info "All templates already in your patch list."
                    }
                }
                else {
                    $tIdx = 0
                    if ([int]::TryParse($templateChoice, [ref]$tIdx) -and $tIdx -ge 1 -and $tIdx -le $templates.Count) {
                        $selected = $templates[$tIdx - 1]

                        # Check for duplicate
                        $exists = $Config.ConfigPatches | Where-Object {
                            $_.FilePath -eq $selected.FilePath -and $_.Key -eq $selected.Key
                        }
                        if ($exists) {
                            Write-Warn "This patch is already in your list."
                        } else {
                            Write-Info "Apply to: [1] Server, [2] Client, [3] Both"
                            $tTarget = Read-MenuChoice "Target"
                            $tTargetValue = switch ($tTarget) {
                                '1' { 'server' }
                                '2' { 'client' }
                                default { 'both' }
                            }

                            $newPatch = [PSCustomObject]@{
                                FilePath    = $selected.FilePath
                                Key         = $selected.Key
                                Value       = $selected.Value
                                Description = $selected.Description
                                Target      = $tTargetValue
                            }
                            if ($selected.PSObject.Properties.Name -contains 'Section') {
                                $newPatch | Add-Member -NotePropertyName 'Section' -NotePropertyValue $selected.Section
                            }
                            $Config.ConfigPatches += $newPatch
                            Save-Config -Config $Config
                            Write-Success "Added: $($selected.Name)"
                        }
                    } else {
                        Write-Warn "Invalid selection."
                    }
                }
                Wait-ForKey
            }
            'F' {
                # Edit a patch
                if ($Config.ConfigPatches.Count -eq 0) {
                    Write-Warn "No patches to edit."
                    continue
                }
                $indexStr = Read-UserInput -Prompt 'Enter patch number to edit'
                $editIdx = 0
                if (-not [int]::TryParse($indexStr, [ref]$editIdx) -or $editIdx -lt 1 -or $editIdx -gt $Config.ConfigPatches.Count) {
                    Write-Warn "Invalid patch number."
                    Wait-ForKey
                    continue
                }
                $editPatch = $Config.ConfigPatches[$editIdx - 1]

                Write-Header "Edit Patch: $($editPatch.Description ?? $editPatch.Key)"

                Write-Host "  File:   " -NoNewline -ForegroundColor Gray
                Write-Host "$($editPatch.FilePath)" -ForegroundColor Cyan
                Write-Host "  Key:    " -NoNewline -ForegroundColor Gray
                Write-Host "$($editPatch.Key)" -ForegroundColor Cyan
                Write-Host "  Value:  " -NoNewline -ForegroundColor Gray
                Write-Host "$($editPatch.Value)" -ForegroundColor Cyan
                Write-Host "  Target: " -NoNewline -ForegroundColor Gray
                Write-Host "$($editPatch.Target)" -ForegroundColor Cyan
                Write-Host ""

                Write-MenuOption "1" "Change value"
                Write-MenuOption "2" "Change target (server/client/both)"
                Write-MenuOption "3" "Change description"
                Write-MenuOption "R" "Cancel"

                $editChoice = Read-MenuChoice "Edit what"

                switch ($editChoice) {
                    '1' {
                        $newVal = Read-UserInput "New value" -Default $editPatch.Value
                        if ($newVal) {
                            $editPatch.Value = $newVal
                            Save-Config -Config $Config
                            Write-Success "Value updated to: $newVal"
                        }
                    }
                    '2' {
                        Write-MenuOption "1" "Server only"
                        Write-MenuOption "2" "Client only"
                        Write-MenuOption "3" "Both"
                        $tChoice = Read-MenuChoice "Target"
                        $editPatch.Target = switch ($tChoice) {
                            '1' { 'server' }
                            '2' { 'client' }
                            default { 'both' }
                        }
                        Save-Config -Config $Config
                        Write-Success "Target updated to: $($editPatch.Target)"
                    }
                    '3' {
                        $newDesc = Read-UserInput "New description" -Default ($editPatch.Description ?? '')
                        $editPatch.Description = $newDesc
                        Save-Config -Config $Config
                        Write-Success "Description updated."
                    }
                }
                Wait-ForKey
            }
            'D' {
                # Delete a patch
                if ($Config.ConfigPatches.Count -eq 0) {
                    Write-Warn "No patches to delete."
                    continue
                }
                $indexStr = Read-UserInput -Prompt 'Enter patch number to delete'
                $index = 0
                if (-not [int]::TryParse($indexStr, [ref]$index)) {
                    Write-Warn "Invalid patch number."
                    continue
                }
                $index = $index - 1
                if ($index -ge 0 -and $index -lt $Config.ConfigPatches.Count) {
                    $removed = $Config.ConfigPatches[$index]
                    $Config.ConfigPatches = @($Config.ConfigPatches | Where-Object { $_ -ne $removed })
                    Save-Config -Config $Config
                    Write-Success "Patch deleted: $($removed.Description ?? $removed.Key)"
                } else {
                    Write-Warn "Invalid patch number."
                }
                Wait-ForKey
            }
            'T' {
                # Test patches
                Write-Info "Test against which target? [1] Server, [2] Client"
                $testTarget = Read-MenuChoice -Prompt 'Target'
                $targetName = $testTarget -eq '1' ? 'server' : 'client'
                $instancePath = $targetName -eq 'server' ? $Config.ServerPath : $Config.ClientInstancePath

                if ([string]::IsNullOrEmpty($instancePath)) {
                    Write-Warn "No $targetName path configured."
                } else {
                    Test-ConfigPatches -Config $Config -InstancePath $instancePath -Target $targetName
                }
                Wait-ForKey
            }
            'X' {
                # Export patches to file
                if ($Config.ConfigPatches.Count -eq 0) {
                    Write-Warn "No patches to export."
                } else {
                    $defaultPath = Join-Path $script:ScriptDir 'gtnh-patches-export.json'
                    $exportPath = Read-UserInput "Export path" -Default $defaultPath
                    if ($exportPath) {
                        try {
                            $Config.ConfigPatches | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $exportPath -Encoding UTF8 -Force
                            Write-Success "Exported $($Config.ConfigPatches.Count) patch(es) to: $(Split-Path -Leaf $exportPath)"
                        }
                        catch {
                            Write-Err "Export failed: $($_.Exception.Message)"
                        }
                    }
                }
                Wait-ForKey
            }
            'I' {
                # Import patches from file
                $importPath = Read-UserInput "Path to patches file"
                if ($importPath -and (Test-Path -LiteralPath $importPath)) {
                    try {
                        $raw = Get-Content -LiteralPath $importPath -Raw -ErrorAction Stop
                        $imported = $raw | ConvertFrom-Json -ErrorAction Stop

                        # Ensure it's an array
                        if ($imported -isnot [System.Collections.IEnumerable] -or $imported -is [string]) {
                            $imported = @($imported)
                        }

                        # Validate each patch has required fields
                        $validPatches = @()
                        foreach ($p in $imported) {
                            if ($p.FilePath -and $p.Key -and $p.PSObject.Properties.Name -contains 'Value') {
                                $validPatches += $p
                            }
                        }

                        if ($validPatches.Count -eq 0) {
                            Write-Warn "No valid patches found in file."
                        } else {
                            # Check for duplicates and add new ones
                            $addedCount = 0
                            foreach ($p in $validPatches) {
                                $exists = $Config.ConfigPatches | Where-Object {
                                    $_.FilePath -eq $p.FilePath -and $_.Key -eq $p.Key
                                }
                                if (-not $exists) {
                                    # Ensure Target field exists
                                    if (-not $p.Target) {
                                        $p | Add-Member -NotePropertyName 'Target' -NotePropertyValue 'both' -Force
                                    }
                                    $Config.ConfigPatches += $p
                                    $addedCount++
                                }
                            }
                            if ($addedCount -gt 0) {
                                Save-Config -Config $Config
                                Write-Success "Imported $addedCount new patch(es). $($validPatches.Count - $addedCount) duplicate(s) skipped."
                            } else {
                                Write-Info "All patches already in your list."
                            }
                        }
                    }
                    catch {
                        Write-Err "Import failed: $($_.Exception.Message)"
                    }
                } else {
                    Write-Warn "File not found."
                }
                Wait-ForKey
            }
            'C' {
                # Clear all patches
                if (Confirm-Action "Clear ALL config patches?") {
                    $Config.ConfigPatches = @()
                    Save-Config -Config $Config
                    Write-Success "All patches cleared."
                }
                Wait-ForKey
            }
            'G' {
                # Re-scan for config changes using the pack defaults
                Write-Info "Compares your current config files against the pack's defaults."
                Write-Info "Any keys you've changed will be offered as new patches."
                Write-Host ""
                Write-Info "Re-scan against which target? [1] Server, [2] Client"
                $scanTarget = Read-MenuChoice "Target"
                $scanTargetName = $scanTarget -eq '1' ? 'server' : 'client'
                $scanVersion    = $scanTarget -eq '1' ? $Config.InstalledServerVersion : $Config.InstalledClientVersion
                $scanInstance   = $scanTarget -eq '1' ? $Config.ServerPath : $Config.ClientInstancePath

                if ([string]::IsNullOrEmpty($scanInstance) -or -not (Test-Path -LiteralPath $scanInstance)) {
                    Write-Warn "No valid $scanTargetName path configured."
                    Wait-ForKey; continue
                }

                # Determine if this is a nightly/daily instance
                $scanIsNightly = ($Config.DefaultChannel ?? 'stable') -ne 'stable'
                $nightlyState = Join-Path $scanInstance '.gtnh-nightly-state.json'
                if (Test-Path -LiteralPath $nightlyState) { $scanIsNightly = $true }
                if ($scanVersion -match 'nightly|daily|experimental|\d{4}-\d{2}-\d{2}|^GTNH-') { $scanIsNightly = $true }

                $scanZipPath = $null
                $tempZip = $null

                if ($scanIsNightly) {
                    # ── Daily/Experimental: use saved config baseline or download ─────
                    $nightlyState = Join-Path $scanInstance '.gtnh-nightly-state.json'
                    if (-not (Test-Path -LiteralPath $nightlyState)) {
                        Write-Warn "No update has been run through this tool yet for this instance."
                        Write-Info "Run a daily/experimental update first, then the config scan will work accurately."
                        Wait-ForKey; continue
                    }

                    # Check for saved config baseline first (avoids re-downloading)
                    $baselinePath = Join-Path $scanInstance '.gtnh-config-baseline.zip'
                    if (Test-Path -LiteralPath $baselinePath) {
                        Write-Info "Using saved config baseline."
                        $scanZipPath = $baselinePath
                    } else {
                        # No baseline saved - download from GitHub
                        $stateData = $null
                        try {
                            $stateData = Get-Content -LiteralPath $nightlyState -Raw | ConvertFrom-Json
                        } catch {
                            Write-Warn "Could not read state file: $($_.Exception.Message)"
                            Wait-ForKey; continue
                        }

                        if (-not $stateData.InstalledVersion) {
                            Write-Warn "State file is missing version info. Run an update first."
                            Wait-ForKey; continue
                        }

                        $configTag = $stateData.InstalledVersion
                        Write-Info "Comparing against config defaults from: $($configTag -replace 'nightly-', '' -replace 'experimental-', '')"

                        $releaseInfo = Get-NightlyReleaseInfo -ConfigTag $configTag
                        if (-not $releaseInfo -or -not $releaseInfo.ZipUrl) {
                            Write-Warn "Could not find config zip URL for $configTag."
                            Wait-ForKey; continue
                        }

                        if (-not (Test-Path -LiteralPath $script:TempDir)) {
                            New-Item -Path $script:TempDir -ItemType Directory -Force | Out-Null
                        }
                        $tempZip = Join-Path $script:TempDir "config-scan-$configTag.zip"
                        $httpClient = $null
                        try {
                            $httpClient = [System.Net.Http.HttpClient]::new()
                            $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
                            $httpClient.Timeout = [TimeSpan]::FromMinutes(3)
                            $zipBytes = $httpClient.GetByteArrayAsync($releaseInfo.ZipUrl).Result
                            [System.IO.File]::WriteAllBytes($tempZip, $zipBytes)
                            $scanZipPath = $tempZip
                            Write-Info "Downloaded config zip ($([math]::Round($zipBytes.Length / 1MB, 1)) MB)"
                        }
                        catch {
                            Write-Warn "Could not download config zip: $($_.Exception.Message)"
                            Wait-ForKey; continue
                        }
                        finally {
                            if ($httpClient) { try { $httpClient.Dispose() } catch {} }
                        }
                    }
                } else {
                    # ── Stable: download pack zip ──────────────────────────────────────
                    if ([string]::IsNullOrEmpty($scanVersion)) {
                        Write-Warn "No installed version recorded for $scanTargetName. Set it in Settings > Update Preferences."
                        Wait-ForKey; continue
                    }

                    $releases = $script:CachedWebsiteReleases
                    if (-not $releases) {
                        Write-Info "Fetching release list..."
                        $releases = Get-WebsiteReleases -PackType ($Config.JavaVersion ?? 'java17')
                    }
                    $scanRelease = $releases | Where-Object { $_.Version -eq $scanVersion } | Select-Object -First 1
                    if (-not $scanRelease) {
                        Write-Warn "Could not find v$scanVersion in release list."
                        Wait-ForKey; continue
                    }

                    $scanZipUrl  = $scanTargetName -eq 'server' ? $scanRelease.ServerZipUrl  : $scanRelease.ClientZipUrl
                    $scanZipName = $scanTargetName -eq 'server' ? $scanRelease.ServerZipName : $scanRelease.ClientZipName
                    if (-not $scanZipUrl) {
                        Write-Warn "No zip URL found for v$scanVersion $scanTargetName."
                        Wait-ForKey; continue
                    }

                    $scanZipPath = Get-CachedFile -FileName $scanZipName
                    if ($scanZipPath) {
                        Write-Info "Using cached pack: $scanZipName"
                    } else {
                        if (-not (Test-Path -LiteralPath $script:TempDir)) {
                            New-Item -Path $script:TempDir -ItemType Directory -Force | Out-Null
                        }
                        $tempZip = Join-Path $script:TempDir $scanZipName
                        $dlResult = Invoke-FileDownload -Url $scanZipUrl -OutPath $tempZip -Description "v$scanVersion $scanTargetName pack"
                        if (-not $dlResult) {
                            Write-Warn "Download failed."
                            if (Test-Path -LiteralPath $tempZip) { try { Remove-Item -LiteralPath $tempZip -Force } catch {} }
                            Wait-ForKey; continue
                        }
                        $scanZipPath = $tempZip
                    }
                }

                try {
                    $added = Invoke-ConfigDiffDetection `
                        -BaselineZipPath $scanZipPath `
                        -InstancePath    $scanInstance `
                        -Config          $Config `
                        -Target          $scanTargetName
                    if ($added -eq 0) { Write-Info "No new changes detected." }
                }
                finally {
                    if ($tempZip -and (Test-Path -LiteralPath $tempZip)) {
                        try { Remove-Item -LiteralPath $tempZip -Force } catch {}
                    }
                }
                Wait-ForKey
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

function Get-ConfigFileKeys {
    <#
    .SYNOPSIS
        Parse a .cfg or .properties file into a flat hashtable of "section.path::key" => value.
    .DESCRIPTION
        Tracks full section path for nested sections (e.g., "general.rendering")
        to avoid key collisions when the same key name appears in different subsections.
    .PARAMETER FilePath
        Full path to the config file (used when Lines is not provided).
    .PARAMETER Lines
        Pre-read string array of lines (used when reading from a zip stream).
    .OUTPUTS
        Hashtable where keys are "section.path::key" (section is empty string for .properties).
    #>
    param(
        [string]$FilePath,
        [string[]]$Lines
    )

    $result = @{}
    if (-not $Lines) {
        try { $Lines = Get-Content -LiteralPath $FilePath -Encoding UTF8 -ErrorAction Stop }
        catch { return $result }
    }

    $sectionStack = @()
    foreach ($line in $Lines) {
        if ($line -match '^\s*#') { continue }  # Skip comments
        if ($line -match '^\s*"?([^"{}=#]+)"?\s*\{') {
            $sectionStack += $Matches[1].Trim()
        }
        elseif ($line -match '^\s*\}') {
            if ($sectionStack.Count -gt 0) {
                $sectionStack = @($sectionStack | Select-Object -SkipLast 1)
            }
        }
        elseif ($line -match '^\s*([BISD]:[^=]+?)\s*=\s*(.*)$') {
            $sectionPath = $sectionStack -join '.'
            $result["${sectionPath}::$($Matches[1].Trim())"] = $Matches[2].Trim()
        }
        elseif ($line -match '^\s*([a-zA-Z][\w\-\.]*)\s*=\s*(.*)$') {
            $sectionPath = $sectionStack -join '.'
            $result["${sectionPath}::$($Matches[1].Trim())"] = $Matches[2].Trim()
        }
    }
    return $result
}

function Get-ConfigKeysFromZip {
    <#
    .SYNOPSIS
        Read all patchable config files from a pack zip and return a hashtable of
        relPath => (hashtable of "section::key" => value).
    .PARAMETER ZipPath
        Full path to the pack zip file.
    .OUTPUTS
        Hashtable: "config/relative/path.cfg" => (hashtable of keys).
        Returns $null on failure.
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    $result = @{}
    $zip = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notmatch '(?:^|/)config/.*\.(cfg|properties)$') { continue }
            # Normalise to "config/relative/path.cfg" (strip any leading folders)
            # Handles single-nested (folder/config/...) and double-nested (folder/folder/config/...)
            $relPath = $entry.FullName -replace '^(.+/)?(?=config/)', ''
            # Also handle .minecraft wrapper: folder/.minecraft/config/...
            $relPath = $relPath -replace '^\.minecraft/', ''
            if ($relPath -notmatch '^config/') { continue }
            try {
                $stream = $entry.Open()
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
                $content = $reader.ReadToEnd()
                $reader.Dispose(); $stream.Dispose()
                $lines = $content -split "`r?`n"
                $result[$relPath] = Get-ConfigFileKeys -Lines $lines
            }
            catch { }
        }
    }
    catch {
        Write-Log "[DIFF] Failed to read zip for config baseline: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($zip) { try { $zip.Dispose() } catch {} }
    }
    return $result
}

function Invoke-ConfigDiffDetection {
    <#
    .SYNOPSIS
        Three-way diff (previous pack zip vs. current instance vs. new pack zip) to
        auto-detect user config changes and register them as patches.
    .DESCRIPTION
        BaselineZipPath  = previous pack zip (what the pack shipped last time)
        StagingZipPath   = new pack zip (what the pack ships now); pass $null or same
                           as BaselineZipPath when called from Re-scan (no new staging).
        For each key in the baseline:
          current == baseline            → user didn't change it, skip
          current != baseline, staging == baseline → user changed it → auto-register
          current != baseline, staging != baseline → conflict → prompt
          key absent from staging        → skip (pack removed it)
        Already-patched keys are always skipped.
    .PARAMETER BaselineZipPath
        Full path to the previous version's pack zip.
    .PARAMETER InstancePath
        Root path of the current instance.
    .PARAMETER StagingZipPath
        Full path to the new version's pack zip. Pass $null or same as BaselineZipPath
        for a manual re-scan where there is no new staging.
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Target
        'server' or 'client'.
    .OUTPUTS
        Number of new patches registered.
    #>
    param(
        [Parameter(Mandatory)][string]$BaselineZipPath,
        [Parameter(Mandatory)][string]$InstancePath,
        [string]$StagingZipPath,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateSet('server','client')][string]$Target
    )

    if ([string]::IsNullOrEmpty($StagingZipPath)) { $StagingZipPath = $BaselineZipPath }

    Write-Step "Analyzing config changes..."

    $baselineMap = Get-ConfigKeysFromZip -ZipPath $BaselineZipPath
    if ($null -eq $baselineMap) {
        Write-Warn "Could not read baseline zip for config diff — skipping detection."
        return 0
    }

    # Only read staging zip if it differs from baseline
    $stagingMap = if ($StagingZipPath -eq $BaselineZipPath) { $baselineMap } else {
        $m = Get-ConfigKeysFromZip -ZipPath $StagingZipPath
        if ($null -eq $m) { $baselineMap } else { $m }
    }

    # Build already-patched lookup
    $alreadyPatched = @{}
    foreach ($p in $Config.ConfigPatches) {
        $normFile = ($p.FilePath ?? '') -replace '[/\\]', '/'
        $alreadyPatched["${normFile}::$($p.Section ?? '')::$($p.Key)"] = $true
    }

    $newPatches   = @()
    $skippedCount = 0
    $conflicts    = @()

    foreach ($configRelPath in $baselineMap.Keys) {
        $currentFile = Join-Path $InstancePath ($configRelPath -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $currentFile)) { continue }

        $baselineKeys = $baselineMap[$configRelPath]
        $stagingKeys  = $stagingMap.ContainsKey($configRelPath) ? $stagingMap[$configRelPath] : $baselineKeys
        $currentKeys  = Get-ConfigFileKeys -FilePath $currentFile

        foreach ($compositeKey in $baselineKeys.Keys) {
            if (-not $stagingKeys.ContainsKey($compositeKey)) { continue }
            if (-not $currentKeys.ContainsKey($compositeKey))  { continue }

            $baseVal    = $baselineKeys[$compositeKey]
            $currentVal = $currentKeys[$compositeKey]
            $stagingVal = $stagingKeys[$compositeKey]

            if ($currentVal -eq $baseVal) { continue }

            $sepIdx  = $compositeKey.IndexOf('::')
            $section = $compositeKey.Substring(0, $sepIdx)
            $key     = $compositeKey.Substring($sepIdx + 2)

            # Skip version-tracking keys -- these are pack-managed and change every release
            $bareKey = $key -replace '^[BISD]:', ''
            if ($bareKey -match '(?i)^(version|modVersion|lastVersion|configVersion|schemaVersion|config_version|lastRunVersion|hasShownUpdateNotice|version_seen|firstLaunch|lastKnownVersion)$') { continue }
            # Also skip keys that contain common version/tracking patterns
            if ($bareKey -match '(?i)(Version$|_version$|\.version$|LastRun|FirstLaunch|UpdateNotice)') { continue }

            if ($alreadyPatched.ContainsKey("${configRelPath}::${section}::${key}")) {
                $skippedCount++
                continue
            }

            if ($stagingVal -eq $baseVal) {
                $newPatches += [PSCustomObject]@{
                    FilePath    = $configRelPath
                    Key         = $key
                    Value       = $currentVal
                    Description = ''
                    Target      = $Target
                    Section     = $section
                    Source      = 'auto'
                }
            }
            else {
                $conflicts += [PSCustomObject]@{
                    FilePath  = $configRelPath
                    Key       = $key
                    Section   = $section
                    YourValue = $currentVal
                    PackValue = $stagingVal
                }
            }
        }
    }

    # ── Report and register ───────────────────────────────────────────────────
    $totalNew = $newPatches.Count
    if ($totalNew -eq 0 -and $conflicts.Count -eq 0 -and $skippedCount -eq 0) { return 0 }

    Write-Host ""
    Write-Host "  -- Config Change Detection --" -ForegroundColor Cyan

    if ($totalNew -gt 0) {
        Write-Host "  $totalNew change(s) detected and saved as patch(es):" -ForegroundColor Green
        foreach ($p in $newPatches) {
            $secNote = $p.Section ? " [$($p.Section)]" : ''
            Write-Host "    + " -NoNewline -ForegroundColor Green
            Write-Host "$($p.FilePath)" -NoNewline -ForegroundColor White
            Write-Host "  $($p.Key)" -ForegroundColor Cyan
            Write-Host "      pack default: " -NoNewline -ForegroundColor DarkGray
            # Look up the baseline value for display
            $baseKey = "$($p.Section)::$($p.Key)"
            $baseVal = if ($baselineMap.ContainsKey($p.FilePath) -and $baselineMap[$p.FilePath].ContainsKey($baseKey)) {
                $baselineMap[$p.FilePath][$baseKey]
            } else { '(unknown)' }
            Write-Host "$baseVal" -NoNewline -ForegroundColor DarkGray
            Write-Host "  ->  yours: " -NoNewline -ForegroundColor Gray
            Write-Host "$($p.Value)" -ForegroundColor Green
            Write-Log "[DIFF] Auto-registered patch: $($p.FilePath) | $($p.Key) = $($p.Value) (was: $baseVal)"
        }
        foreach ($p in $newPatches) { $Config.ConfigPatches += $p }
        Save-Config -Config $Config
    }

    if ($skippedCount -gt 0) {
        Write-Host "  $skippedCount key(s) already covered by existing patches (skipped)" -ForegroundColor DarkGray
    }

    foreach ($conflict in $conflicts) {
        Write-Host ""
        Write-Host "  Conflict: " -NoNewline -ForegroundColor Yellow
        Write-Host "$($conflict.FilePath)  $($conflict.Key)" -ForegroundColor White
        $secNote = $conflict.Section ? " [$($conflict.Section)]" : ''
        Write-Host "    Your value:       " -NoNewline -ForegroundColor Cyan
        Write-Host "$($conflict.YourValue)$secNote" -ForegroundColor Cyan
        Write-Host "    Pack's new value: " -NoNewline -ForegroundColor DarkYellow
        Write-Host "$($conflict.PackValue)" -ForegroundColor DarkYellow
        Write-Host ""
        Write-MenuOption 'K' "Keep yours ($($conflict.YourValue)) and save as patch"
        Write-MenuOption 'U' "Use pack's value ($($conflict.PackValue))"
        Write-MenuOption 'S' 'Skip (pack wins this update, no patch saved)'

        $choice = Read-MenuChoice 'Choose'
        switch ($choice.ToUpper()) {
            'K' {
                $Config.ConfigPatches += [PSCustomObject]@{
                    FilePath    = $conflict.FilePath
                    Key         = $conflict.Key
                    Value       = $conflict.YourValue
                    Description = ''
                    Target      = $Target
                    Section     = $conflict.Section
                    Source      = 'auto'
                }
                Save-Config -Config $Config
                $totalNew++
                Write-Log "[DIFF] Conflict resolved (kept mine): $($conflict.FilePath) | $($conflict.Key) = $($conflict.YourValue)"
            }
            'U' { Write-Log "[DIFF] Conflict resolved (used pack's): $($conflict.FilePath) | $($conflict.Key) = $($conflict.PackValue)" }
            default { Write-Log "[DIFF] Conflict skipped: $($conflict.FilePath) | $($conflict.Key)" }
        }
    }

    Write-Log "[DIFF] Detection complete: $totalNew new patch(es), $($conflicts.Count) conflict(s), $skippedCount skipped"
    Write-Host ""
    return $totalNew
}