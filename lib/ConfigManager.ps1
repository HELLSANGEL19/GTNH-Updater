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
        AutoCheckUpdates       = $true
        ConfigPatches          = @()
        UpdateHistory          = @()
        ConfigVersion          = 2
        LastSeenScriptVersion  = ''
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
        Serialize config object to JSON and write to disk.
    .PARAMETER Config
        The config PSCustomObject to save.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    try {
        $json = $Config | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $script:ConfigPath -Value $json -Encoding UTF8 -Force
    }
    catch {
        Write-Err "Failed to save config: $($_.Exception.Message)"
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

    # Ensure array fields are actually arrays (protects against corrupt config)
    $arrayFields = @('CustomServerMods', 'CustomClientMods', 'ConfigPatches', 'UpdateHistory')
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

    # Ensure numeric fields are integers
    if ($Config.BackupRetention -isnot [int]) {
        $parsed = 0
        if ([int]::TryParse("$($Config.BackupRetention)", [ref]$parsed) -and $parsed -gt 0) {
            $Config.BackupRetention = $parsed
        } else {
            $Config.BackupRetention = 5
        }
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
    Write-Info "Nightly updater ver:  $($Config.NightlyUpdaterVersion ? $Config.NightlyUpdaterVersion : '(not installed)')"
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
        Import a config from a specified file path.
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
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
        $config = Repair-Config -Config $config
        Write-Success "Config imported from: $ImportPath"
        return $config
    }
    catch {
        Write-Err "Failed to import config: $($_.Exception.Message)"
        return $null
    }
}
