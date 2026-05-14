# ============================================================================
# Group 3: Config Management - Load, save, validate, and display configuration
# ============================================================================
# Functions:
#   New-DefaultConfig   - Create a fresh PSCustomObject with all default values
#   Load-Config         - Read and parse gtnh-updater-config.json, handle
#                          invalid JSON with specific parse error message
#   Save-Config         - Serialize config object to JSON (Depth 5) and write to disk
#   Repair-Config     - Check for missing fields, add defaults, warn about each
#   Show-CurrentConfig  - Display all current settings in formatted output
#   Export-ConfigFile   - Export config to a specified file path
#   Import-ConfigFile   - Import config from a specified file path
#   Get-ProfileList     - Return all profile config files as structured objects
#   Switch-Profile      - Point $script:ConfigPath at a profile, return loaded config
#
# Config schema version: 2
# All fields are top-level in the JSON - no deep nesting beyond arrays of objects.
# ============================================================================

function New-DefaultConfig {
    <#
    .SYNOPSIS
        Create and return a fresh PSCustomObject with all default config fields.
    #>
    return [PSCustomObject]@{
        ServerPath             = ''
        ClientInstancePath     = ''
        JavaPath               = ''
        DefaultChannel         = 'stable'
        JavaVersion            = 'java17'
        BackupEnabled          = $false
        BackupDir              = Join-Path $script:ScriptDir 'backups'
        BackupRetention        = 5
        InstalledServerVersion = ''
        InstalledClientVersion = ''
        NightlyUpdaterVersion  = ''
        CustomServerMods       = @()
        CustomClientMods       = @()
        OverrideServerMods     = @()
        OverrideClientMods     = @()
        AutoCheckUpdates       = $true
        ConfigPatches          = @()
        UpdateHistory          = @()
        ConfigVersion          = 2
        LastSeenScriptVersion  = ''
        ProfileLabel           = ''
        LastUpdateTarget       = ''
    }
}

function Load-Config {
    <#
    .SYNOPSIS
        Read and parse gtnh-updater-config.json. Returns the parsed object or $null.
    .DESCRIPTION
        If the file doesn't exist, returns $null.
        If JSON is invalid, displays the parse error, offers to back up the broken
        file and re-run setup.
    #>
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warn "Config file is empty. It may have been corrupted."
            return $null
        }
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
        return $config
    }
    catch {
        Write-Err "Failed to parse config file: $($_.Exception.Message)"

        if (Confirm-Action "Back up the broken config and re-run setup?") {
            $backupName = "gtnh-updater-config.broken-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $backupPath = Join-Path $script:ScriptDir $backupName
            try {
                Copy-Item -LiteralPath $script:ConfigPath -Destination $backupPath -Force
                Write-Success "Broken config backed up to: $backupName"
            }
            catch {
                Write-Warn "Could not back up broken config: $($_.Exception.Message)"
            }
        }

        return $null
    }
}

function Save-Config {
    <#
    .SYNOPSIS
        Serialize config object to JSON and write to disk atomically.
    .DESCRIPTION
        Uses write-to-temp-then-rename pattern to prevent corruption if the
        process is interrupted mid-write. The rename operation is atomic on
        both Windows (NTFS) and Linux (ext4/xfs/btrfs).
    .PARAMETER Config
        The config PSCustomObject to save.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    try {
        $json = $Config | ConvertTo-Json -Depth 10
        $tempPath = "$($script:ConfigPath).tmp"
        Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -Force
        # Atomic rename (overwrites destination on both Windows and Linux)
        Move-Item -LiteralPath $tempPath -Destination $script:ConfigPath -Force
    }
    catch {
        Write-Err "Failed to save config: $($_.Exception.Message)"
        # Clean up temp file if rename failed
        $tempPath = "$($script:ConfigPath).tmp"
        if (Test-Path -LiteralPath $tempPath) {
            try { Remove-Item -LiteralPath $tempPath -Force } catch {}
        }
    }
}

