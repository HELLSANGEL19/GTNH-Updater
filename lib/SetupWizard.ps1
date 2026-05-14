# ============================================================================
# Group 5: Setup Wizard - First-run interactive configuration
# ============================================================================
# Functions:
#   Test-GtnhPath            - Validate a path looks like a GTNH instance
#   Invoke-InteractiveSetup  - Multi-step wizard:
#                               1. Detect Java installations
#                               2. Ask what user manages (server/client/both)
#                               3. Detect server instances (if applicable)
#                               4. Detect client instances (if applicable)
#                               5. Set preferences (channel, pack type)
#                               6. Config patches
#                               7. Summary and save
#
# Presents detected options as numbered lists; manual entry is always the
# last option. Shows defaults in brackets, validates paths immediately.
# Steps 3/4 are skipped based on the user's answer in step 2.
# ============================================================================

function Resolve-InstancePath {
    <#
    .SYNOPSIS
        Resolve a user-provided path to the actual game root directory.
    .DESCRIPTION
        Users often paste a parent directory instead of the actual game root.
        This function checks if the given path directly contains mods/ (game root).
        If not, it searches common child folder names for the game root:
          - .minecraft (Prism/MultiMC/PolyMC client instances)
          - minecraft (some setups)
          - Minecraft (AMP and other server panels)
          - server (common standalone naming)
        Returns the resolved path if found, or the original path if it already
        looks correct or no child match is found.
    .PARAMETER Path
        The user-provided path.
    .PARAMETER Target
        'server' or 'client' - affects which child folders to prioritize.
    .OUTPUTS
        PSCustomObject with ResolvedPath and WasResolved boolean.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    # If the path directly has mods/, it's already the game root
    $modsDir = Join-Path $Path 'mods'
    if (Test-Path -LiteralPath $modsDir) {
        return [PSCustomObject]@{ ResolvedPath = $Path; WasResolved = $false }
    }

    # Common child folder names that might be the actual game root
    # Ordered by likelihood per target type
    $childCandidates = if ($Target -eq 'client') {
        @('.minecraft', 'minecraft', '.minecraft64', 'Minecraft')
    }
    else {
        @('Minecraft', 'minecraft', 'server', 'Server', '.minecraft')
    }

    foreach ($child in $childCandidates) {
        $candidatePath = Join-Path $Path $child
        if (Test-Path -LiteralPath $candidatePath) {
            $candidateMods = Join-Path $candidatePath 'mods'
            if (Test-Path -LiteralPath $candidateMods) {
                return [PSCustomObject]@{ ResolvedPath = $candidatePath; WasResolved = $true }
            }
        }
    }

    # No child match found - also try one level deeper for nested structures
    # (e.g., AMP: Instances/GTNH01/Minecraft/ where user pastes Instances/GTNH01/)
    try {
        $subDirs = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue | Select-Object -First 20
        foreach ($dir in $subDirs) {
            $subMods = Join-Path $dir.FullName 'mods'
            if (Test-Path -LiteralPath $subMods) {
                # Verify it looks like a game directory (has config/ too, not just a random mods/ folder)
                $subConfig = Join-Path $dir.FullName 'config'
                if (Test-Path -LiteralPath $subConfig) {
                    return [PSCustomObject]@{ ResolvedPath = $dir.FullName; WasResolved = $true }
                }
            }
        }
    }
    catch {
        # Access denied or other error scanning children - just return original
    }

    # Return original path unchanged
    return [PSCustomObject]@{ ResolvedPath = $Path; WasResolved = $false }
}

