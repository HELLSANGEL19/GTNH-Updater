# ============================================================================
# Group 5: Setup Wizard - First-run interactive configuration
# ============================================================================
# Functions:
#   Test-GtnhPath            - Validate a path looks like a GTNH instance
#   Invoke-InteractiveSetup  - Multi-step wizard:
#                               1. Detect Java installations
#                               2. Detect server instances
#                               3. Detect client instances
#                               4. Set preferences (channel, pack type)
#                               5. Summary and save
#
# Presents detected options as numbered lists; manual entry is always the
# last option. Shows defaults in brackets, validates paths immediately.
# ============================================================================

function Test-GtnhPath {
    <#
    .SYNOPSIS
        Validate a path looks like a GTNH instance and warn if not.
    .PARAMETER Path
        The path to check.
    .PARAMETER Target
        'server' or 'client' - affects what we look for.
    .OUTPUTS
        $true if the path looks valid or the user confirms anyway.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $issues = @()

    # Check for mods/ folder
    $modsPath = Join-Path $Path 'mods'
    if (-not (Test-Path -LiteralPath $modsPath)) {
        $issues += "No mods/ folder found"
    } else {
        # Check for GTNH-specific mods
        if (-not (Test-IsGtnhInstance -ModsPath $modsPath)) {
            $issues += "No GregTech mods found in mods/ (may not be a GTNH instance)"
        }
    }

    # Check for config/ folder
    $configPath = Join-Path $Path 'config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $issues += "No config/ folder found"
    }

    # Server-specific checks
    if ($Target -eq 'server') {
        $serverProps = Join-Path $Path 'server.properties'
        if (-not (Test-Path -LiteralPath $serverProps)) {
            $issues += "No server.properties found"
        }
    }

    if ($issues.Count -eq 0) {
        Write-Success "Path looks like a valid GTNH $Target instance."
        return $true
    }

    Write-Warn "This path may not be a GTNH $Target instance:"
    foreach ($issue in $issues) {
        Write-Warn "  - $issue"
    }
    return (Confirm-Action "Use this path anyway?")
}