function Repair-Config {
    <#
    .SYNOPSIS
        Check for missing fields in a config object, add defaults, warn about each.
    .PARAMETER Config
        The config PSCustomObject to validate and repair.
    .OUTPUTS
        The repaired config object with all expected fields present.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $defaults = New-DefaultConfig
    $defaultProperties = $defaults.PSObject.Properties

    $repaired = $false
    foreach ($prop in $defaultProperties) {
        if (-not ($Config.PSObject.Properties.Name -contains $prop.Name)) {
            Write-Warn "Config missing field '$($prop.Name)' - adding default value."
            $Config | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            $repaired = $true
        }
    }

    # Expand ~ in path fields (Linux users may have saved tilde paths)
    foreach ($field in @('ServerPath', 'ClientInstancePath', 'JavaPath', 'BackupDir')) {
        $val = $Config.$field
        if ($val -match '^~[/\\]') { $Config.$field = $val -replace '^~', $HOME; $repaired = $true }
        elseif ($val -eq '~') { $Config.$field = $HOME; $repaired = $true }
    }

    # Ensure array fields are actually arrays (protects against corrupt config)
    $arrayFields = @('CustomServerMods', 'CustomClientMods', 'OverrideServerMods', 'OverrideClientMods', 'ConfigPatches', 'UpdateHistory')
    foreach ($field in $arrayFields) {
        $val = $Config.$field
        if ($null -eq $val) {
            $Config.$field = @()
            $repaired = $true
        }
        elseif ($val -isnot [System.Collections.IEnumerable] -or $val -is [string]) {
            Write-Warn "Config field '$field' has wrong type - resetting to empty array."
            $Config.$field = @()
            $repaired = $true
        }
    }

    # Clean mod arrays: remove null, empty, or whitespace-only entries
    foreach ($field in @('CustomServerMods', 'CustomClientMods', 'OverrideServerMods', 'OverrideClientMods')) {
        $arr = @($Config.$field)
        $cleaned = @($arr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($cleaned.Count -ne $arr.Count) {
            $Config.$field = $cleaned
            $repaired = $true
            Write-Log "[REPAIR] Removed $($arr.Count - $cleaned.Count) invalid entries from $field"
        }
    }

    # Ensure numeric fields are integers with reasonable bounds
    if ($Config.BackupRetention -isnot [int]) {
        $parsed = 0
        if ([int]::TryParse("$($Config.BackupRetention)", [ref]$parsed) -and $parsed -gt 0) {
            $Config.BackupRetention = [math]::Min($parsed, 50)
        } else {
            $Config.BackupRetention = 5
        }
        $repaired = $true
    }
    elseif ($Config.BackupRetention -gt 50) {
        Write-Warn "BackupRetention was $($Config.BackupRetention) - capping at 50."
        $Config.BackupRetention = 50
        $repaired = $true
    }
    elseif ($Config.BackupRetention -lt 1) {
        $Config.BackupRetention = 1
        $repaired = $true
    }

    if ($repaired) {
        Save-Config -Config $Config
        Write-Success "Configuration saved."
    }

    # Warn if server and client paths are the same
    if (-not [string]::IsNullOrEmpty($Config.ServerPath) -and
        -not [string]::IsNullOrEmpty($Config.ClientInstancePath) -and
        $Config.ServerPath -eq $Config.ClientInstancePath) {
        Write-Warn "Server and client paths are the same! This will cause problems during updates."
        Write-Warn "Fix this in Settings > Instance Paths."
    }

    return $Config
}

function Show-CurrentConfig {
    <#
    .SYNOPSIS
        Display all current settings in formatted output.
    .PARAMETER Config
        The config PSCustomObject to display.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    Write-Header "Current Configuration"

    Write-Info "Server path:          $($Config.ServerPath ? $Config.ServerPath : '(not set)')"
    Write-Info "Client path:          $($Config.ClientInstancePath ? $Config.ClientInstancePath : '(not set)')"
    Write-Info "Java path:            $($Config.JavaPath ? $Config.JavaPath : '(not set)')"
    Write-Info "Default channel:      $($Config.DefaultChannel ?? 'stable')"
    Write-Info "Pack type:            $(if (($Config.JavaVersion ?? 'java17') -eq 'java17') { 'Java 17+' } else { 'Java 8' })"
    Write-Info "Backup enabled:       $($Config.BackupEnabled ? 'Yes' : 'No')"
    Write-Info "Backup directory:     $($Config.BackupDir ? $Config.BackupDir : '(default)')"
    Write-Info "Backup retention:     $($Config.BackupRetention ?? 5)"
    Write-Info "Server version:       $($Config.InstalledServerVersion ? $Config.InstalledServerVersion : '(unknown)')"
    Write-Info "Client version:       $($Config.InstalledClientVersion ? $Config.InstalledClientVersion : '(unknown)')"
    Write-Info "Daily updater ver:    (native - no external binary needed)"
    Write-Info "Custom server mods:   $($Config.CustomServerMods.Count) configured"
    Write-Info "Custom client mods:   $($Config.CustomClientMods.Count) configured"
    Write-Info "Config patches:       $($Config.ConfigPatches.Count) defined"
    Write-Info "Log directory:        $($script:LogDir)"
}

function Export-ConfigFile {
    <#
    .SYNOPSIS
        Export the current config to a specified file path.
    .PARAMETER Config
        The config PSCustomObject to export.
    .PARAMETER ExportPath
        The destination file path.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$ExportPath
    )

    try {
        $json = $Config | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $ExportPath -Value $json -Encoding UTF8 -Force
        Write-Success "Config exported to: $ExportPath"
        return $true
    }
    catch {
        Write-Err "Failed to export config: $($_.Exception.Message)"
        return $false
    }
}