function Test-JavaBinary {
    <#
    .SYNOPSIS
        Validate that a path points to an actual Java binary.
    .DESCRIPTION
        Checks that the file exists, has the expected name (java or java.exe),
        and responds to -version. Returns $true if valid, $false otherwise.
    .PARAMETER Path
        The file path to validate.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    # Check it's a file, not a directory
    if ((Get-Item -LiteralPath $Path).PSIsContainer) {
        Write-Warn "Path is a directory, not a file. Point to the java binary itself."
        return $false
    }

    # Check filename looks like java
    $fileName = Split-Path -Leaf $Path
    $validNames = @('java', 'java.exe')
    if ($fileName.ToLower() -notin $validNames) {
        Write-Warn "File is '$fileName' - expected 'java' or 'java.exe'."
        return (Confirm-Action "Use this path anyway?")
    }

    # Try running java -version to verify it works
    try {
        $stderrFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath $Path -ArgumentList '-version' -Wait -PassThru -NoNewWindow `
            -RedirectStandardError $stderrFile -ErrorAction Stop
        # Clean up the temp file
        try { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue } catch {}
        if ($proc.ExitCode -eq 0) {
            return $true
        }
        Write-Warn "Java at this path returned exit code $($proc.ExitCode)."
        return (Confirm-Action "Use this path anyway?")
    }
    catch {
        # Clean up temp file on error path too
        if ($stderrFile -and (Test-Path -LiteralPath $stderrFile)) {
            try { Remove-Item -LiteralPath $stderrFile -Force } catch {}
        }
        Write-Warn "Could not execute Java at this path: $($_.Exception.Message)"
        return (Confirm-Action "Use this path anyway?")
    }
}

function Test-GtnhPath {
    <#
    .SYNOPSIS
        Validate a path looks like a GTNH instance, auto-resolving if needed.
    .DESCRIPTION
        First tries to resolve the path to the actual game root (in case the user
        pasted a parent directory). Then validates the resolved path has the expected
        structure. Returns the resolved path via [ref] if it was auto-corrected.
    .PARAMETER Path
        The path to check (passed by reference so it can be updated if resolved).
    .PARAMETER Target
        'server' or 'client' - affects what we look for.
    .OUTPUTS
        $true if the path looks valid or the user confirms anyway.
        The $Path variable is updated in-place if auto-resolved.
    #>
    param(
        [Parameter(Mandatory)][ref]$Path,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    $inputPath = $Path.Value

    # Try to resolve to the actual game root
    $resolved = Resolve-InstancePath -Path $inputPath -Target $Target
    if ($resolved.WasResolved) {
        Write-Info "Auto-detected game root: $($resolved.ResolvedPath)"
        Write-Info "  (resolved from: $inputPath)"
        $Path.Value = $resolved.ResolvedPath
        $inputPath = $resolved.ResolvedPath
    }

    $issues = @()

    # Check for mods/ folder
    $modsPath = Join-Path $inputPath 'mods'
    if (-not (Test-Path -LiteralPath $modsPath)) {
        $issues += "No mods/ folder found"
    } else {
        # Check for GTNH-specific mods
        if (-not (Test-IsGtnhInstance -ModsPath $modsPath)) {
            $issues += "No GregTech mods found in mods/ (may not be a GTNH instance)"
        }
    }

    # Check for config/ folder
    $configPath = Join-Path $inputPath 'config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $issues += "No config/ folder found"
    }

    # Server-specific checks
    if ($Target -eq 'server') {
        $serverProps = Join-Path $inputPath 'server.properties'
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
    Write-Header "Step 1/7: Java Installation"

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
        Write-MenuOption "S" "Skip"

        $javaBinaryName = if ($IsWindows) { 'java.exe' } else { 'java' }
        $defaultHint = $recommendedIdx -ge 0 ? " [default: $($recommendedIdx + 1)]" : ""
        $javaChoice = Read-MenuChoice "Select Java installation$defaultHint"

        # Auto-select recommended if user just presses Enter
        if ([string]::IsNullOrEmpty($javaChoice) -and $recommendedIdx -ge 0) {
            $config.JavaPath = $javaInstalls[$recommendedIdx].Path
        }
        elseif ($javaChoice -eq 'S' -or $javaChoice -eq 's') {
            Write-Info "Java configuration skipped."
        }
        elseif ($javaChoice -eq 'M' -or $javaChoice -eq 'm') {
            $javaPrompt = if ($IsWindows) { "Enter the full path to java.exe (not javaw.exe)" } else { "Enter the full path to the java binary" }
            $javaPath = Read-UserInput $javaPrompt
            while ($javaPath -and -not (Test-Path -LiteralPath $javaPath)) {
                Write-Warn "Path not found: $javaPath"
                $javaPath = Read-UserInput $javaPrompt
            }
            if ($javaPath) {
                if (Test-JavaBinary -Path $javaPath) {
                    $config.JavaPath = $javaPath
                } else {
                    Write-Info "Java path not set."
                }
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
        $javaPrompt = if ($IsWindows) { "Enter the full path to java.exe (not javaw.exe), or press Enter to skip" } else { "Enter the full path to the java binary, or press Enter to skip" }
        $javaPath = Read-UserInput $javaPrompt
        if ($javaPath) {
            while ($javaPath -and -not (Test-Path -LiteralPath $javaPath)) {
                Write-Warn "Path not found: $javaPath"
                $javaPrompt2 = if ($IsWindows) { "Enter the full path to java.exe, or press Enter to skip" } else { "Enter the full path to the java binary, or press Enter to skip" }
                $javaPath = Read-UserInput $javaPrompt2
            }
            if ($javaPath) {
                if (Test-JavaBinary -Path $javaPath) {
                    $config.JavaPath = $javaPath
                } else {
                    Write-Info "Java path not set."
                }
            }
        }
    }

    if ($config.JavaPath) {
        Write-Success "Java path set: $($config.JavaPath)"
    }

    # ========================================================================
    # Step 2: What are you managing?
    # ========================================================================
    Write-Header "Step 2/7: What do you manage?"

    Write-Info "What will you use this updater for?"
    Write-MenuOption "1" "Server only (dedicated server, no client on this machine)"
    Write-MenuOption "2" "Client only (Prism Launcher, MultiMC, etc.)"
    Write-MenuOption "3" "Both server and client"

    $manageChoice = Read-MenuChoice "Select option"
    $wantServer = $manageChoice -eq '1' -or $manageChoice -eq '3'
    $wantClient = $manageChoice -eq '2' -or $manageChoice -eq '3'

    # Default to both if invalid input
    if (-not $wantServer -and -not $wantClient) {
        Write-Info "Defaulting to both server and client."
        $wantServer = $true
        $wantClient = $true
    }

    # ========================================================================
    # Step 3: Server Instance Detection (skipped if not managing a server)
    # ========================================================================
    if ($wantServer) {
    Write-Header "Step 3/7: GTNH Server Instance"

    $serverInstances = Find-ServerInstances

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
            if ($serverPath -and (Test-GtnhPath -Path ([ref]$serverPath) -Target 'server')) {
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
            if ($serverPath -and (Test-GtnhPath -Path ([ref]$serverPath) -Target 'server')) {
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
    } # end if ($wantServer)

    # ========================================================================
    # Step 4: Client Instance Detection (skipped if not managing a client)
    # ========================================================================
    if ($wantClient) {
    Write-Header "Step 4/7: GTNH Client Instance (Prism Launcher)"

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
            if ($clientPath -and (Test-GtnhPath -Path ([ref]$clientPath) -Target 'client')) {
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
            if ($clientPath -and (Test-GtnhPath -Path ([ref]$clientPath) -Target 'client')) {
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
    } # end if ($wantClient)

    # ========================================================================
    # Step 5: Preferences
    # ========================================================================
    Write-Header "Step 5/7: Preferences"

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
            $serverDisplay = $serverDetected -replace 'nightly-', '' -replace 'experimental-', ''
            Write-Success "Detected server version: $serverDisplay"
        }
        if ($clientDetected) {
            $clientDisplay = $clientDetected -replace 'nightly-', '' -replace 'experimental-', ''
            Write-Success "Detected client version: $clientDisplay"
        }

        if ($serverDetected -and $clientDetected -and $serverDetected -ne $clientDetected) {
            Write-Warn "Server and client are on different versions."
        }

        Write-Info "Press Enter to accept, or type a version to override."

        if ($hasServer) {
            $serverVersion = $null
            do {
                $input = Read-UserInput "Server version" -Default ($serverDetected ?? '')
                if (-not $input -or $input -eq ($serverDetected ?? '')) { $serverVersion = $serverDetected; break }
                if ($input -match '^(?:GTNH-)?(\d{4}-\d{2}-\d{2})') { $serverVersion = "nightly-$($Matches[1])"; break }
                if ($input -match '^nightly-') { $serverVersion = $input; break }
                if ($input -match '^\d+\.\d+\.\d+') { $serverVersion = $input }
                else { Write-Warn "Enter a version like 2.8.4 or 2026-05-01. Daily users can press Enter to skip." }
            } while (-not $serverVersion)
            if ($serverVersion) { $config.InstalledServerVersion = $serverVersion }
        }
        if ($hasClient) {
            $clientVersion = $null
            do {
                $input = Read-UserInput "Client version" -Default ($clientDetected ?? '')
                if (-not $input -or $input -eq ($clientDetected ?? '')) { $clientVersion = $clientDetected; break }
                if ($input -match '^(?:GTNH-)?(\d{4}-\d{2}-\d{2})') { $clientVersion = "nightly-$($Matches[1])"; break }
                if ($input -match '^nightly-') { $clientVersion = $input; break }
                if ($input -match '^\d+\.\d+\.\d+') { $clientVersion = $input }
                else { Write-Warn "Enter a version like 2.8.4 or 2026-05-01. Daily users can press Enter to skip." }
            } while (-not $clientVersion)
            if ($clientVersion) { $config.InstalledClientVersion = $clientVersion }
        }

        if ($config.InstalledServerVersion -or $config.InstalledClientVersion) {
            $parts = @()
            if ($config.InstalledServerVersion) { $parts += "Server: $($config.InstalledServerVersion)" }
            if ($config.InstalledClientVersion) { $parts += "Client: $($config.InstalledClientVersion)" }
            Write-Success "Version set: $($parts -join ', ')"
        }
    } else {
        Write-Info ""
        Write-Info "Current GTNH version (leave blank if unsure or on daily/experimental):"
        Write-Host "  Examples: " -NoNewline -ForegroundColor Gray
        Write-Host "2.8.4" -NoNewline -ForegroundColor Cyan
        Write-Host ", " -NoNewline -ForegroundColor Gray
        Write-Host "2.8.0-beta-4" -ForegroundColor Cyan
        Write-Info "  (Daily/experimental users: skip this and just run an update)"
        $currentVersion = $null
        do {
            $input = Read-UserInput "Current GTNH version"
            if (-not $input) { break }
            if ($input -match '^(?:GTNH-)?(\d{4}-\d{2}-\d{2})') {
                $currentVersion = "nightly-$($Matches[1])"
                Write-Info "  Recognized as dev build: $($Matches[1])"
                break
            }
            if ($input -match '^\d+\.\d+\.\d+') { $currentVersion = $input }
            elseif ($input -match '\d{4}-\d{2}-\d{2}') {
                # Accept any format with a date in it as a nightly indicator
                $dateMatch = [regex]::Match($input, '\d{4}-\d{2}-\d{2}').Value
                $currentVersion = "nightly-$dateMatch"
                Write-Info "  Recognized as dev build: $dateMatch"
                break
            }
            else { Write-Warn "Enter a version like 2.8.4 or 2.8.0-beta-4. Daily users can leave blank." }
        } while (-not $currentVersion)
        if ($currentVersion) {
            if ($hasServer) { $config.InstalledServerVersion = $currentVersion }
            if ($hasClient) { $config.InstalledClientVersion = $currentVersion }
            Write-Success "Version set to: $currentVersion"
        }
    }

    # Optional: Custom mods prompt
    if ($hasServer -or $hasClient) {
        Write-Host ""
        Write-Info "If you have custom mods (not part of GTNH), they need to be tracked"
        Write-Info "so they're preserved during updates."
        Write-Host ""
        Write-MenuOption "S" "Scan (downloads pack zip, auto-detects your custom mods)"
        Write-MenuOption "B" "Browse mods/ folder and pick manually"
        Write-MenuOption "K" "Skip (do this later in Settings > Custom Mods)"

        $customChoice = Read-MenuChoice "Choose"

        if ($customChoice -eq 's' -or $customChoice -eq 'S') {
            # Use the scan approach - download pack zip and compare
            $scanTargets = @()
            if ($hasServer) { $scanTargets += 'server' }
            if ($hasClient) { $scanTargets += 'client' }

            foreach ($scanTarget in $scanTargets) {
                $scanLabel = $scanTarget -eq 'server' ? 'Server' : 'Client'
                $scanVer = $scanTarget -eq 'server' ? $config.InstalledServerVersion : $config.InstalledClientVersion
                $scanPath = $scanTarget -eq 'server' ? $config.ServerPath : $config.ClientInstancePath

                if ([string]::IsNullOrWhiteSpace($scanVer) -or $scanVer -eq 'unknown') {
                    Write-Warn "No version set for $scanLabel - skipping scan."
                    continue
                }
                if ([string]::IsNullOrEmpty($scanPath) -or -not (Test-Path -LiteralPath $scanPath)) {
                    continue
                }
                $scanModsDir = Join-Path $scanPath 'mods'
                if (-not (Test-Path -LiteralPath $scanModsDir)) { continue }

                # Find the release
                $scanReleases = $script:CachedWebsiteReleases ?? (Get-WebsiteReleases -PackType ($config.JavaVersion ?? 'java17'))
                $scanRelease = $null
                if ($scanReleases) {
                    $scanRelease = $scanReleases | Where-Object { $_.Version -eq $scanVer } | Select-Object -First 1
                }
                if (-not $scanRelease) {
                    Write-Warn "Could not find v${scanVer} in releases - skipping $scanLabel scan."
                    continue
                }

                $scanZipUrl = if ($scanTarget -eq 'server') { $scanRelease.ServerZipUrl } else { $scanRelease.ClientZipUrl }
                $scanZipName = if ($scanTarget -eq 'server') { $scanRelease.ServerZipName } else { $scanRelease.ClientZipName }
                if (-not $scanZipUrl) { continue }

                # Check cache or download
                $scanCached = Get-CachedFile -FileName $scanZipName
                if ($scanCached) {
                    Write-Info "Using cached $scanLabel pack: $scanZipName"
                } else {
                    Write-Info "Downloading v${scanVer} $($scanLabel.ToLower()) pack for comparison..."
                }

                $scanTempDir = $script:TempDir
                if (-not (Test-Path -LiteralPath $scanTempDir)) {
                    New-Item -Path $scanTempDir -ItemType Directory -Force | Out-Null
                }
                $scanZipPath = Join-Path $scanTempDir $scanZipName

                if ($scanCached) {
                    try { Copy-Item -LiteralPath $scanCached -Destination $scanZipPath -Force } catch { continue }
                } else {
                    $dlResult = Invoke-FileDownload -Url $scanZipUrl -OutPath $scanZipPath -Description "v${scanVer} $scanLabel pack"
                    if (-not $dlResult) {
                        Write-Warn "Download failed - skipping $scanLabel scan."
                        continue
                    }
                }

                # Read mod filenames from zip
                $scanZip = $null
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                    $scanZip = [System.IO.Compression.ZipFile]::OpenRead($scanZipPath)
                    $officialModFiles = @()
                    foreach ($entry in $scanZip.Entries) {
                        if ($entry.FullName -match '(?:^|/)mods/([^/]+\.jar)$') {
                            $officialModFiles += $Matches[1]
                        }
                    }
                }
                catch {
                    Write-Warn "Could not read zip - skipping $scanLabel scan."
                    continue
                }
                finally {
                    if ($scanZip) { try { $scanZip.Dispose() } catch {} }
                    if (Test-Path -LiteralPath $scanZipPath) {
                        try { Remove-Item -LiteralPath $scanZipPath -Force } catch {}
                    }
                }

                if ($officialModFiles.Count -eq 0) { continue }

                # Compare
                $officialBaseNames = @{}
                foreach ($modFile in $officialModFiles) {
                    $officialBaseNames[(Get-ModBaseName -FileName $modFile)] = $true
                }

                $localJars = @(Get-ChildItem -LiteralPath $scanModsDir -Filter '*.jar' -File | ForEach-Object { $_.Name })
                $customFound = @()
                foreach ($jar in $localJars) {
                    if (-not $officialBaseNames.ContainsKey((Get-ModBaseName -FileName $jar))) {
                        $customFound += $jar
                    }
                }

                if ($customFound.Count -gt 0) {
                    Write-Host ""
                    Write-Info "Found $($customFound.Count) custom $($scanLabel.ToLower()) mod(s):"
                    foreach ($mod in ($customFound | Sort-Object)) {
                        Write-Host "    * $mod" -ForegroundColor Cyan
                    }
                    Write-Host ""
                    if (Confirm-Action "Track all $($customFound.Count) as custom $($scanLabel.ToLower()) mods?") {
                        if ($scanTarget -eq 'server') {
                            $config.CustomServerMods = $customFound
                        } else {
                            $config.CustomClientMods = $customFound
                        }
                        Write-Success "Added $($customFound.Count) custom $($scanLabel.ToLower()) mod(s)."
                    }
                } else {
                    Write-Success "No custom $($scanLabel.ToLower()) mods detected - all mods match the official pack."
                }
            }
        }
        elseif ($customChoice -eq 'b' -or $customChoice -eq 'B') {
            # Reusable paginated mod picker scriptblock
            $pickCustomMods = {
                param([string]$ModsDir, [string]$Label)
                $allJars = @(Get-ChildItem -LiteralPath $ModsDir -Filter '*.jar' -File | Sort-Object Name | ForEach-Object { $_.Name })
                if ($allJars.Count -eq 0) { return @() }
                $pageSize = 30
                $page = 0
                $selected = @()
                while ($true) {
                    $totalPages = [math]::Ceiling($allJars.Count / $pageSize)
                    $start = $page * $pageSize
                    $end = [math]::Min($start + $pageSize, $allJars.Count) - 1
                    $tagWidth = "[$($allJars.Count)]".Length
                    Write-Info "Browse $Label mods (page $($page+1)/$totalPages, $($allJars.Count) total):"
                    Write-Info "Type numbers to add (comma-separated), N/P for pages, Enter to skip:"
                    for ($i = $start; $i -le $end; $i++) {
                        $tag = "[$($i + 1)]".PadLeft($tagWidth)
                        Write-Host "    $tag $($allJars[$i])" -ForegroundColor Cyan
                    }
                    Write-Host ""
                    $picks = (Read-UserInput "Selection (or N/P to page)").Trim()
                    if (-not $picks) { break }
                    if ($picks -eq 'n' -or $picks -eq 'N') { if ($page -lt $totalPages - 1) { $page++ }; continue }
                    if ($picks -eq 'p' -or $picks -eq 'P') { if ($page -gt 0) { $page-- }; continue }
                    foreach ($part in ($picks -split ',')) {
                        $idx = 0
                        if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $allJars.Count) {
                            $selected += $allJars[$idx - 1]
                        }
                    }
                    break
                }
                return $selected
            }

            if ($hasServer) {
                $serverModsDir = Join-Path $config.ServerPath 'mods'
                if (Test-Path -LiteralPath $serverModsDir) {
                    $selected = & $pickCustomMods $serverModsDir 'server'
                    if ($selected.Count -gt 0) {
                        $config.CustomServerMods = $selected
                        Write-Success "Added $($selected.Count) server custom mod(s)."
                    }
                }
            }
            if ($hasClient) {
                $clientModsDir = Join-Path $config.ClientInstancePath 'mods'
                if (Test-Path -LiteralPath $clientModsDir) {
                    $selected = & $pickCustomMods $clientModsDir 'client'
                    if ($selected.Count -gt 0) {
                        $config.CustomClientMods = $selected
                        Write-Success "Added $($selected.Count) client custom mod(s)."
                    }
                }
            }
        }
        # 'K' or anything else = skip
    }

    # ========================================================================
    # Step 6: Config Patches
    # ========================================================================
    Write-Header "Step 6/7: Config Patches"
    Write-Info "Config patches let you toggle common settings (explosions, channels, etc.)"
    Write-Info "You can skip this and manage patches later via Settings > Config Patches."
    Write-Host ""
    if (Confirm-Action "Set up config patches now?") {
        Invoke-ConfigPatchMenu -Config $config
    }

    # ========================================================================
    # Step 7: Summary and Save
    # ========================================================================
    Write-Header "Step 7/7: Configuration Summary"

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

        # Offer to set up a second profile â€” only when there's currently just one
        $existingProfiles = Get-ProfileList
        if ($existingProfiles.Count -eq 1) {
            Write-Host ""
            Write-Info "You can manage multiple independent instances (e.g. a daily test server)"
            Write-Info "using profiles. Each profile has its own paths, channel, and mod list."
            Write-Host ""
            if (Confirm-Action "Set up an additional profile now?") {
                # Delegate to the profile menu's create flow
                $dummyConfig = $config  # profile menu needs a config to copy from
                $null = Invoke-ProfileMenu -Config $dummyConfig
            }
        }
    }
    else {
        Write-Warn "Configuration not saved. You can re-run setup from the Settings menu."
    }

    return $config
}