function Invoke-InteractiveSetup {
    <#
    .SYNOPSIS
        Run the multi-step interactive setup wizard.
    .DESCRIPTION
        Guides the user through detecting and selecting Java, server instance,
        client instance, and preferences. Saves the resulting config to disk.
    .PARAMETER ExistingConfig
        Optional existing config object to use as defaults.
    .OUTPUTS
        The completed config PSCustomObject.
    #>
    param(
        [PSCustomObject]$ExistingConfig
    )

    $config = $ExistingConfig ?? (New-DefaultConfig)

    Write-Header "GTNH Updater - Setup Wizard"
    Write-Info "Close this window at any time to cancel. Setup will re-run next launch."
    Write-Host ""

    # ========================================================================
    # Step 1: Java Detection
    # ========================================================================
    Write-Header "Step 1/5: Java Installation"

    $javaInstalls = Find-JavaInstallations

    if ($javaInstalls.Count -gt 0) {
        # Find the best Java (highest version that's 21+, or just highest)
        $recommended = $javaInstalls | Where-Object { $_.MajorVersion -ge 21 } | Select-Object -First 1
        $recommendedIdx = -1

        Write-Info "Detected Java installations:"
        Write-Info ""
        for ($i = 0; $i -lt $javaInstalls.Count; $i++) {
            $java = $javaInstalls[$i]
            $label = "Java $($java.MajorVersion) - $($java.Path)"
            if ($recommended -and $java.Path -eq $recommended.Path) {
                $label += " (recommended)"
                $recommendedIdx = $i
            }
            Write-MenuOption "$($i + 1)" $label
        }
        Write-MenuOption "M" "Enter path manually"

        $defaultHint = $recommendedIdx -ge 0 ? " [default: $($recommendedIdx + 1)]" : ""
        $javaChoice = Read-MenuChoice "Select Java installation$defaultHint"

        # Auto-select recommended if user just presses Enter
        if ([string]::IsNullOrEmpty($javaChoice) -and $recommendedIdx -ge 0) {
            $config.JavaPath = $javaInstalls[$recommendedIdx].Path
        }
        elseif ($javaChoice -eq 'M' -or $javaChoice -eq 'm') {
            $javaPath = Read-UserInput "Enter the full path to java.exe (not javaw.exe)"
            while ($javaPath -and -not (Test-Path -LiteralPath $javaPath)) {
                Write-Warn "Path not found: $javaPath"
                $javaPath = Read-UserInput "Enter the full path to java.exe (not javaw.exe)"
            }
            if ($javaPath) {
                $config.JavaPath = $javaPath
            }
        }
        else {
            $idx = 0
            if ([int]::TryParse($javaChoice, [ref]$idx) -and $idx -ge 1 -and $idx -le $javaInstalls.Count) {
                $config.JavaPath = $javaInstalls[$idx - 1].Path
            }
            else {
                Write-Warn "Invalid selection. Skipping Java configuration."
            }
        }
    }
    else {
        Write-Info "No Java installations detected."
        $javaPath = Read-UserInput "Enter the full path to java.exe (not javaw.exe), or press Enter to skip"
        if ($javaPath) {
            while ($javaPath -and -not (Test-Path -LiteralPath $javaPath)) {
                Write-Warn "Path not found: $javaPath"
                $javaPath = Read-UserInput "Enter the full path to java.exe, or press Enter to skip"
            }
            if ($javaPath) {
                $config.JavaPath = $javaPath
            }
        }
    }

    if ($config.JavaPath) {
        Write-Success "Java path set: $($config.JavaPath)"
    }

    # ========================================================================
    # Step 2: Server Instance Detection
    # ========================================================================
    Write-Header "Step 2/5: GTNH Server Instance"

    $serverInstances = Find-AmpInstances

    if ($serverInstances.Count -gt 0) {
        Write-Info "Detected GTNH server instances:"
        Write-Info ""
        for ($i = 0; $i -lt $serverInstances.Count; $i++) {
            $srv = $serverInstances[$i]
            $verDisplay = ($srv.Version -ne 'unknown') ? " (v$($srv.Version))" : ""
            Write-MenuOption "$($i + 1)" "$($srv.Name)$verDisplay - $($srv.Path)"
        }
        Write-MenuOption "M" "Enter path manually"
        Write-MenuOption "S" "Skip (no server)"

        $serverChoice = Read-MenuChoice "Select server instance"

        if ($serverChoice -eq 'S' -or $serverChoice -eq 's') {
            Write-Info "Skipping server configuration."
        }
        elseif ($serverChoice -eq 'M' -or $serverChoice -eq 'm') {
            $serverPath = Read-UserInput "Enter the full path to your GTNH server root folder"
            while ($serverPath -and -not (Test-Path -LiteralPath $serverPath)) {
                Write-Warn "Path not found: $serverPath"
                $serverPath = Read-UserInput "Enter the full path to your GTNH server root folder"
            }
            if ($serverPath -and (Test-GtnhPath -Path $serverPath -Target 'server')) {
                $config.ServerPath = $serverPath
            }
        }
        else {
            $idx = 0
            if ([int]::TryParse($serverChoice, [ref]$idx) -and $idx -ge 1 -and $idx -le $serverInstances.Count) {
                $config.ServerPath = $serverInstances[$idx - 1].Path
            }
            else {
                Write-Warn "Invalid selection. Skipping server configuration."
            }
        }
    }
    else {
        Write-Info "No GTNH server instances detected."
        Write-MenuOption "M" "Enter path manually"
        Write-MenuOption "S" "Skip (no server)"

        $serverChoice = Read-MenuChoice "Select an option"

        if ($serverChoice -eq 'M' -or $serverChoice -eq 'm') {
            $serverPath = Read-UserInput "Enter the full path to your GTNH server root folder"
            while ($serverPath -and -not (Test-Path -LiteralPath $serverPath)) {
                Write-Warn "Path not found: $serverPath"
                $serverPath = Read-UserInput "Enter the full path to your GTNH server root folder"
            }
            if ($serverPath -and (Test-GtnhPath -Path $serverPath -Target 'server')) {
                $config.ServerPath = $serverPath
            }
        }
        else {
            Write-Info "Skipping server configuration."
        }
    }

    if ($config.ServerPath) {
        Write-Success "Server path set: $($config.ServerPath)"
    }

    # ========================================================================
    # Step 3: Client Instance Detection
    # ========================================================================
    Write-Header "Step 3/5: GTNH Client Instance (Prism Launcher)"

    $clientInstances = Find-PrismInstances

    if ($clientInstances.Count -gt 0) {
        Write-Info "Detected GTNH client instances:"
        Write-Info ""
        for ($i = 0; $i -lt $clientInstances.Count; $i++) {
            $cli = $clientInstances[$i]
            $verDisplay = ($cli.Version -ne 'unknown') ? " (v$($cli.Version))" : ""
            Write-MenuOption "$($i + 1)" "$($cli.Name)$verDisplay - $($cli.Path)"
        }
        Write-MenuOption "M" "Enter path manually"
        Write-MenuOption "S" "Skip (no client)"

        $clientChoice = Read-MenuChoice "Select client instance"

        if ($clientChoice -eq 'S' -or $clientChoice -eq 's') {
            Write-Info "Skipping client configuration."
        }
        elseif ($clientChoice -eq 'M' -or $clientChoice -eq 'm') {
            $clientPath = Read-UserInput "Enter the full path to your GTNH .minecraft folder"
            while ($clientPath -and -not (Test-Path -LiteralPath $clientPath)) {
                Write-Warn "Path not found: $clientPath"
                $clientPath = Read-UserInput "Enter the full path to your GTNH .minecraft folder"
            }
            if ($clientPath -and (Test-GtnhPath -Path $clientPath -Target 'client')) {
                $config.ClientInstancePath = $clientPath
            }
        }
        else {
            $idx = 0
            if ([int]::TryParse($clientChoice, [ref]$idx) -and $idx -ge 1 -and $idx -le $clientInstances.Count) {
                $config.ClientInstancePath = $clientInstances[$idx - 1].Path
            }
            else {
                Write-Warn "Invalid selection. Skipping client configuration."
            }
        }
    }
    else {
        Write-Info "No GTNH client instances detected."
        Write-MenuOption "M" "Enter path manually"
        Write-MenuOption "S" "Skip (no client)"

        $clientChoice = Read-MenuChoice "Select an option"

        if ($clientChoice -eq 'M' -or $clientChoice -eq 'm') {
            $clientPath = Read-UserInput "Enter the full path to your GTNH .minecraft folder"
            while ($clientPath -and -not (Test-Path -LiteralPath $clientPath)) {
                Write-Warn "Path not found: $clientPath"
                $clientPath = Read-UserInput "Enter the full path to your GTNH .minecraft folder"
            }
            if ($clientPath -and (Test-GtnhPath -Path $clientPath -Target 'client')) {
                $config.ClientInstancePath = $clientPath
            }
        }
        else {
            Write-Info "Skipping client configuration."
        }
    }

    if ($config.ClientInstancePath) {
        Write-Success "Client path set: $($config.ClientInstancePath)"
    }

    # ========================================================================
    # Step 4: Preferences
    # ========================================================================
    Write-Header "Step 4/5: Preferences"

    # Default channel
    Write-Info "Select default update channel:"
    Write-MenuOption "1" "Stable (official releases from gtnewhorizons.com)"
    Write-MenuOption "2" "Daily (dev builds, updated daily)"
    Write-MenuOption "3" "Experimental (bleeding edge, may be unstable)"

    $channelChoice = Read-MenuChoice "Default channel"
    $config.DefaultChannel = switch ($channelChoice) {
        '1' { 'stable' }
        '2' { 'daily' }
        '3' { 'experimental' }
        default { $config.DefaultChannel ?? 'stable' }
    }
    Write-Success "Default channel: $($config.DefaultChannel)"

    # Server pack type
    Write-Info ""
    Write-Info "Select server pack type:"
    Write-MenuOption "1" "Java 17+ (recommended)"
    Write-MenuOption "2" "Java 8 (legacy)"

    $packChoice = Read-MenuChoice "Server pack type"
    $config.JavaVersion = switch ($packChoice) {
        '1' { 'java17' }
        '2' { 'java8' }
        default { $config.JavaVersion ?? 'java17' }
    }
    Write-Success "Server pack type: $($config.JavaVersion)"

    # Current installed version - try to auto-detect independently for server and client
    $serverDetected = $null
    $clientDetected = $null
    if (-not [string]::IsNullOrEmpty($config.ServerPath)) {
        $serverDetected = Get-InstalledGtnhVersion -InstancePath $config.ServerPath
        if ($serverDetected -eq 'unknown') { $serverDetected = $null }
    }
    if (-not [string]::IsNullOrEmpty($config.ClientInstancePath)) {
        $clientDetected = Get-InstalledGtnhVersion -InstancePath $config.ClientInstancePath
        if ($clientDetected -eq 'unknown') { $clientDetected = $null }
    }

    $hasServer = -not [string]::IsNullOrEmpty($config.ServerPath)
    $hasClient = -not [string]::IsNullOrEmpty($config.ClientInstancePath)

    if ($serverDetected -or $clientDetected) {
        Write-Host ""
        if ($serverDetected) {
            Write-Success "Detected server version: $serverDetected"
        }
        if ($clientDetected) {
            Write-Success "Detected client version: $clientDetected"
        }

        if ($serverDetected -and $clientDetected -and $serverDetected -ne $clientDetected) {
            Write-Warn "Server and client are on different versions."
        }

        Write-Info "Press Enter to accept, or type a version to override."

        if ($hasServer) {
            $serverVersion = Read-UserInput "Server version" -Default ($serverDetected ?? '')
            if ($serverVersion) {
                $config.InstalledServerVersion = $serverVersion
            }
        }
        if ($hasClient) {
            $clientVersion = Read-UserInput "Client version" -Default ($clientDetected ?? '')
            if ($clientVersion) {
                $config.InstalledClientVersion = $clientVersion
            }
        }

        if ($config.InstalledServerVersion -or $config.InstalledClientVersion) {
            $parts = @()
            if ($config.InstalledServerVersion) { $parts += "Server: $($config.InstalledServerVersion)" }
            if ($config.InstalledClientVersion) { $parts += "Client: $($config.InstalledClientVersion)" }
            Write-Success "Version set: $($parts -join ', ')"
        }
    } else {
        Write-Info ""
        Write-Info "Current GTNH version (leave blank if unsure):"
        Write-Host "  Examples: " -NoNewline -ForegroundColor Gray
        Write-Host "2.8.4" -NoNewline -ForegroundColor Cyan
        Write-Host " or " -NoNewline -ForegroundColor Gray
        Write-Host "2.8.0-beta-4" -ForegroundColor Cyan
        $currentVersion = Read-UserInput "Current GTNH version"
        if ($currentVersion) {
            if ($hasServer) {
                $config.InstalledServerVersion = $currentVersion
            }
            if ($hasClient) {
                $config.InstalledClientVersion = $currentVersion
            }
            Write-Success "Version set to: $currentVersion"
        }
    }

    # Optional: Custom mods prompt
    if ($hasServer -or $hasClient) {
        Write-Host ""
        Write-Info "If you have custom mods (not part of GTNH), you can add them now."
        Write-Info "They'll be preserved during updates. You can also do this later in Settings."
        if (Confirm-Action "Add custom mods now?") {
            if ($hasServer) {
                $serverModsDir = Join-Path $config.ServerPath 'mods'
                if (Test-Path -LiteralPath $serverModsDir) {
                    Write-Info "Browse server mods to mark as custom:"
                    # Inline browse - show all jars, let user pick
                    $allJars = @(Get-ChildItem -LiteralPath $serverModsDir -Filter '*.jar' -File | Sort-Object Name | ForEach-Object { $_.Name })
                    if ($allJars.Count -gt 0) {
                        Write-Info "Type numbers to add (comma-separated), or Enter to skip:"
                        $tagWidth = "[$($allJars.Count)]".Length
                        $displayCount = [math]::Min($allJars.Count, 30)
                        for ($i = 0; $i -lt $displayCount; $i++) {
                            $tag = "[$($i + 1)]".PadLeft($tagWidth)
                            Write-Host "    $tag $($allJars[$i])" -ForegroundColor Cyan
                        }
                        if ($allJars.Count -gt 30) {
                            Write-Info "    ... ($($allJars.Count) total, showing first 30. Add more in Settings.)"
                        }
                        Write-Host ""
                        Write-Host "  Select: " -NoNewline -ForegroundColor White
                        $picks = (Read-Host).Trim()
                        if ($picks) {
                            $selected = @()
                            foreach ($part in ($picks -split ',')) {
                                $idx = 0
                                if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $allJars.Count) {
                                    $selected += $allJars[$idx - 1]
                                }
                            }
                            if ($selected.Count -gt 0) {
                                $config.CustomServerMods = $selected
                                Write-Success "Added $($selected.Count) server custom mod(s)."
                            }
                        }
                    }
                }
            }
            if ($hasClient) {
                $clientModsDir = Join-Path $config.ClientInstancePath 'mods'
                if (Test-Path -LiteralPath $clientModsDir) {
                    Write-Info "Browse client mods to mark as custom:"
                    $allJars = @(Get-ChildItem -LiteralPath $clientModsDir -Filter '*.jar' -File | Sort-Object Name | ForEach-Object { $_.Name })
                    if ($allJars.Count -gt 0) {
                        Write-Info "Type numbers to add (comma-separated), or Enter to skip:"
                        $tagWidth = "[$($allJars.Count)]".Length
                        $displayCount = [math]::Min($allJars.Count, 30)
                        for ($i = 0; $i -lt $displayCount; $i++) {
                            $tag = "[$($i + 1)]".PadLeft($tagWidth)
                            Write-Host "    $tag $($allJars[$i])" -ForegroundColor Cyan
                        }
                        if ($allJars.Count -gt 30) {
                            Write-Info "    ... ($($allJars.Count) total, showing first 30. Add more in Settings.)"
                        }
                        Write-Host ""
                        Write-Host "  Select: " -NoNewline -ForegroundColor White
                        $picks = (Read-Host).Trim()
                        if ($picks) {
                            $selected = @()
                            foreach ($part in ($picks -split ',')) {
                                $idx = 0
                                if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $allJars.Count) {
                                    $selected += $allJars[$idx - 1]
                                }
                            }
                            if ($selected.Count -gt 0) {
                                $config.CustomClientMods = $selected
                                Write-Success "Added $($selected.Count) client custom mod(s)."
                            }
                        }
                    }
                }
            }
        }
    }

    # ========================================================================
    # Step 5: Summary and Save
    # ========================================================================
    Write-Header "Step 5/5: Configuration Summary"

    Show-CurrentConfig -Config $config

    # Warn if no paths configured
    if ([string]::IsNullOrEmpty($config.ServerPath) -and [string]::IsNullOrEmpty($config.ClientInstancePath)) {
        Write-Host ""
        Write-Warn "No server or client path configured. You won't be able to update until you set at least one."
        Write-Info "You can add paths later in Settings > Instance Paths."
    }

    # Warn if server and client are the same path
    if (-not [string]::IsNullOrEmpty($config.ServerPath) -and
        -not [string]::IsNullOrEmpty($config.ClientInstancePath) -and
        $config.ServerPath -eq $config.ClientInstancePath) {
        Write-Host ""
        Write-Warn "Server and client paths are the same! This will cause problems."
        Write-Info "Fix this in Settings > Instance Paths after saving."
    }

    Write-Info ""
    if (Confirm-Action "Save this configuration?") {
        Save-Config -Config $config
        Write-Success "Configuration saved."
    }
    else {
        Write-Warn "Configuration not saved. You can re-run setup from the Settings menu."
    }

    return $config
}