function Import-ConfigFile {
    <#
    .SYNOPSIS
        Import a config from a specified file path with validation.
    .PARAMETER ImportPath
        The source file path to import from.
    .OUTPUTS
        The imported config PSCustomObject, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$ImportPath
    )

    if (-not (Test-Path -LiteralPath $ImportPath)) {
        Write-Err "Import file not found: $ImportPath"
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $ImportPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Err "Import file is empty."
            return $null
        }
        $config = $raw | ConvertFrom-Json -ErrorAction Stop

        # Validate the imported object looks like a GTNH updater config
        # (must have at least one of the core fields to be a valid config)
        $coreFields = @('ServerPath', 'ClientInstancePath', 'DefaultChannel', 'JavaVersion')
        $hasCore = $false
        foreach ($field in $coreFields) {
            if ($config.PSObject.Properties.Name -contains $field) {
                $hasCore = $true
                break
            }
        }
        if (-not $hasCore) {
            Write-Err "File does not appear to be a GTNH Updater config (missing expected fields)."
            return $null
        }

        # Warn about paths that may not exist on this machine
        $pathWarnings = @()
        foreach ($field in @('ServerPath', 'ClientInstancePath', 'JavaPath')) {
            $val = $config.$field
            if (-not [string]::IsNullOrEmpty($val) -and -not (Test-Path -LiteralPath $val)) {
                $pathWarnings += "$field`: $val"
            }
        }
        if ($pathWarnings.Count -gt 0) {
            Write-Warn "Some paths in the imported config don't exist on this machine:"
            foreach ($pw in $pathWarnings) {
                Write-Info "  $pw"
            }
            Write-Info "You can update them in Settings > Instance Paths."
        }

        $config = Repair-Config -Config $config
        Write-Success "Config imported from: $(Split-Path -Leaf $ImportPath)"
        return $config
    }
    catch {
        Write-Err "Failed to import config: $($_.Exception.Message)"
        return $null
    }
}

function Get-ProfileList {
    <#
    .SYNOPSIS
        Return all profile config files in ScriptDir.
    .OUTPUTS
        Array of @{ Name; Label; Path; IsDefault } sorted: default first, then alpha.
    #>
    $profiles = @()

    $defaultPath = Join-Path $script:ScriptDir 'gtnh-updater-config.json'
    if (Test-Path -LiteralPath $defaultPath) {
        $label = ''
        try { $label = ((Get-Content -LiteralPath $defaultPath -Raw | ConvertFrom-Json).ProfileLabel ?? '') } catch {}
        $profiles += [PSCustomObject]@{ Name = 'default'; Label = $label; Path = $defaultPath; IsDefault = $true }
    }

    Get-ChildItem -LiteralPath $script:ScriptDir -Filter 'gtnh-updater-config-*.json' -File |
        Sort-Object Name |
        ForEach-Object {
            if ($_.Name -match '^gtnh-updater-config-(.+)\.json$') {
                $name = $Matches[1]
                $label = ''
                try { $label = ((Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).ProfileLabel ?? '') } catch {}
                $profiles += [PSCustomObject]@{ Name = $name; Label = $label; Path = $_.FullName; IsDefault = $false }
            }
        }

    return $profiles
}

function Switch-Profile {
    <#
    .SYNOPSIS
        Point $script:ConfigPath at the given profile and return the loaded+repaired config.
    .PARAMETER ProfileName
        'default' or a named profile slug (e.g. 'daily').
    .OUTPUTS
        The loaded config, or $null if the file doesn't exist yet.
    #>
    param([Parameter(Mandatory)][string]$ProfileName)

    $script:ConfigPath = if ($ProfileName -eq 'default') {
        Join-Path $script:ScriptDir 'gtnh-updater-config.json'
    } else {
        Join-Path $script:ScriptDir "gtnh-updater-config-$ProfileName.json"
    }

    # Clear cached data that may be stale for the new profile's settings
    $script:CachedWebsiteReleases = $null
    $script:CachedLatestVersion = $null
    $script:CachedLatestBeta = $null
    $script:CachedLatestNightly = $null
    $script:CachedNightlyLastUpdated = $null
    $script:GitHubETagCache = @{}

    $config = Load-Config
    if ($null -ne $config) { $config = Repair-Config -Config $config }
    return $config
}
