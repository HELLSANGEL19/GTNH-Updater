# ============================================================================
# Group 17: Menu System & Main Loop - Interactive navigation and dispatch
# ============================================================================
# Functions:
#   Show-MainMenu            - Display ASCII banner, main menu with options
#                               [1]-[5], and [Q], show current server/client
#                               versions and paths, version mismatch warning
#   Invoke-TargetSelection   - Prompt for update target: [1] Server only,
#                               [2] Client only, [3] Both.
#   Invoke-SettingsMenu      - Top-level settings menu with grouped sub-menus
#   Invoke-InstancePathsMenu - Sub-menu for server/client/Java paths
#   Invoke-UpdatePreferencesMenu - Sub-menu for channel, Java version, etc.
#   Invoke-CustomModsMenu    - Sub-menu dispatching to server/client custom mods
#   Invoke-CustomModSettingsMenu - Sub-menu for managing custom mods (server or client)
#   Invoke-BackupsAndCacheMenu - Sub-menu for backup settings, backups, cache
#   Invoke-ExportImportMenu  - Sub-menu for config export/import
#   Invoke-ViewLogs          - List recent log files, offer to open folder
#   Invoke-ChangelogViewer   - Fetch and display GTNH changelog from GitHub
#   Invoke-ScriptUpdateCheck - Check for newer script version on GitHub
#   Invoke-VersionPicker     - Show version picker from pre-fetched releases
#                               (stable + beta/RC) for user selection
#   Invoke-UpdateHistory     - Display update history from config
#   Invoke-MainLoop          - Top-level loop: init logging -> load/validate
#                               config -> setup wizard if needed -> menu loop ->
#                               dispatch to sub-functions
# ============================================================================

