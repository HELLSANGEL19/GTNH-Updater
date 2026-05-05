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
        $lines = Get-Content -LiteralPath $fullPath -Encoding UTF8
        $found = $false

        # Escape special regex characters in the key
        $escapedKey = [regex]::Escape($Key)
        $pattern = "^\s*${escapedKey}\s*="

        # Track current section for section-scoped matching
        $currentSection = ''
        $inTargetSection = [string]::IsNullOrEmpty($Section)

        for ($i = 0; $i -lt $lines.Count; $i++) {
            # Track section headers
            if ($lines[$i] -match '^\s*"?([^"{}=#]+)"?\s*\{') {
                $currentSection = $Matches[1].Trim()
                if (-not [string]::IsNullOrEmpty($Section)) {
                    $inTargetSection = $currentSection -eq $Section
                }
            }

            if ($inTargetSection -and $lines[$i] -match $pattern) {
                # Preserve leading whitespace
                $leadingWhitespace = ''
                if ($lines[$i] -match '^(\s*)') {
                    $leadingWhitespace = $Matches[1]
                }
                $lines[$i] = "${leadingWhitespace}${Key}=${Value}"
                $found = $true
                break
            }
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
            $lines = Get-Content -LiteralPath $fullPath -Encoding UTF8
            $escapedKey = [regex]::Escape($patch.Key)
            $pattern = "^\s*${escapedKey}\s*="
            $keyFound = $false

            $currentSection = ''
            $inTargetSection = [string]::IsNullOrEmpty($patch.Section)

            foreach ($line in $lines) {
                if ($line -match '^\s*"?([^"{}=#]+)"?\s*\{') {
                    $currentSection = $Matches[1].Trim()
                    if (-not [string]::IsNullOrEmpty($patch.Section)) {
                        $inTargetSection = $currentSection -eq $patch.Section
                    }
                }
                if ($inTargetSection -and $line -match $pattern) {
                    $keyFound = $true
                    break
                }
            }

            if (-not $keyFound) {
                $sectionNote = $patch.Section ? " in section '$($patch.Section)'" : ''
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

    Write-Step "Applying $($validPatches.Count) config patch(es) for $Target..."

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

        $lines = Get-Content -LiteralPath $fullPath -Encoding UTF8
        $escapedKey = [regex]::Escape($patch.Key)
        $pattern = "^\s*${escapedKey}\s*="
        $currentValue = '(not found)'
        $currentSection = ''
        $inTargetSection = [string]::IsNullOrEmpty($patch.Section)

        foreach ($line in $lines) {
            if ($line -match '^\s*"?([^"{}=#]+)"?\s*\{') {
                $currentSection = $Matches[1].Trim()
                if (-not [string]::IsNullOrEmpty($patch.Section)) {
                    $inTargetSection = $currentSection -eq $patch.Section
                }
            }
            if ($inTargetSection -and $line -match $pattern) {
                $currentValue = ($line -split '=', 2)[1].Trim()
                break
            }
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

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Track section headers (lines with just a word and {)
        if ($line -match '^\s*"?([^"{}=#]+)"?\s*\{') {
            $currentSection = $Matches[1].Trim()
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
                $tag = "[$($i + 1)]".PadLeft($tagWidth)
                Write-Host "  $tag " -NoNewline -ForegroundColor White
                Write-Host "$($p.Description ?? $p.Key)" -NoNewline -ForegroundColor Cyan
                Write-Host " [$targetLabel]" -ForegroundColor DarkGray
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
                    $patch | Add-Member -NotePropertyName 'Target' -NotePropertyValue 'both'

                    $Config.ConfigPatches += $patch
                    Save-Config -Config $Config
                    Write-Success "Patch added: $($patch.Key) = $($patch.Value) [server+client]"
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
                            $Config.ConfigPatches += [PSCustomObject]@{
                                FilePath    = $t.FilePath
                                Key         = $t.Key
                                Value       = $t.Value
                                Description = $t.Description
                                Target      = 'both'
                            }
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

                            $Config.ConfigPatches += [PSCustomObject]@{
                                FilePath    = $selected.FilePath
                                Key         = $selected.Key
                                Value       = $selected.Value
                                Description = $selected.Description
                                Target      = $tTargetValue
                            }
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
            'R' {
                return
            }
            default {
                Write-Warn "Invalid option. Please try again."
            }
        }
    }
}