function Show-MainMenu {
    <#
    .SYNOPSIS
        Display the main menu with banner, status, and options.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    Clear-Host
    Write-Banner

    # Show current status
    Write-Host ""
    $serverVer = $Config.InstalledServerVersion ? $Config.InstalledServerVersion : '(unknown)'
    $clientVer = $Config.InstalledClientVersion ? $Config.InstalledClientVersion : '(unknown)'
    $channel = $Config.DefaultChannel ?? 'stable'
    $latestStable = $script:CachedLatestVersion ? $script:CachedLatestVersion : '(not checked)'
    $isStableChannel = $channel -eq 'stable'

    # Determine what "latest" means for the current channel
    $latestForChannel = if ($isStableChannel) { $script:CachedLatestVersion } else { $script:CachedLatestNightly }

    # Normalize versions for comparison (trim whitespace, strip leading 'v')
    $normalizeVer = { param($v) if ($v) { $v.Trim().TrimStart('v', 'V') } else { $null } }

    # Server version display
    Write-Host "  Server:         " -NoNewline -ForegroundColor Gray
    $serverNorm = & $normalizeVer $Config.InstalledServerVersion
    $latestNorm = & $normalizeVer $latestForChannel
    if ($serverNorm -and $latestNorm -and $serverNorm -eq $latestNorm) {
        Write-Host "$serverVer " -NoNewline -ForegroundColor Green
        Write-Host "(up to date)" -ForegroundColor DarkGreen
    } elseif ($isStableChannel -and $Config.InstalledServerVersion -match '^\d+\.\d+\.\d+$' -and $script:CachedLatestVersion -and $Config.InstalledServerVersion -ne $script:CachedLatestVersion) {
        Write-Host "$serverVer" -NoNewline -ForegroundColor Yellow
        Write-Host "  ->  $($script:CachedLatestVersion) available" -ForegroundColor DarkYellow
    } else {
        Write-Host "$serverVer" -ForegroundColor Green
    }

    # Client version display
    Write-Host "  Client:         " -NoNewline -ForegroundColor Gray
    $clientNorm = & $normalizeVer $Config.InstalledClientVersion
    if ($clientNorm -and $latestNorm -and $clientNorm -eq $latestNorm) {
        Write-Host "$clientVer " -NoNewline -ForegroundColor Green
        Write-Host "(up to date)" -ForegroundColor DarkGreen
    } elseif ($isStableChannel -and $Config.InstalledClientVersion -match '^\d+\.\d+\.\d+$' -and $script:CachedLatestVersion -and $Config.InstalledClientVersion -ne $script:CachedLatestVersion) {
        Write-Host "$clientVer" -NoNewline -ForegroundColor Yellow
        Write-Host "  ->  $($script:CachedLatestVersion) available" -ForegroundColor DarkYellow
    } else {
        Write-Host "$clientVer" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Latest stable:  " -NoNewline -ForegroundColor Gray
    Write-Host "$latestStable" -ForegroundColor Cyan
    if ($isStableChannel -and $script:CachedLatestBeta) {
        Write-Host "  Latest beta:    " -NoNewline -ForegroundColor Gray
        Write-Host "$($script:CachedLatestBeta)" -ForegroundColor DarkYellow
    }
    if (-not $isStableChannel -and $script:CachedLatestNightly) {
        Write-Host "  Latest daily:   " -NoNewline -ForegroundColor Gray
        Write-Host "$($script:CachedLatestNightly)" -ForegroundColor Magenta
    }
    Write-Host "  Channel:        " -NoNewline -ForegroundColor Gray
    Write-Host "$channel" -ForegroundColor $(if ($isStableChannel) { 'Cyan' } else { 'Magenta' })

    # Custom mods and patches summary (only show if any are configured)
    $serverModCount = ($Config.CustomServerMods ?? @()).Count
    $clientModCount = ($Config.CustomClientMods ?? @()).Count
    $patchCount = ($Config.ConfigPatches ?? @()).Count
    if ($serverModCount -gt 0 -or $clientModCount -gt 0 -or $patchCount -gt 0) {
        $summaryParts = @()
        if ($serverModCount -gt 0 -or $clientModCount -gt 0) {
            $modParts = @()
            if ($serverModCount -gt 0) { $modParts += "$serverModCount server" }
            if ($clientModCount -gt 0) { $modParts += "$clientModCount client" }
            $summaryParts += "Mods: $($modParts -join ', ')"
        }
        if ($patchCount -gt 0) {
            $summaryParts += "Patches: $patchCount"
        }
        Write-Host "  Custom:         " -NoNewline -ForegroundColor Gray
        Write-Host ($summaryParts -join '  |  ') -ForegroundColor DarkCyan
    }

    # Version mismatch warning
    Show-VersionMismatchWarning -Config $Config

    # Divider between status and menu
    Write-Host ""
    Write-Host "  $('-' * 56)" -ForegroundColor DarkGray

    # Menu options
    Write-Host ""
    Write-MenuOption "1" "Update GTNH ($channel)"
    Write-MenuOption "2" "Settings"
    Write-MenuOption "3" "View logs"
    Write-MenuOption "4" "View GTNH changelog"
    Write-MenuOption "5" "Update history"
    Write-MenuOption "H" "Help"
    Write-Host ""
    Write-MenuOption "Q" "Quit"
}

function Invoke-TargetSelection {
    <#
    .SYNOPSIS
        Prompt for update target selection.
    .DESCRIPTION
        Asks user to choose [1] Server only, [2] Client only, [3] Both.
        Backup warnings are shown later in the engine, right before applying.
    .PARAMETER Config
        The config PSCustomObject.
    .OUTPUTS
        Hashtable @{ Server = $true/$false; Client = $true/$false }
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $result = @{ Server = $false; Client = $false }

    # Check what's configured
    $hasServer = -not [string]::IsNullOrEmpty($Config.ServerPath)
    $hasClient = -not [string]::IsNullOrEmpty($Config.ClientInstancePath)

    if (-not $hasServer -and -not $hasClient) {
        Write-Err "No server or client paths configured. Run setup wizard first."
        Wait-ForKey
        return $result
    }

    Write-Header "Select Update Target"
    Write-Host ""

    if ($hasServer) { Write-MenuOption "1" "Server only" }
    if ($hasClient) { Write-MenuOption "2" "Client only" }
    if ($hasServer -and $hasClient) { Write-MenuOption "3" "Both server and client" }
    Write-MenuOption "R" "Return to main menu"

    $choice = Read-MenuChoice "Select target"

    switch ($choice) {
        '1' {
            if (-not $hasServer) {
                Write-Err "No server path configured."
                Wait-ForKey
                return $result
            }
            $result.Server = $true
        }
        '2' {
            if (-not $hasClient) {
                Write-Err "No client path configured."
                Wait-ForKey
                return $result
            }
            $result.Client = $true
        }
        '3' {
            if (-not $hasServer -or -not $hasClient) {
                Write-Err "Both server and client paths must be configured for this option."
                Wait-ForKey
                return $result
            }
            $result.Server = $true
            $result.Client = $true
        }
        { $_ -eq 'R' -or $_ -eq 'r' } {
            return $result
        }
        default {
            Write-Err "Invalid selection."
            Wait-ForKey
            return $result
        }
    }

    return $result
}

function Invoke-SettingsMenu {
    <#
    .SYNOPSIS
        Settings menu with grouped sub-menus for all configuration options.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Settings"

        Write-MenuOption "1" "Instance paths"
        Write-MenuOption "2" "Update preferences"
        Write-MenuOption "3" "Custom mods"
        Write-MenuOption "4" "Config patches"
        Write-MenuOption "5" "Backups and cache"
        Write-MenuOption "6" "Re-run setup wizard"
        Write-MenuOption "7" "Export/Import config"
        Write-Host ""
        Write-MenuOption "R" "Return to main menu"

        $choice = Read-MenuChoice "Select setting"

        switch ($choice) {
            '1' {
                Invoke-InstancePathsMenu -Config $Config
            }
            '2' {
                Invoke-UpdatePreferencesMenu -Config $Config
            }
            '3' {
                Invoke-CustomModsMenu -Config $Config
            }
            '4' {
                Invoke-ConfigPatchMenu -Config $Config
            }
            '5' {
                Invoke-BackupsAndCacheMenu -Config $Config
            }
            '6' {
                Write-Info "Re-running setup wizard..."
                $Config = Invoke-InteractiveSetup -ExistingConfig $Config
                Wait-ForKey
            }
            '7' {
                Invoke-ExportImportMenu -Config $Config
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-InstancePathsMenu {
    <#
    .SYNOPSIS
        Sub-menu for managing instance paths (server, client, Java).
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Settings > Instance Paths"

        $serverPath = $Config.ServerPath ? $Config.ServerPath : '(not set)'
        $clientPath = $Config.ClientInstancePath ? $Config.ClientInstancePath : '(not set)'
        $javaPath = $Config.JavaPath ? $Config.JavaPath : '(not set)'

        Write-Host "  Server: " -NoNewline -ForegroundColor Gray
        Write-Host "$serverPath" -ForegroundColor Cyan
        Write-Host "  Client: " -NoNewline -ForegroundColor Gray
        Write-Host "$clientPath" -ForegroundColor Cyan
        Write-Host "  Java:   " -NoNewline -ForegroundColor Gray
        Write-Host "$javaPath" -ForegroundColor Cyan
        Write-Host ""

        Write-MenuOption "1" "Server path"
        Write-MenuOption "2" "Client path"
        Write-MenuOption "3" "Java path (for daily/experimental updates)"
        Write-Host ""
        Write-MenuOption "R" "Return"

        $choice = Read-MenuChoice "Select option"

        switch ($choice) {
            '1' {
                Write-Host '  Example: E:\AMPDatastore\Instances\GTNH01\Minecraft' -ForegroundColor Cyan
                Write-Host '  Example: D:\Games\GTNH\server' -ForegroundColor Cyan
                $newPath = Read-UserInput "Enter new server path" -Default $Config.ServerPath
                if ($newPath -and (Test-Path -LiteralPath $newPath)) {
                    if (Test-GtnhPath -Path $newPath -Target 'server') {
                        $Config.ServerPath = $newPath
                        Save-Config -Config $Config
                        Write-Success "Server path updated."
                    }
                }
                elseif ($newPath) {
                    Write-Err "Path not found: $newPath"
                }
                Wait-ForKey
            }
            '2' {
                Write-Host '  Example: C:\Users\You\AppData\Roaming\PrismLauncher\instances\GTNH\.minecraft' -ForegroundColor Cyan
                Write-Host '  Example: D:\MultiMC\instances\GTNH\.minecraft' -ForegroundColor Cyan
                Write-Info "Must point to the .minecraft folder, not the instance root."
                $newPath = Read-UserInput "Enter new client .minecraft path" -Default $Config.ClientInstancePath
                if ($newPath -and (Test-Path -LiteralPath $newPath)) {
                    if (Test-GtnhPath -Path $newPath -Target 'client') {
                        $Config.ClientInstancePath = $newPath
                        Save-Config -Config $Config
                        Write-Success "Client path updated."
                    }
                }
                elseif ($newPath) {
                    Write-Err "Path not found: $newPath"
                }
                Wait-ForKey
            }
            '3' {
                Write-Host '  Example: C:\Program Files\Java\jdk-21\bin\java.exe' -ForegroundColor Cyan
                Write-Host '  Example: C:\Program Files\Eclipse Adoptium\jdk-21\bin\java.exe' -ForegroundColor Cyan
                $newPath = Read-UserInput "Enter full path to java.exe" -Default $Config.JavaPath
                if ($newPath) {
                    if (-not ($newPath -match '[/\\]java\.exe$')) {
                        Write-Warn "Path should end with java.exe (not javaw.exe or a folder)."
                    }
                    if (Test-Path -LiteralPath $newPath) {
                        $Config.JavaPath = $newPath
                        Save-Config -Config $Config
                        Write-Success "Java path updated."
                    } else {
                        Write-Err "Path not found: $newPath"
                    }
                }
                Wait-ForKey
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-UpdatePreferencesMenu {
    <#
    .SYNOPSIS
        Sub-menu for update preferences (channel, Java version, installed version, auto-check).
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Settings > Update Preferences"

        $channel = $Config.DefaultChannel ?? 'stable'
        $javaVer = $Config.JavaVersion ?? 'java17'
        $serverVer = $Config.InstalledServerVersion ? $Config.InstalledServerVersion : '(unknown)'
        $clientVer = $Config.InstalledClientVersion ? $Config.InstalledClientVersion : '(unknown)'
        $autoCheck = ($Config.AutoCheckUpdates ?? $true) ? 'Yes' : 'No'

        Write-Host "  Channel:        " -NoNewline -ForegroundColor Gray
        Write-Host "$channel" -ForegroundColor Cyan
        Write-Host "  Java version:   " -NoNewline -ForegroundColor Gray
        Write-Host "$javaVer" -ForegroundColor Cyan
        Write-Host "  Server version: " -NoNewline -ForegroundColor Gray
        Write-Host "$serverVer" -ForegroundColor Cyan
        Write-Host "  Client version: " -NoNewline -ForegroundColor Gray
        Write-Host "$clientVer" -ForegroundColor Cyan
        Write-Host "  Auto-check:     " -NoNewline -ForegroundColor Gray
        Write-Host "$autoCheck" -ForegroundColor Cyan
        Write-Host ""

        Write-MenuOption "1" "Default update channel"
        Write-MenuOption "2" "Java version for downloads (17+ or 8)"
        Write-MenuOption "3" "Set installed GTNH version"
        Write-MenuOption "4" "Auto-update check on/off"
        Write-Host ""
        Write-MenuOption "R" "Return"

        $choice = Read-MenuChoice "Select option"

        switch ($choice) {
            '1' {
                Write-Info "Select default channel:"
                Write-MenuOption "1" "Stable"
                Write-MenuOption "2" "Daily"
                Write-MenuOption "3" "Experimental"
                $ch = Read-MenuChoice "Channel"
                $Config.DefaultChannel = switch ($ch) {
                    '1' { 'stable' }
                    '2' { 'daily' }
                    '3' { 'experimental' }
                    default { $Config.DefaultChannel }
                }
                Save-Config -Config $Config
                Write-Success "Default channel set to: $($Config.DefaultChannel)"
                Wait-ForKey
            }
            '2' {
                Write-Info "Select server pack type:"
                Write-MenuOption "1" "Java 17+ (recommended)"
                Write-MenuOption "2" "Java 8 (legacy)"
                $pt = Read-MenuChoice "Pack type"
                $Config.JavaVersion = switch ($pt) {
                    '1' { 'java17' }
                    '2' { 'java8' }
                    default { $Config.JavaVersion }
                }
                Save-Config -Config $Config
                Write-Success "Server pack type set to: $($Config.JavaVersion)"
                Wait-ForKey
            }
            '3' {
                Write-Header "Set Installed Version"
                Write-Info "Tell the updater what GTNH version you are currently running."
                Write-Info "Server: $($Config.InstalledServerVersion ? $Config.InstalledServerVersion : '(unknown)')"
                Write-Info "Client: $($Config.InstalledClientVersion ? $Config.InstalledClientVersion : '(unknown)')"

                # Try auto-detection
                $serverDetected = $null
                $clientDetected = $null
                if (-not [string]::IsNullOrEmpty($Config.ServerPath)) {
                    $serverDetected = Get-InstalledGtnhVersion -InstancePath $Config.ServerPath
                    if ($serverDetected -eq 'unknown') { $serverDetected = $null }
                }
                if (-not [string]::IsNullOrEmpty($Config.ClientInstancePath)) {
                    $clientDetected = Get-InstalledGtnhVersion -InstancePath $Config.ClientInstancePath
                    if ($clientDetected -eq 'unknown') { $clientDetected = $null }
                }

                if ($serverDetected -or $clientDetected) {
                    Write-Host ""
                    if ($serverDetected) {
                        Write-Success "Detected server version: $serverDetected"
                    }
                    if ($clientDetected) {
                        Write-Success "Detected client version: $clientDetected"
                    }
                    Write-Host ""
                    Write-MenuOption "A" "Accept detected version(s)"
                    Write-MenuOption "M" "Enter manually"
                    Write-MenuOption "R" "Cancel"
                    $detectChoice = Read-MenuChoice "Choose"

                    if ($detectChoice -eq 'a' -or $detectChoice -eq 'A') {
                        if ($serverDetected) {
                            $Config.InstalledServerVersion = $serverDetected
                        }
                        if ($clientDetected) {
                            $Config.InstalledClientVersion = $clientDetected
                        }
                        Save-Config -Config $Config
                        Write-Success "Version(s) updated from auto-detection."
                        Wait-ForKey
                        continue
                    }
                    if ($detectChoice -eq 'r' -or $detectChoice -eq 'R') {
                        Wait-ForKey
                        continue
                    }
                    # Fall through to manual entry for 'M'
                }

                Write-Host ""
                Write-Host '  Example: 2.8.4' -ForegroundColor Cyan
                Write-Host '  Example: 2.8.0-beta-4' -ForegroundColor Cyan
                $newVer = Read-UserInput "GTNH version"
                if ($newVer -and $newVer -notmatch '^\d+\.\d+') {
                    Write-Warn "That doesn't look like a version number. Expected format: X.Y.Z"
                }
                if ($newVer) {
                    Write-Info "Apply to: [1] Server, [2] Client, [3] Both"
                    $verTarget = Read-MenuChoice "Target"
                    if ($verTarget -eq '1' -or $verTarget -eq '3') {
                        $Config.InstalledServerVersion = $newVer
                    }
                    if ($verTarget -eq '2' -or $verTarget -eq '3') {
                        $Config.InstalledClientVersion = $newVer
                    }
                    Save-Config -Config $Config
                    Write-Success "Version updated."
                }
                Wait-ForKey
            }
            '4' {
                $Config.AutoCheckUpdates = -not ($Config.AutoCheckUpdates ?? $true)
                Save-Config -Config $Config
                Write-Success "Auto-update check $($Config.AutoCheckUpdates ? 'enabled' : 'disabled')."
                Wait-ForKey
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-CustomModsMenu {
    <#
    .SYNOPSIS
        Sub-menu for choosing server or client custom mods management.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Settings > Custom Mods"

        Write-MenuOption "1" "Server custom mods"
        Write-MenuOption "2" "Client custom mods"
        Write-Host ""
        Write-MenuOption "R" "Return"

        $choice = Read-MenuChoice "Select option"

        switch ($choice) {
            '1' {
                Invoke-CustomModSettingsMenu -Config $Config -Target 'server'
            }
            '2' {
                Invoke-CustomModSettingsMenu -Config $Config -Target 'client'
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-BackupsAndCacheMenu {
    <#
    .SYNOPSIS
        Sub-menu for backup settings, managing backups, and download cache.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Settings > Backups and Cache"

        Write-MenuOption "1" "Backup settings"
        Write-MenuOption "2" "Manage backups"
        Write-MenuOption "3" "Manage download cache"
        Write-Host ""
        Write-MenuOption "R" "Return"

        $choice = Read-MenuChoice "Select option"

        switch ($choice) {
            '1' {
                # Backup settings sub-menu
                Write-Header "Settings > Backup Settings"

                Write-Host "  Enabled:   " -NoNewline -ForegroundColor Gray
                Write-Host "$($Config.BackupEnabled ? 'Yes' : 'No')" -ForegroundColor Cyan
                Write-Host "  Directory: " -NoNewline -ForegroundColor Gray
                Write-Host "$($Config.BackupDir)" -ForegroundColor Cyan
                Write-Host "  Retention: " -NoNewline -ForegroundColor Gray
                Write-Host "$($Config.BackupRetention) backups" -ForegroundColor Cyan
                Write-Host ""
                Write-MenuOption "1" "Toggle backup enabled/disabled"
                Write-MenuOption "2" "Change backup directory"
                Write-MenuOption "3" "Change backup retention count"
                Write-MenuOption "R" "Return"

                $bkChoice = Read-MenuChoice "Select option"
                switch ($bkChoice) {
                    '1' {
                        $Config.BackupEnabled = -not $Config.BackupEnabled
                        Save-Config -Config $Config
                        Write-Success "Backups $($Config.BackupEnabled ? 'enabled' : 'disabled')."
                    }
                    '2' {
                        $newDir = Read-UserInput "Enter backup directory path" -Default $Config.BackupDir
                        if ($newDir) {
                            $Config.BackupDir = $newDir
                            Save-Config -Config $Config
                            Write-Success "Backup directory updated."
                        }
                    }
                    '3' {
                        $newRet = Read-UserInput "Enter retention count (number of backups to keep)" -Default "$($Config.BackupRetention)"
                        $retVal = 0
                        if ([int]::TryParse($newRet, [ref]$retVal) -and $retVal -gt 0) {
                            $Config.BackupRetention = $retVal
                            Save-Config -Config $Config
                            Write-Success "Backup retention set to $retVal."
                        }
                        else {
                            Write-Err "Invalid number. Must be a positive integer."
                        }
                    }
                }
                Wait-ForKey
            }
            '2' {
                Invoke-BackupMenu -Config $Config
            }
            '3' {
                Invoke-CacheMenu
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-ExportImportMenu {
    <#
    .SYNOPSIS
        Sub-menu for exporting and importing configuration.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    while ($true) {
        Write-Header "Settings > Export/Import Config"

        Write-MenuOption "1" "Export config"
        Write-MenuOption "2" "Import config"
        Write-Host ""
        Write-MenuOption "R" "Return"

        $choice = Read-MenuChoice "Select option"

        switch ($choice) {
            '1' {
                $defaultExport = Join-Path $script:ScriptDir 'gtnh-config-export.json'
                $exportPath = Read-UserInput "Export path" -Default $defaultExport
                if ($exportPath) {
                    Export-ConfigFile -Config $Config -ExportPath $exportPath
                }
                Wait-ForKey
            }
            '2' {
                $importPath = Read-UserInput "Path to config file to import"
                if ($importPath -and (Test-Path -LiteralPath $importPath)) {
                    $imported = Import-ConfigFile -ImportPath $importPath
                    if ($null -ne $imported) {
                        $imported = Validate-Config -Config $imported
                        Save-Config -Config $imported
                        # Update the reference so caller sees changes
                        $imported.PSObject.Properties | ForEach-Object {
                            if ($Config.PSObject.Properties.Name -contains $_.Name) {
                                $Config.$($_.Name) = $_.Value
                            } else {
                                $Config | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value -Force
                            }
                        }
                        Write-Success "Config imported and saved. Paths may need updating for this machine."
                    }
                } else {
                    Write-Warn "File not found."
                }
                Wait-ForKey
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-CustomModSettingsMenu {
    <#
    .SYNOPSIS
        Sub-menu for managing custom mods (server or client).
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Target
        'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $label = $Target -eq 'server' ? 'Server' : 'Client'
    $instancePath = $Target -eq 'server' ? $Config.ServerPath : $Config.ClientInstancePath

    while ($true) {
        $modList = $Target -eq 'server' ? $Config.CustomServerMods : $Config.CustomClientMods

        Write-Header "Settings > Custom $label Mods"

        if ($modList.Count -gt 0) {
            foreach ($mod in $modList) {
                Write-Host "  - " -NoNewline -ForegroundColor DarkGray
                Write-Host "$mod" -ForegroundColor Cyan
            }
        }
        else {
            Write-Info "No custom mods configured."
        }

        Write-Host ""
        Write-MenuOption "B" "Browse mods/ folder and pick"
        Write-MenuOption "A" "Add manually (type filenames)"
        Write-MenuOption "D" "Remove individual mod"
        Write-MenuOption "C" "Clear all custom $($label.ToLower()) mods"
        Write-MenuOption "R" "Return"

        $choice = Read-MenuChoice "Select option"

        switch ($choice) {
            { $_ -eq 'B' -or $_ -eq 'b' } {
                if ([string]::IsNullOrEmpty($instancePath) -or -not (Test-Path -LiteralPath $instancePath)) {
                    Write-Warn "No valid $($label.ToLower()) path configured."
                    Wait-ForKey
                    continue
                }

                $modsDir = Join-Path $instancePath 'mods'
                if (-not (Test-Path -LiteralPath $modsDir)) {
                    Write-Warn "No mods/ folder found at: $instancePath"
                    Wait-ForKey
                    continue
                }

                # Get all .jar files in mods/
                $allJars = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File |
                    Sort-Object Name |
                    ForEach-Object { $_.Name })

                if ($allJars.Count -eq 0) {
                    Write-Warn "No .jar files found in mods/ folder."
                    Wait-ForKey
                    continue
                }

                # Filter out already-tracked mods
                $alreadyTracked = @($modList)
                $available = @($allJars | Where-Object { $_ -notin $alreadyTracked })

                if ($available.Count -eq 0) {
                    Write-Info "All mods in the folder are already tracked as custom mods."
                    Wait-ForKey
                    continue
                }

                # Paginated list with search
                $pageSize = 20
                $page = 0
                $searchFilter = ''
                $filtered = $available

                while ($true) {
                    # Apply search filter
                    if ($searchFilter) {
                        $filtered = @($available | Where-Object { $_ -like "*$searchFilter*" })
                    } else {
                        $filtered = $available
                    }

                    $totalPages = [math]::Max(1, [math]::Ceiling($filtered.Count / $pageSize))
                    if ($page -ge $totalPages) { $page = 0 }
                    $startIdx = $page * $pageSize
                    $endIdx = [math]::Min($startIdx + $pageSize, $filtered.Count) - 1

                    Write-Header "Browse Mods - $label"
                    if ($searchFilter) {
                        Write-Host "  Search: " -NoNewline -ForegroundColor Gray
                        Write-Host "$searchFilter" -NoNewline -ForegroundColor Yellow
                        Write-Host " ($($filtered.Count) matches)" -ForegroundColor DarkGray
                    }
                    if ($filtered.Count -eq 0) {
                        Write-Info "No mods match '$searchFilter'."
                    } else {
                        $tagWidth = "[$($filtered.Count)]".Length
                        for ($i = $startIdx; $i -le $endIdx; $i++) {
                            $tag = "[$($i + 1)]".PadLeft($tagWidth)
                            Write-Host "    $tag $($filtered[$i])" -ForegroundColor Cyan
                        }
                    }
                    Write-Host ""
                    Write-MenuOption "/" "Search (e.g. /worldedit)"
                    if ($searchFilter) { Write-MenuOption "/" "Clear search" }
                    if ($totalPages -gt 1) { Write-MenuOption "N/P" "Next/Previous page" }
                    Write-MenuOption "Q" "Cancel"

                    $browseChoice = Read-MenuChoice "Select"

                    if ($browseChoice -eq 'q' -or $browseChoice -eq 'Q') { break }
                    if ($browseChoice -eq '/') { $searchFilter = ''; $page = 0; continue }
                    if ($browseChoice -match '^/(.+)') { $searchFilter = $Matches[1]; $page = 0; continue }
                    if ($browseChoice -eq 'n' -or $browseChoice -eq 'N') {
                        if ($page -lt $totalPages - 1) { $page++ }
                        continue
                    }
                    if ($browseChoice -eq 'p' -or $browseChoice -eq 'P') {
                        if ($page -gt 0) { $page-- }
                        continue
                    }

                    # Parse comma-separated numbers
                    $selectedMods = @()
                    foreach ($part in ($browseChoice -split ',')) {
                        $idx = 0
                        if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $filtered.Count) {
                            $selectedMods += $filtered[$idx - 1]
                        }
                    }

                    if ($selectedMods.Count -gt 0) {
                        if ($Target -eq 'server') {
                            $Config.CustomServerMods = @($Config.CustomServerMods) + $selectedMods
                        } else {
                            $Config.CustomClientMods = @($Config.CustomClientMods) + $selectedMods
                        }
                        Save-Config -Config $Config
                        Write-Success "Added $($selectedMods.Count): $($selectedMods -join ', ')"
                        Start-Sleep -Milliseconds 1500

                        # Refresh the available list (remove just-added mods)
                        $modList = $Target -eq 'server' ? $Config.CustomServerMods : $Config.CustomClientMods
                        $alreadyTracked = @($modList)
                        $available = @($allJars | Where-Object { $_ -notin $alreadyTracked })
                        if ($available.Count -eq 0) {
                            Write-Info "All mods are now tracked."
                            Wait-ForKey
                            break
                        }
                        continue
                    } else {
                        Write-Warn "No valid selection."
                    }
                }
            }
            { $_ -eq 'A' -or $_ -eq 'a' } {
                Write-Info "Type the exact .jar filename(s) you want to track."
                Write-Host '  Example: WorldEdit-1.7.10-6.1.1.jar' -ForegroundColor Cyan
                Write-Host '  Example: MouseTweaks-2.10.jar, JourneyMap-5.1.4.jar' -ForegroundColor Cyan
                $userInput = Read-UserInput "Mod filename(s), comma-separated"
                if ($userInput) {
                    $newMods = $userInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                    $validMods = @()
                    $modsDir = if (-not [string]::IsNullOrEmpty($instancePath)) { Join-Path $instancePath 'mods' } else { $null }

                    foreach ($mod in $newMods) {
                        # Must end in .jar
                        if ($mod -notmatch '\.jar$') {
                            Write-Warn "Skipping '$mod' - not a .jar file. Did you mean '${mod}.jar'?"
                            continue
                        }
                        # Check if already tracked
                        $currentMods = $Target -eq 'server' ? $Config.CustomServerMods : $Config.CustomClientMods
                        if ($mod -in @($currentMods)) {
                            Write-Warn "Skipping '$mod' - already tracked."
                            continue
                        }
                        # Check if file exists in mods/ folder
                        if ($modsDir -and (Test-Path -LiteralPath $modsDir)) {
                            $modPath = Join-Path $modsDir $mod
                            if (-not (Test-Path -LiteralPath $modPath)) {
                                Write-Warn "'$mod' not found in mods/ folder. Adding anyway (it may be installed later)."
                            }
                        }
                        $validMods += $mod
                    }

                    if ($validMods.Count -gt 0) {
                        if ($Target -eq 'server') {
                            $Config.CustomServerMods = @($Config.CustomServerMods) + $validMods
                        } else {
                            $Config.CustomClientMods = @($Config.CustomClientMods) + $validMods
                        }
                        Save-Config -Config $Config
                        Write-Success "Added $($validMods.Count) mod(s)."
                    }
                }
                Wait-ForKey
            }
            { $_ -eq 'D' -or $_ -eq 'd' } {
                $currentList = $Target -eq 'server' ? $Config.CustomServerMods : $Config.CustomClientMods
                if ($currentList.Count -eq 0) {
                    Write-Warn "No custom mods to remove."
                } else {
                    Write-Host ""
                    $tagWidth = "[$($currentList.Count)]".Length
                    for ($i = 0; $i -lt $currentList.Count; $i++) {
                        $tag = "[$($i + 1)]".PadLeft($tagWidth)
                        Write-Host "    $tag $($currentList[$i])" -ForegroundColor Cyan
                    }
                    Write-Host ""
                    $removeInput = Read-UserInput "Enter number(s) to remove (comma-separated), or Enter to cancel"
                    if ($removeInput) {
                        $indicesToRemove = @()
                        foreach ($part in ($removeInput -split ',')) {
                            $idx = 0
                            if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $currentList.Count) {
                                $indicesToRemove += ($idx - 1)
                            }
                        }
                        if ($indicesToRemove.Count -gt 0) {
                            $newList = @()
                            for ($i = 0; $i -lt $currentList.Count; $i++) {
                                if ($i -notin $indicesToRemove) {
                                    $newList += $currentList[$i]
                                }
                            }
                            if ($Target -eq 'server') {
                                $Config.CustomServerMods = $newList
                            } else {
                                $Config.CustomClientMods = $newList
                            }
                            Save-Config -Config $Config
                            Write-Success "Removed $($indicesToRemove.Count) mod(s)."
                        }
                    }
                }
                Wait-ForKey
            }
            { $_ -eq 'C' -or $_ -eq 'c' } {
                if (Confirm-Action "Clear all custom $($label.ToLower()) mods?") {
                    if ($Target -eq 'server') {
                        $Config.CustomServerMods = @()
                    }
                    else {
                        $Config.CustomClientMods = @()
                    }
                    Save-Config -Config $Config
                    Write-Success "Custom $($label.ToLower()) mods cleared."
                }
                Wait-ForKey
            }
            { $_ -eq 'R' -or $_ -eq 'r' } {
                return
            }
            default {
                Write-Err "Invalid selection. Please try again."
                Wait-ForKey
            }
        }
    }
}

function Invoke-ViewLogs {
    <#
    .SYNOPSIS
        List recent log files and offer to open the logs folder in Explorer.
    #>

    Write-Header "View Logs"
    Write-Host ""

    $logDir = $script:LogDir

    if (-not (Test-Path -LiteralPath $logDir)) {
        Write-Info "No logs directory found."
        Wait-ForKey
        return
    }

    $logFiles = Get-ChildItem -LiteralPath $logDir -Filter '*.log' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10

    if ($logFiles.Count -eq 0) {
        Write-Info "No log files found."
        Wait-ForKey
        return
    }

    Write-Info "Recent log files (newest first):"
    Write-Host ""
    foreach ($file in $logFiles) {
        $sizeKB = [math]::Round($file.Length / 1KB, 1)
        $date = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        Write-Info "  $($file.Name)  ($sizeKB KB)  [$date]"
    }

    Write-Host ""
    Write-MenuOption "O" "Open logs folder in Explorer"
    Write-MenuOption "R" "Return to main menu"

    $choice = Read-MenuChoice "Select option"

    switch ($choice) {
        { $_ -eq 'O' -or $_ -eq 'o' } {
            try {
                Start-Process explorer.exe -ArgumentList "`"$logDir`""
                Write-Success "Opened logs folder."
            }
            catch {
                Write-Err "Could not open Explorer: $($_.Exception.Message)"
            }
        }
    }

    Wait-ForKey
}

function Invoke-ChangelogViewer {
    <#
    .SYNOPSIS
        Fetch and display the GTNH changelog from GitHub releases.
    .DESCRIPTION
        Lets the user pick a version or view the latest changelog. Fetches the
        release body from GitHub and displays it in the console with basic
        markdown rendering (headers, bullet points).
    #>

    Write-Header "GTNH Changelog"
    Write-Info "Fetching changelog from GitHub..."
    Write-Host ""

    # Get recent releases for the version picker
    $releases = Invoke-GitHubApi -Uri 'https://api.github.com/repos/GTNewHorizons/GT-New-Horizons-Modpack/releases?per_page=10'

    if (-not $releases -or $releases.Count -eq 0) {
        Write-Err "Could not fetch releases. Check your internet connection."
        Wait-ForKey
        return
    }

    Write-Info "Recent GTNH releases:"
    Write-Host ""
    for ($i = 0; $i -lt $releases.Count; $i++) {
        $r = $releases[$i]
        $date = ''
        if ($r.published_at) {
            try { $date = " ($([datetime]::Parse($r.published_at).ToString('yyyy-MM-dd')))" } catch {}
        }
        $prerelease = $r.prerelease ? ' [pre-release]' : ''
        Write-MenuOption "$($i + 1)" "$($r.tag_name)${date}${prerelease}"
    }
    Write-Host ""
    Write-MenuOption "R" "Return"

    $choice = Read-MenuChoice "Select a release to view"

    if ($choice -eq 'r' -or $choice -eq 'R') { return }

    $idx = 0
    if (-not ([int]::TryParse($choice, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $releases.Count) {
        Write-Warn "Invalid selection."
        Wait-ForKey
        return
    }

    $selected = $releases[$idx - 1]

    Write-Header "Changelog: $($selected.tag_name)"

    if ($selected.body) {
        # Render markdown for console display
        $lines = $selected.body -split "`n"
        foreach ($line in $lines) {
            $trimmed = $line.TrimEnd()

            # Skip noise: co-author lines, PR merge messages
            if ($trimmed -match '^Co-authored-by:') { continue }
            if ($trimmed -match '^\* \*\*Full Changelog\*\*') { continue }

            if ($trimmed -match '^#{1,3}\s+(.+)') {
                # Header lines
                Write-Host ""
                Write-Host "  $($Matches[1])" -ForegroundColor Cyan
            }
            elseif ($trimmed -match '^\s*[-*]\s+(.+)') {
                # Bullet points - clean up markdown links [text](url) -> text
                $content = $Matches[1] -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
                # Clean up bold **text** -> text
                $content = $content -replace '\*\*([^\*]+)\*\*', '$1'
                # Clean up inline code `text` -> text
                $content = $content -replace '`([^`]+)`', '$1'
                Write-Host "    - $content" -ForegroundColor Gray
            }
            elseif ($trimmed -eq '') {
                Write-Host ""
            }
            else {
                # Clean up markdown formatting in regular text
                $clean = $trimmed -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
                $clean = $clean -replace '\*\*([^\*]+)\*\*', '$1'
                $clean = $clean -replace '`([^`]+)`', '$1'
                Write-Host "  $clean" -ForegroundColor Gray
            }
        }
    } else {
        Write-Info "No changelog text available for this release."
    }

    Write-Host ""
    if ($selected.html_url) {
        Write-Info "Full release: $($selected.html_url)"
    }

    Wait-ForKey
}

function Invoke-ScriptUpdateCheck {
    <#
    .SYNOPSIS
        Check if a newer version of the GTNH Updater script is available.
    .DESCRIPTION
        Queries the configured GitHub repository and offers to open the download
        page if a newer version is found. Does nothing if no update URL is configured.
    #>

    $updateInfo = Get-ScriptUpdateInfo
    if (-not $updateInfo) {
        return  # Up to date or no URL configured
    }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  GTNH Updater update available!                             ║" -ForegroundColor Cyan
    Write-Host "  ║  Current: v$($script:UpdaterVersion)    Latest: v$($updateInfo.Version)$((' ' * [math]::Max(0, 37 - $updateInfo.Version.Length - $script:UpdaterVersion.Length)))║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($updateInfo.Body) {
        # Show first few lines of release notes
        $bodyLines = ($updateInfo.Body -split "`n") | Select-Object -First 5
        foreach ($line in $bodyLines) {
            Write-Host "  $($line.TrimEnd())" -ForegroundColor Gray
        }
        if (($updateInfo.Body -split "`n").Count -gt 5) {
            Write-Host "  ..." -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-MenuOption "D" "Download update"
    Write-MenuOption "S" "Skip for now"

    $choice = Read-MenuChoice "Choose"

    if ($choice -eq 'D' -or $choice -eq 'd') {
        if ($updateInfo.ReleaseUrl) {
            Start-Process $updateInfo.ReleaseUrl
            Write-Success "Opened release page in your browser."
            Write-Info "Download the latest version and replace your GTNHUpdater folder."
        } else {
            Write-Info "Release URL: $($updateInfo.DownloadUrl)"
        }
        Wait-ForKey
    }
}

function Invoke-VersionPicker {
    <#
    .SYNOPSIS
        Show a version picker listing all website releases (stable + beta/RC).
    .DESCRIPTION
        Presents a numbered list of all available releases. The latest release
        is pre-selected as the default. Users can pick a beta/RC version without
        changing their channel. Returns the selected release object, or $null
        if cancelled.
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Releases
        Array of release objects from Get-WebsiteReleases.
    .OUTPUTS
        PSCustomObject with Version, Type, ServerZipUrl, ServerZipName,
        ClientZipUrl, ClientZipName, ReleaseUrl. Returns $null if cancelled.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][array]$Releases
    )

    Write-Header "Select Version"

    $releases = $Releases

    # Find the installed versions and latest stable for markers
    $serverVer = $Config.InstalledServerVersion
    $clientVer = $Config.InstalledClientVersion
    $installedVersions = @()
    if ($serverVer) { $installedVersions += $serverVer }
    if ($clientVer -and $clientVer -ne $serverVer) { $installedVersions += $clientVer }

    $latestStableIdx = -1
    for ($si = 0; $si -lt $releases.Count; $si++) {
        if ($releases[$si].Type -eq 'Stable') { $latestStableIdx = $si; break }
    }

    # Show the list (page 1 = recent, which is what most people want)
    $pageSize = 15
    $page = 0
    $totalPages = [math]::Max(1, [math]::Ceiling($releases.Count / $pageSize))

    while ($true) {
        $startIdx = $page * $pageSize
        $endIdx = [math]::Min($startIdx + $pageSize, $releases.Count) - 1

        Write-Host ""
        Write-Host "  Available releases (newest first):" -ForegroundColor White
        Write-Host ""

        for ($i = $startIdx; $i -le $endIdx; $i++) {
            $r = $releases[$i]
            $num = "[$($i + 1)]".PadLeft(5)
            $typeLabel = $r.Type -eq 'Stable' ? '         ' : ' (beta)  '
            $dateLabel = $r.Date ? "  $($r.Date)" : ''

            # Build the tag that appears after the version
            $tag = ''
            if ($r.Version -in $installedVersions) { $tag += ' (installed)' }
            if ($i -eq 0 -and $latestStableIdx -ne 0) {
                # Newest overall is a beta, mark it
                $tag += ' <-- newest'
            }
            elseif ($i -eq 0) {
                $tag += ' <-- latest'
            }
            if ($i -eq $latestStableIdx -and $latestStableIdx -ne 0) {
                $tag += ' <-- latest stable'
            }

            # Pick color based on type and position
            if ($r.Version -in $installedVersions) {
                Write-Host "  $num $($r.Version)${typeLabel}" -NoNewline -ForegroundColor White
                Write-Host "${dateLabel}${tag}" -ForegroundColor DarkGray
            }
            elseif ($i -eq 0) {
                Write-Host "  $num $($r.Version)${typeLabel}" -NoNewline -ForegroundColor Green
                Write-Host "${dateLabel}" -NoNewline -ForegroundColor DarkGray
                Write-Host "$tag" -ForegroundColor DarkGreen
            }
            elseif ($r.Type -eq 'Beta') {
                Write-Host "  $num $($r.Version)${typeLabel}" -NoNewline -ForegroundColor DarkYellow
                Write-Host "${dateLabel}${tag}" -ForegroundColor DarkGray
            }
            else {
                Write-Host "  $num $($r.Version)${typeLabel}" -NoNewline -ForegroundColor Cyan
                Write-Host "${dateLabel}${tag}" -ForegroundColor DarkGray
            }
        }

        Write-Host ""
        if ($totalPages -gt 1) {
            Write-Host "  Page $($page + 1) of $totalPages" -ForegroundColor DarkGray
        }

        # Options
        if ($totalPages -gt 1 -and $page -lt $totalPages - 1) {
            Write-MenuOption "N" "Next page"
        }
        if ($page -gt 0) {
            Write-MenuOption "P" "Previous page"
        }
        $defaultLabel = $releases[0].Version
        if ($latestStableIdx -eq 0) {
            Write-MenuOption "Enter" "Latest stable ($defaultLabel)"
        } else {
            Write-MenuOption "Enter" "Newest ($defaultLabel)"
        }
        Write-MenuOption "R" "Return to main menu"

        $choice = Read-MenuChoice "Enter number or option"

        if ($choice -eq '' -or $choice -eq $null) {
            # Default: latest release
            return $releases[0]
        }
        if ($choice -eq 'r' -or $choice -eq 'R') {
            return $null
        }
        if ($choice -eq 'n' -or $choice -eq 'N') {
            if ($page -lt $totalPages - 1) { $page++ }
            continue
        }
        if ($choice -eq 'p' -or $choice -eq 'P') {
            if ($page -gt 0) { $page-- }
            continue
        }

        # Try to parse as a number
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $releases.Count) {
            return $releases[$idx - 1]
        }

        Write-Warn "Invalid selection. Enter a number (1-$($releases.Count)), N/P, or R."
    }
}

function Invoke-UpdateHistory {
    <#
    .SYNOPSIS
        Display the update history from config with dates, versions, channels, and targets.
    .PARAMETER Config
        The config PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    Write-Header "Update History"

    $history = $Config.UpdateHistory
    if (-not $history -or @($history).Count -eq 0) {
        Write-Info "No update history recorded yet."
        Write-Info "History is recorded automatically after each update."
        Wait-ForKey
        return
    }

    $entries = @($history) | Sort-Object { $_.Date } -Descending

    Write-Info "Recent updates (newest first):"
    Write-Host ""
    Write-Host "  Date                  Version                Channel        Target" -ForegroundColor White
    Write-Host "  $('-' * 72)" -ForegroundColor DarkGray

    foreach ($entry in $entries) {
        $date = $entry.Date ? $entry.Date.Substring(0, [math]::Min(19, $entry.Date.Length)) : '(unknown)'
        $version = ($entry.Version ?? '(unknown)').PadRight(22)
        $channel = ($entry.Channel ?? '(unknown)').PadRight(14)
        $target = $entry.Target ?? '(unknown)'

        $channelColor = switch ($entry.Channel) {
            'stable'       { 'Cyan' }
            'beta'         { 'DarkYellow' }
            'daily'        { 'Magenta' }
            'experimental' { 'DarkMagenta' }
            default        { 'Gray' }
        }

        Write-Host "  $date  " -NoNewline -ForegroundColor Gray
        Write-Host "$version" -NoNewline -ForegroundColor Green
        Write-Host "$channel" -NoNewline -ForegroundColor $channelColor
        Write-Host "$target" -NoNewline -ForegroundColor White
        if ($entry.Details) {
            Write-Host "  $($entry.Details)" -ForegroundColor DarkGray
        } else {
            Write-Host ""
        }
    }

    Write-Host ""
    Write-Info "$($entries.Count) update(s) recorded."

    Wait-ForKey
}

function Show-HelpScreen {
    <#
    .SYNOPSIS
        Display a help overview explaining the main features.
    #>

    Write-Header "Help"

    Write-Host "  " -NoNewline
    Write-Host "Update GTNH" -ForegroundColor Cyan
    Write-Host "  Updates your server and/or client using your default channel." -ForegroundColor Gray
    Write-Host "  Stable: shows a version picker with all releases (stable + beta)," -ForegroundColor Gray
    Write-Host "  then downloads a full pack zip with preview before applying." -ForegroundColor Gray
    Write-Host "  Daily/Experimental: uses the GTNH updater JAR (needs Java 21+)." -ForegroundColor Gray
    Write-Host ""

    Write-Host "  " -NoNewline
    Write-Host "Custom Mods" -ForegroundColor Cyan
    Write-Host "  Mods you added that aren't part of GTNH. Add them in Settings" -ForegroundColor Gray
    Write-Host "  so they're preserved when you update. Use Browse to pick from" -ForegroundColor Gray
    Write-Host "  your mods/ folder instead of typing filenames." -ForegroundColor Gray
    Write-Host ""

    Write-Host "  " -NoNewline
    Write-Host "Config Patches" -ForegroundColor Cyan
    Write-Host "  Settings you always change (like disabling pollution). Save them" -ForegroundColor Gray
    Write-Host "  as patches and they're re-applied automatically after every update." -ForegroundColor Gray
    Write-Host ""

    Write-Host "  " -NoNewline
    Write-Host "Channels" -ForegroundColor Cyan
    Write-Host "  Stable = official releases. Daily = dev builds (updated daily)." -ForegroundColor Gray
    Write-Host "  Experimental = bleeding edge (may be unstable)." -ForegroundColor Gray
    Write-Host "  Change your channel in Settings > Update Preferences." -ForegroundColor Gray
    Write-Host ""

    Write-Host "  " -NoNewline
    Write-Host "Backups" -ForegroundColor Cyan
    Write-Host "  Always back up before updating. The script saves a rollback" -ForegroundColor Gray
    Write-Host "  snapshot during updates, but your own backups are essential." -ForegroundColor Gray
    Write-Host ""

    Write-Host "  " -NoNewline
    Write-Host "Tips" -ForegroundColor Cyan
    Write-Host "  Use /text to search in any browse list." -ForegroundColor Gray
    Write-Host "  Type comma-separated numbers to select multiple items (1,3,5)." -ForegroundColor Gray
    Write-Host ""

    Wait-ForKey
}

function Invoke-MainLoop {
    <#
    .SYNOPSIS
        Top-level entry point: init logging, load config, run main menu loop.
    .DESCRIPTION
        1. Initialize logging
        2. Load config (run setup wizard if null)
        3. Validate config
        4. Main menu loop: display menu, read choice, dispatch
    #>

    try {
        # Clear screen and show loading message
        Clear-Host
        Write-Banner
        Write-Info "Starting up..."
        Write-Host ""

        # Initialize logging first
        Initialize-Logging

        Write-Log "[MAIN] GTNH Updater starting..."

        # Clean up stale files from previous runs
        Invoke-StartupCleanup

        # Check for leftover rollback snapshots (indicates a previous update may have been interrupted)
        $tempDir = $script:TempDir
        if (Test-Path -LiteralPath $tempDir) {
            $rollbackDirs = @(Get-ChildItem -LiteralPath $tempDir -Directory -Filter 'rollback-*' -ErrorAction SilentlyContinue)
            if ($rollbackDirs.Count -gt 0) {
                Write-Host ""
                Write-Warn "Found rollback snapshot(s) from a previous update that may have been interrupted."
                foreach ($rd in $rollbackDirs) {
                    Write-Info "  - $($rd.Name)"
                }
                Write-Host ""
                Write-Info "If your instance is broken, you can restore from these snapshots in Settings > Backups."
                Write-Info "Otherwise they will be cleaned up automatically."
                Write-Host ""
                Wait-ForKey
            }
        }

        # Load config
        $config = Load-Config

        if ($null -eq $config) {
            Write-Info "No configuration found. Starting setup wizard..."
            Write-Host ""
            $config = Invoke-InteractiveSetup
            if ($null -eq $config) {
                Write-Err "Setup wizard did not produce a configuration. Exiting."
                return
            }
        }

        # Validate config (add missing fields with defaults)
        $config = Validate-Config -Config $config

        # Log config context for troubleshooting (redact usernames from paths)
        $redactPath = { param($p) if ($p) { $p -replace '\\Users\\[^\\]+', '\Users\***' } else { '(not set)' } }
        Write-Log "[CONFIG] Server path: $(& $redactPath $config.ServerPath)"
        Write-Log "[CONFIG] Client path: $(& $redactPath $config.ClientInstancePath)"
        Write-Log "[CONFIG] Java path: $(& $redactPath $config.JavaPath)"
        Write-Log "[CONFIG] Channel: $($config.DefaultChannel)"
        Write-Log "[CONFIG] Java version: $($config.JavaVersion)"
        Write-Log "[CONFIG] Server version: $($config.InstalledServerVersion)"
        Write-Log "[CONFIG] Client version: $($config.InstalledClientVersion)"
        Write-Log "[CONFIG] Custom server mods: $($config.CustomServerMods.Count)"
        Write-Log "[CONFIG] Custom client mods: $($config.CustomClientMods.Count)"
        Write-Log "[CONFIG] Config patches: $($config.ConfigPatches.Count)"

        # Show "what's new" if the script version changed since last run
        $lastSeenVersion = $config.PSObject.Properties.Name -contains 'LastSeenScriptVersion' ? $config.LastSeenScriptVersion : $null
        if ($lastSeenVersion -and $lastSeenVersion -ne $script:UpdaterVersion) {
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "  ║  GTNH Updater updated to v$($script:UpdaterVersion)!$(' ' * [math]::Max(0, 33 - $script:UpdaterVersion.Length))║" -ForegroundColor Green
            Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
            Write-Host ""
            # Show brief changelog from the bundled CHANGELOG.md if it exists
            $changelogPath = Join-Path $script:ScriptDir 'CHANGELOG.md'
            if (Test-Path -LiteralPath $changelogPath) {
                $clLines = Get-Content -LiteralPath $changelogPath -Encoding UTF8 -TotalCount 30
                $inCurrentVersion = $false
                foreach ($clLine in $clLines) {
                    if ($clLine -match "^\#\#\s+\[$([regex]::Escape($script:UpdaterVersion))") {
                        $inCurrentVersion = $true
                        continue
                    }
                    if ($inCurrentVersion -and $clLine -match '^\#\#\s+\[') {
                        break  # Hit the next version header, stop
                    }
                    if ($inCurrentVersion -and $clLine.Trim()) {
                        $clean = $clLine.Trim() -replace '^[-*]\s+', '- '
                        Write-Host "  $clean" -ForegroundColor Gray
                    }
                }
            }
            Write-Host ""
            Wait-ForKey
        }
        # Update the last seen version
        if (-not ($config.PSObject.Properties.Name -contains 'LastSeenScriptVersion')) {
            $config | Add-Member -NotePropertyName 'LastSeenScriptVersion' -NotePropertyValue $script:UpdaterVersion -Force
        } else {
            $config.LastSeenScriptVersion = $script:UpdaterVersion
        }
        Save-Config -Config $config

        # Auto-check for latest version (cached for the session)
        $script:CachedLatestVersion = $null
        $script:CachedLatestBeta = $null
        $script:CachedLatestNightly = $null
        $autoCheck = $config.AutoCheckUpdates ?? $true
        $isStable = ($config.DefaultChannel ?? 'stable') -eq 'stable'
        if ($autoCheck) {
            Write-Info "Checking for latest versions..."
            try {
                $websiteReleases = Get-WebsiteReleases -PackType ($config.JavaVersion ?? 'java17')
                if ($websiteReleases -and $websiteReleases.Count -gt 0) {
                    # Latest stable = first entry with Type 'Stable'
                    $latestStableEntry = $websiteReleases | Where-Object { $_.Type -eq 'Stable' } | Select-Object -First 1
                    if ($latestStableEntry) {
                        $script:CachedLatestVersion = $latestStableEntry.Version
                        Write-Log "[MAIN] Latest stable version: $($script:CachedLatestVersion)"
                    }
                    # Latest beta = first entry with Type 'Beta' (only if it's newer than latest stable)
                    $latestBetaEntry = $websiteReleases | Where-Object { $_.Type -eq 'Beta' } | Select-Object -First 1
                    if ($latestBetaEntry) {
                        # Only show beta if it appears before (newer than) the latest stable on the page
                        $betaIdx = [array]::IndexOf($websiteReleases, $latestBetaEntry)
                        $stableIdx = if ($latestStableEntry) { [array]::IndexOf($websiteReleases, $latestStableEntry) } else { $websiteReleases.Count }
                        if ($betaIdx -lt $stableIdx) {
                            $script:CachedLatestBeta = $latestBetaEntry.Version
                            Write-Log "[MAIN] Latest beta: $($script:CachedLatestBeta)"
                        }
                    }
                }
            }
            catch {
                Write-Log "[WARN] Version check failed: $($_.Exception.Message)"
                # Fallback to the original stable-only check
                try {
                    $latestRelease = Get-LatestStableRelease
                    if ($latestRelease) {
                        $script:CachedLatestVersion = $latestRelease.Version
                    }
                }
                catch {
                    Write-Log "[WARN] Stable version fallback also failed: $($_.Exception.Message)"
                }
            }

            # For nightly users, also check the latest nightly build from GitHub
            if (-not $isStable) {
                Write-Info "Checking for latest daily build..."
                try {
                    $nightlyReleases = Invoke-GitHubApi -Uri 'https://api.github.com/repos/GTNewHorizons/GT-New-Horizons-Modpack/releases?per_page=1'
                    if ($nightlyReleases -and $nightlyReleases.Count -gt 0) {
                        $script:CachedLatestNightly = $nightlyReleases[0].tag_name
                        Write-Log "[MAIN] Latest daily: $($script:CachedLatestNightly)"
                    }
                }
                catch {
                    Write-Log "[WARN] Daily build check failed: $($_.Exception.Message)"
                }
            }

            # Show one-liner based on channel
            if ($isStable) {
                $serverBehind = $config.InstalledServerVersion -and $script:CachedLatestVersion -and $config.InstalledServerVersion -ne $script:CachedLatestVersion
                $clientBehind = $config.InstalledClientVersion -and $script:CachedLatestVersion -and $config.InstalledClientVersion -ne $script:CachedLatestVersion
                if ($serverBehind -or $clientBehind) {
                    Write-Host ""
                    Write-Host "  ★ Stable update available: " -NoNewline -ForegroundColor Yellow
                    Write-Host "$($script:CachedLatestVersion)" -ForegroundColor Cyan
                    if ($script:CachedLatestBeta) {
                        Write-Host "    Beta also available:     $($script:CachedLatestBeta)" -ForegroundColor DarkYellow
                    }
                    Write-Host ""
                } elseif ($script:CachedLatestBeta) {
                    Write-Host ""
                    Write-Host "  ★ Beta available: " -NoNewline -ForegroundColor DarkYellow
                    Write-Host "$($script:CachedLatestBeta)" -ForegroundColor Cyan
                    Write-Host ""
                }
            } else {
                if ($script:CachedLatestNightly) {
                    Write-Host ""
                    Write-Host "  ★ Latest daily: " -NoNewline -ForegroundColor Magenta
                    Write-Host "$($script:CachedLatestNightly)" -ForegroundColor Cyan
                    if ($script:CachedLatestVersion) {
                        Write-Host "    Latest stable:  $($script:CachedLatestVersion)" -ForegroundColor Gray
                    }
                    Write-Host ""
                }
            }
        }

        # Check for script self-update
        Invoke-ScriptUpdateCheck

        # Main menu loop
        while ($true) {
            Show-MainMenu -Config $config

            $choice = Read-MenuChoice "Choose an option"

            switch ($choice) {
                '1' {
                    # Update GTNH - use default channel
                    $channel = $config.DefaultChannel ?? 'stable'

                    if ($channel -eq 'stable') {
                        # Fetch all website releases for version picker and downgrade detection
                        Write-Info "Fetching available releases..."
                        $allReleases = Get-WebsiteReleases -PackType ($config.JavaVersion ?? 'java17')
                        if (-not $allReleases -or $allReleases.Count -eq 0) {
                            Write-Err "Could not fetch releases. Check your internet connection."
                            Wait-ForKey
                            break
                        }

                        # Show version picker first (stable + beta/RC releases)
                        $selectedRelease = Invoke-VersionPicker -Config $config -Releases $allReleases
                        if (-not $selectedRelease) { break }

                        $targets = Invoke-TargetSelection -Config $config
                        if (-not $targets.Server -and -not $targets.Client) { break }

                        # Determine channel label for history
                        $channelLabel = $selectedRelease.Type -eq 'Beta' ? 'beta' : 'stable'

                        if ($targets.Server) {
                            Invoke-StableUpdate -Config $config -Target 'server' -Release $selectedRelease -ChannelLabel $channelLabel -WebsiteReleases $allReleases
                        }
                        if ($targets.Server -and $targets.Client) {
                            Write-Host ""
                            if (-not (Confirm-Action "Continue to client update?")) {
                                Write-Info "Client update skipped."
                                $targets.Client = $false
                            }
                        }
                        if ($targets.Client) {
                            Invoke-StableUpdate -Config $config -Target 'client' -Release $selectedRelease -ChannelLabel $channelLabel -WebsiteReleases $allReleases
                        }
                    }
                    else {
                        $targets = Invoke-TargetSelection -Config $config
                        if (-not $targets.Server -and -not $targets.Client) { break }

                        if ($targets.Server) {
                            Invoke-NightlyUpdate -Config $config -Target 'server' -Channel $channel
                        }
                        if ($targets.Server -and $targets.Client) {
                            Write-Host ""
                            if (-not (Confirm-Action "Continue to client update?")) {
                                Write-Info "Client update skipped."
                                $targets.Client = $false
                            }
                        }
                        if ($targets.Client) {
                            Invoke-NightlyUpdate -Config $config -Target 'client' -Channel $channel
                        }
                    }

                    # Reload config in case updates modified it
                    $reloaded = Load-Config
                    if ($null -ne $reloaded) {
                        $config = Validate-Config -Config $reloaded
                    }

                    # Remind about version mismatch if only one target was updated
                    if (($targets.Server -xor $targets.Client) -and
                        -not [string]::IsNullOrEmpty($config.InstalledServerVersion) -and
                        -not [string]::IsNullOrEmpty($config.InstalledClientVersion) -and
                        $config.InstalledServerVersion -ne $config.InstalledClientVersion) {
                        Write-Host ""
                        Write-Warn "Reminder: Server and client are on different versions."
                        Write-Warn "Consider updating the other target to match."
                    }

                    Wait-ForKey
                }
                '2' {
                    # Settings
                    Invoke-SettingsMenu -Config $config
                    # Reload config in case settings changed
                    $reloaded = Load-Config
                    if ($null -ne $reloaded) {
                        $config = Validate-Config -Config $reloaded
                    }
                    # Fetch version info if not yet cached (handles auto-check toggled on, channel changed, etc.)
                    $autoCheckNow = $config.AutoCheckUpdates ?? $true
                    if ($autoCheckNow) {
                        if (-not $script:CachedLatestVersion) {
                            Write-Info "Checking for latest versions..."
                            try {
                                $websiteReleases = Get-WebsiteReleases -PackType ($config.JavaVersion ?? 'java17')
                                if ($websiteReleases -and $websiteReleases.Count -gt 0) {
                                    $latestStableEntry = $websiteReleases | Where-Object { $_.Type -eq 'Stable' } | Select-Object -First 1
                                    if ($latestStableEntry) {
                                        $script:CachedLatestVersion = $latestStableEntry.Version
                                    }
                                    $latestBetaEntry = $websiteReleases | Where-Object { $_.Type -eq 'Beta' } | Select-Object -First 1
                                    if ($latestBetaEntry) {
                                        $betaIdx = [array]::IndexOf($websiteReleases, $latestBetaEntry)
                                        $stableIdx = if ($latestStableEntry) { [array]::IndexOf($websiteReleases, $latestStableEntry) } else { $websiteReleases.Count }
                                        if ($betaIdx -lt $stableIdx) {
                                            $script:CachedLatestBeta = $latestBetaEntry.Version
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Log "[WARN] Version check failed: $($_.Exception.Message)"
                            }
                        }
                        $currentChannel = $config.DefaultChannel ?? 'stable'
                        if ($currentChannel -ne 'stable' -and -not $script:CachedLatestNightly) {
                            Write-Info "Checking for latest daily build..."
                            try {
                                $nightlyReleases = Invoke-GitHubApi -Uri 'https://api.github.com/repos/GTNewHorizons/GT-New-Horizons-Modpack/releases?per_page=1'
                                if ($nightlyReleases -and $nightlyReleases.Count -gt 0) {
                                    $script:CachedLatestNightly = $nightlyReleases[0].tag_name
                                    Write-Log "[MAIN] Latest daily: $($script:CachedLatestNightly)"
                                }
                            }
                            catch {
                                Write-Log "[WARN] Daily build check failed: $($_.Exception.Message)"
                            }
                        }
                    }
                }
                '3' {
                    # View logs
                    Invoke-ViewLogs
                }
                '4' {
                    # View GTNH changelog
                    Invoke-ChangelogViewer
                }
                '5' {
                    # Update history
                    Invoke-UpdateHistory -Config $config
                }
                { $_ -eq 'H' -or $_ -eq 'h' } {
                    # Help
                    Show-HelpScreen
                }
                { $_ -eq 'Q' -or $_ -eq 'q' } {
                    Write-Host ""
                    Write-Info "Goodbye!"
                    Write-Log "[MAIN] User quit."
                    return
                }
                default {
                    Write-Err "Invalid selection. Please enter 1-5, H, or Q."
                    Start-Sleep -Milliseconds 1500
                }
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "  [FATAL ERROR] An unexpected error occurred:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Check the log file for details." -ForegroundColor DarkYellow
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "[FATAL] Unhandled exception: $($_.Exception.Message)"
            Write-Log "[FATAL] Stack trace: $($_.ScriptStackTrace)"
        }
        Wait-ForKey
    }
}
