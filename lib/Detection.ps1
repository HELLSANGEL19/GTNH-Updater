# ============================================================================
# Group 4: Instance & Java Detection - Auto-detect installations and Java paths
# ============================================================================
# Functions:
#   Find-JavaInstallations   - Scan common paths, JAVA_HOME, PATH for java binary;
#                               return sorted list with major version
#                               (Windows: Program Files; Linux: /usr/lib/jvm, etc.)
#   Find-ServerInstances     - Scan drives/common paths for server.properties
#                               co-located with GTNH mod JARs
#   Find-PrismInstances      - Scan launcher instance directories for
#                               GTNH client instances
#   Test-IsGtnhInstance      - Check if a mods/ folder contains GregTech/GT5 JARs
#   Get-InstalledGtnhVersion - Detect version from gtnh_version.txt or
#                               changelog filenames, return 'unknown' if not found
#
# All registry and file system access is wrapped in try/catch blocks.
# Cross-platform: uses $IsWindows/$IsLinux to branch platform-specific logic.
# ============================================================================

function Find-JavaInstallations {
    <#
    .SYNOPSIS
        Scan common Java installation locations, JAVA_HOME, and PATH for the java binary.
    .DESCRIPTION
        On Windows: searches Adoptium, Oracle, Microsoft, Zulu, and BellSoft install
        directories in Program Files and Program Files (x86), plus JAVA_HOME and PATH.
        On Linux: searches /usr/lib/jvm/, /usr/local/lib/jvm/, /opt/java/, common
        SDKMAN paths, plus JAVA_HOME and PATH (via 'which java').
        For each found java binary, runs -version to determine the major version.
        Returns an array of PSCustomObjects sorted by MajorVersion descending.
    .OUTPUTS
        Array of [PSCustomObject]@{ Path; MajorVersion; VersionText }
    #>

    Write-Step "Scanning for Java installations..."

    $found = @{}  # Use hashtable to deduplicate by resolved path
    $javaBinaryName = if ($IsWindows) { 'java.exe' } else { 'java' }

    if ($IsWindows) {
        # Windows: scan Program Files directories
        $searchPatterns = @(
            "$env:ProgramFiles\Eclipse Adoptium\*\bin\java.exe"
            "$env:ProgramFiles\Java\*\bin\java.exe"
            "$env:ProgramFiles\Microsoft\*\bin\java.exe"
            "$env:ProgramFiles\Zulu\*\bin\java.exe"
            "$env:ProgramFiles\BellSoft\*\bin\java.exe"
            "${env:ProgramFiles(x86)}\Eclipse Adoptium\*\bin\java.exe"
            "${env:ProgramFiles(x86)}\Java\*\bin\java.exe"
        )

        foreach ($pattern in $searchPatterns) {
            try {
                $javaFiles = Get-Item -Path $pattern -ErrorAction SilentlyContinue
                foreach ($item in $javaFiles) {
                    $resolved = $item.FullName
                    if (-not $found.ContainsKey($resolved)) {
                        $found[$resolved] = $true
                    }
                }
            }
            catch {
                # Silently continue if path doesn't exist
            }
        }
    }
    else {
        # Linux: scan common JVM installation directories
        $linuxSearchDirs = @(
            '/usr/lib/jvm'
            '/usr/local/lib/jvm'
            '/opt/java'
            '/opt/jdk'
        )

        # SDKMAN candidates
        $sdkmanDir = Join-Path $HOME '.sdkman/candidates/java'
        if (Test-Path -LiteralPath $sdkmanDir) {
            $linuxSearchDirs += $sdkmanDir
        }

        foreach ($searchDir in $linuxSearchDirs) {
            if (-not (Test-Path -LiteralPath $searchDir)) { continue }
            try {
                $javaBinaries = Get-ChildItem -LiteralPath $searchDir -Filter 'java' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -like '*/bin/java' -and -not $_.PSIsContainer }
                foreach ($item in $javaBinaries) {
                    $resolved = $item.FullName
                    if (-not $found.ContainsKey($resolved)) {
                        $found[$resolved] = $true
                    }
                }
            }
            catch {
                # Silently continue
            }
        }
    }

    # Check JAVA_HOME (cross-platform)
    if ($env:JAVA_HOME) {
        try {
            $javaHomePath = Join-Path $env:JAVA_HOME "bin/$javaBinaryName"
            if (Test-Path -LiteralPath $javaHomePath) {
                $resolved = (Get-Item -LiteralPath $javaHomePath).FullName
                if (-not $found.ContainsKey($resolved)) {
                    $found[$resolved] = $true
                }
            }
        }
        catch {
            # Silently continue
        }
    }

    # Check PATH via Get-Command (cross-platform)
    try {
        $pathJava = Get-Command 'java' -ErrorAction SilentlyContinue
        if ($pathJava) {
            $resolved = $pathJava.Source
            # Resolve symlinks on Linux
            if ($IsLinux -and $resolved) {
                try {
                    $resolvedTarget = (Get-Item -LiteralPath $resolved).Target
                    if ($resolvedTarget) { $resolved = $resolvedTarget }
                }
                catch {
                    # Keep original path
                }
            }
            if ($resolved -and (-not $found.ContainsKey($resolved))) {
                $found[$resolved] = $true
            }
        }
    }
    catch {
        # Silently continue
    }

    # For each found java binary, get version info
    $results = @()
    $seenVersions = @{}  # Deduplicate by version output (catches symlinks/shims)

    foreach ($javaExe in $found.Keys) {
        try {
            $versionOutput = & $javaExe -version 2>&1 | Out-String
            $majorVersion = 0
            if ($versionOutput -match '"(\d+)') {
                $majorVersion = [int]$Matches[1]
            }
            $versionText = ($versionOutput -split "`n")[0].Trim()

            # Skip if we already have this exact version (symlink/shim duplicate)
            if ($seenVersions.ContainsKey($versionText)) {
                Write-Log "[JAVA] Skipping duplicate: $javaExe (same as $($seenVersions[$versionText]))"
                continue
            }
            $seenVersions[$versionText] = $javaExe

            $results += [PSCustomObject]@{
                Path         = $javaExe
                MajorVersion = $majorVersion
                VersionText  = $versionText
            }
        }
        catch {
            $results += [PSCustomObject]@{
                Path         = $javaExe
                MajorVersion = 0
                VersionText  = '(unknown version)'
            }
        }
    }

    # Sort by MajorVersion descending
    $results = $results | Sort-Object -Property MajorVersion -Descending

    Write-Info "Found $($results.Count) Java installation(s)."
    return $results
}

function Test-IsGtnhInstance {
    <#
    .SYNOPSIS
        Check if a mods folder contains GTNH mod JARs.
    .PARAMETER ModsPath
        Path to the mods/ directory to check.
    .OUTPUTS
        Boolean - $true if GTNH mods are detected.
    #>
    param(
        [Parameter(Mandatory)][string]$ModsPath
    )

    if (-not (Test-Path -LiteralPath $ModsPath)) {
        return $false
    }

    try {
        $jars = Get-ChildItem -LiteralPath $ModsPath -Filter '*.jar' -ErrorAction SilentlyContinue
        foreach ($jar in $jars) {
            $name = $jar.Name
            if ($name -like '*gregtech*' -or
                $name -like '*GT5-Unofficial*' -or
                $name -like '*dreamcraft*' -or
                $name -like '*bartworks*' -or
                $name -like '*gtnewhorizons*') {
                return $true
            }
        }
    }
    catch {
        # Silently continue
    }

    return $false
}

function Get-InstalledGtnhVersion {
    <#
    .SYNOPSIS
        Detect the installed GTNH version from instance files.
    .DESCRIPTION
        Tries multiple detection methods in order:
          1. gtnh_version.txt - Written by the nightly updater JAR
          2. Changelog filenames - Pack zips include files like
             "changelog from 2.7.3 to 2.7.4.txt"; the highest "to" version
             across all changelog files is the installed version
        Returns 'unknown' if no version can be determined.
    .PARAMETER InstancePath
        Path to the instance root directory.
    .OUTPUTS
        Version string or 'unknown'.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath
    )

    # Method 1a: Native nightly state file (our updater's state tracking)
    $nativeStateFile = Join-Path $InstancePath '.gtnh-nightly-state.json'
    if (Test-Path -LiteralPath $nativeStateFile) {
        try {
            $nativeState = Get-Content -LiteralPath $nativeStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($nativeState.InstalledVersion) {
                return $nativeState.InstalledVersion
            }
        } catch {
            # Fall through to next method
        }
    }

    # Method 1b: Caedis daily updater state file (legacy, for instances previously managed by Caedis)
    # Check at instance root (server) or parent of .minecraft (client)
    $stateFile = Join-Path $InstancePath '.gtnh-daily-updater.json'
    $parentStateFile = Join-Path (Split-Path -Parent $InstancePath) '.gtnh-daily-updater.json'
    $stateToCheck = if (Test-Path -LiteralPath $stateFile) { $stateFile }
                    elseif (Test-Path -LiteralPath $parentStateFile) { $parentStateFile }
                    else { $null }
    if ($stateToCheck) {
        try {
            $stateContent = Get-Content -LiteralPath $stateToCheck -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($stateContent.configVersion) {
                return $stateContent.configVersion
            }
        } catch {
            # Fall through to next method
        }
    }

    # Method 2: gtnh_version.txt (written by the old nightly updater JAR)
    $versionFile = Join-Path $InstancePath 'gtnh_version.txt'
    if (Test-Path -LiteralPath $versionFile) {
        try {
            $content = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim()
            # Validate it looks like a version (at least X.Y format)
            if ($content -and $content -match '^\d+\.\d+') {
                return $content
            }
        }
        catch {
            # Fall through to next method
        }
    }

    # Method 2: Changelog filenames
    # Pack zips include files like "changelog from 2.7.3 to 2.7.4.txt"
    # or "changelog from 2.8.0-beta-1 to 2.8.0-beta-2.txt"
    # The highest "to" version is the installed version.
    try {
        $changelogFiles = Get-ChildItem -LiteralPath $InstancePath -Filter 'changelog from *' -File -ErrorAction SilentlyContinue
        if ($changelogFiles -and $changelogFiles.Count -gt 0) {
            $toVersions = @()
            foreach ($file in $changelogFiles) {
                if ($file.Name -match 'changelog from .+ to (\d+\.\d+\.\d+(?:[-_](?:beta|rc)[-_]?\d*)?)') {
                    $toVersions += $Matches[1]
                }
            }

            if ($toVersions.Count -gt 0) {
                if ($toVersions.Count -eq 1) {
                    return $toVersions[0]
                }
                # Sort: highest base version first, then stable before beta for same base
                $sorted = $toVersions | Sort-Object {
                    $base = '0.0.0'
                    if ($_ -match '^(\d+\.\d+\.\d+)') { $base = $Matches[1] }
                    [version]$base
                } -Descending
                # Among same-base versions, prefer stable (no suffix) over beta
                $topBase = '0.0.0'
                if ($sorted[0] -match '^(\d+\.\d+\.\d+)') { $topBase = $Matches[1] }
                $topGroup = @($sorted | Where-Object { $_ -match "^$([regex]::Escape($topBase))" })
                $stable = $topGroup | Where-Object { $_ -notmatch '[-_](beta|rc)' } | Select-Object -First 1
                if ($stable) { return $stable }
                return $topGroup[0]
            }
        }
    }
    catch {
        # Fall through to return unknown
    }

    return 'unknown'
}

function Find-ServerInstances {
    <#
    .SYNOPSIS
        Scan common paths for GTNH server instances.
    .DESCRIPTION
        On Windows: checks common server hosting paths (AMP/CubeCoders, standalone
        server folders, common naming patterns) on each fixed drive.
        On Linux: checks common server paths under /home, /opt, /srv, and ~.
        Looks for server.properties files co-located with GTNH mod JARs.
    .OUTPUTS
        Array of [PSCustomObject]@{ Name; Path; Version }
    #>

    Write-Step "Scanning for GTNH server instances..."

    $results = @()
    $foundPaths = @{}  # Deduplicate

    if ($IsWindows) {
        # Get all fixed drives
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null }

        $commonPaths = @(
            'AMPDatastore'
            'AMP'
            'CubeCoders'
            'CubeCoders\AMP'
            'GameServers'
            'Servers'
            'MinecraftServers'
            'Minecraft'
            'GTNH'
            'GT New Horizons'
            'Program Files\CubeCoders'
            'Program Files\AMP'
            'Program Files\Minecraft'
        )

        foreach ($drive in $drives) {
            $driveRoot = $drive.Root

            # Check common paths
            foreach ($subPath in $commonPaths) {
                $searchRoot = Join-Path $driveRoot $subPath
                if (-not (Test-Path -LiteralPath $searchRoot)) {
                    continue
                }

                try {
                    # Search up to depth 5 for server.properties
                    $serverProps = Get-ChildItem -LiteralPath $searchRoot -Filter 'server.properties' -Recurse -Depth 5 -ErrorAction SilentlyContinue

                    foreach ($prop in $serverProps) {
                        $instanceDir = $prop.DirectoryName
                        if ($foundPaths.ContainsKey($instanceDir)) { continue }

                        $modsPath = Join-Path $instanceDir 'mods'

                        if (Test-IsGtnhInstance -ModsPath $modsPath) {
                            $name = Split-Path $instanceDir -Leaf
                            $version = Get-InstalledGtnhVersion -InstancePath $instanceDir

                            $results += [PSCustomObject]@{
                                Name    = $name
                                Path    = $instanceDir
                                Version = $version
                            }
                            $foundPaths[$instanceDir] = $true
                        }
                    }
                }
                catch {
                    # Silently continue if access denied or other error
                }
            }

            # Also check drive root for folders with "GTNH" or "horizons" in the name
            try {
                $rootDirs = Get-ChildItem -LiteralPath $driveRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'gtnh|horizons|minecraft.*server' }

                foreach ($dir in $rootDirs) {
                    $serverPropsPath = Join-Path $dir.FullName 'server.properties'
                    if ((Test-Path -LiteralPath $serverPropsPath) -and -not $foundPaths.ContainsKey($dir.FullName)) {
                        $modsPath = Join-Path $dir.FullName 'mods'
                        if (Test-IsGtnhInstance -ModsPath $modsPath) {
                            $name = $dir.Name
                            $version = Get-InstalledGtnhVersion -InstancePath $dir.FullName

                            $results += [PSCustomObject]@{
                                Name    = $name
                                Path    = $dir.FullName
                                Version = $version
                            }
                            $foundPaths[$dir.FullName] = $true
                        }
                    }
                }
            }
            catch {
                # Silently continue
            }
        }
    }
    else {
        # Linux: check common server locations
        $linuxSearchRoots = @(
            '/opt'
            '/srv'
            (Join-Path $HOME 'Games')
            (Join-Path $HOME 'games')
            (Join-Path $HOME 'servers')
            (Join-Path $HOME 'minecraft')
            (Join-Path $HOME 'GTNH')
            $HOME
        )

        foreach ($searchRoot in $linuxSearchRoots) {
            if (-not (Test-Path -LiteralPath $searchRoot)) { continue }

            try {
                # Exclude common large directories that won't contain Minecraft servers
                $excludeDirs = @('.cache', 'node_modules', '.npm', '.local/lib', 'Downloads',
                    '.steam', '.var', 'snap', '.gradle', '.m2', '.cargo', '.rustup')
                $serverProps = Get-ChildItem -LiteralPath $searchRoot -Filter 'server.properties' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                    Where-Object {
                        $path = $_.FullName
                        $excluded = $false
                        foreach ($ex in $excludeDirs) {
                            if ($path -like "*/$ex/*" -or $path -like "*\$ex\*") { $excluded = $true; break }
                        }
                        -not $excluded
                    }

                foreach ($prop in $serverProps) {
                    $instanceDir = $prop.DirectoryName
                    if ($foundPaths.ContainsKey($instanceDir)) { continue }

                    $modsPath = Join-Path $instanceDir 'mods'

                    if (Test-IsGtnhInstance -ModsPath $modsPath) {
                        $name = Split-Path $instanceDir -Leaf
                        $version = Get-InstalledGtnhVersion -InstancePath $instanceDir

                        $results += [PSCustomObject]@{
                            Name    = $name
                            Path    = $instanceDir
                            Version = $version
                        }
                        $foundPaths[$instanceDir] = $true
                    }
                }
            }
            catch {
                # Silently continue if access denied
            }
        }
    }

    Write-Info "Found $($results.Count) GTNH server instance(s)."
    return $results
}

function Find-PrismInstances {
    <#
    .SYNOPSIS
        Scan common launcher instance directories for GTNH client instances.
    .DESCRIPTION
        On Windows: checks PrismLauncher, MultiMC, PolyMC, and ATLauncher instance
        directories in APPDATA, LOCALAPPDATA, and drive roots.
        On Linux: checks ~/.local/share/PrismLauncher/instances/,
        ~/.local/share/multimc/instances/, ~/Games/, and other common paths.
    .OUTPUTS
        Array of [PSCustomObject]@{ Name; Path; Version }
    #>

    Write-Step "Scanning for GTNH client instances..."

    $results = @()

    # Build launcher paths based on platform
    $launcherPaths = @()

    if ($IsWindows) {
        $launcherPaths = @(
            (Join-Path $env:APPDATA 'PrismLauncher\instances')
            (Join-Path $env:APPDATA 'MultiMC\instances')
            (Join-Path $env:APPDATA 'PolyMC\instances')
            (Join-Path $env:LOCALAPPDATA 'PrismLauncher\instances')
            (Join-Path $env:LOCALAPPDATA 'MultiMC\instances')
            (Join-Path $env:LOCALAPPDATA 'PolyMC\instances')
            (Join-Path $env:APPDATA 'ATLauncher\instances')
        )

        # Also check common custom locations on all drives
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null }
        foreach ($drive in $drives) {
            $driveRoot = $drive.Root
            $launcherPaths += Join-Path $driveRoot 'PrismLauncher\instances'
            $launcherPaths += Join-Path $driveRoot 'MultiMC\instances'
        }
    }
    else {
        # Linux: XDG data directories and common locations
        $xdgDataHome = $env:XDG_DATA_HOME
        if (-not $xdgDataHome) {
            $xdgDataHome = Join-Path $HOME '.local/share'
        }

        $launcherPaths = @(
            (Join-Path $xdgDataHome 'PrismLauncher/instances')
            (Join-Path $xdgDataHome 'multimc/instances')
            (Join-Path $xdgDataHome 'PolyMC/instances')
            (Join-Path $xdgDataHome 'ATLauncher/instances')
            (Join-Path $HOME '.local/share/PrismLauncher/instances')
            (Join-Path $HOME '.local/share/multimc/instances')
            (Join-Path $HOME '.local/share/PolyMC/instances')
            (Join-Path $HOME 'Games/PrismLauncher/instances')
            (Join-Path $HOME 'Games/MultiMC/instances')
            (Join-Path $HOME 'games/PrismLauncher/instances')
            (Join-Path $HOME 'games/MultiMC/instances')
            # Flatpak locations
            (Join-Path $HOME '.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances')
            (Join-Path $HOME '.var/app/org.polymc.PolyMC/data/PolyMC/instances')
            # Snap locations
            (Join-Path $HOME 'snap/prismlauncher/common/.local/share/PrismLauncher/instances')
        )
    }

    # Deduplicate paths
    $launcherPaths = $launcherPaths | Select-Object -Unique

    foreach ($instancesDir in $launcherPaths) {
        if (-not (Test-Path -LiteralPath $instancesDir)) {
            continue
        }

        try {
            $instanceDirs = Get-ChildItem -LiteralPath $instancesDir -Directory -ErrorAction SilentlyContinue

            foreach ($dir in $instanceDirs) {
                # Check .minecraft subfolder (Prism/MultiMC/PolyMC style)
                $minecraftDir = Join-Path $dir.FullName '.minecraft'
                $modsPath = Join-Path $minecraftDir 'mods'

                if (Test-IsGtnhInstance -ModsPath $modsPath) {
                    $name = $dir.Name
                    $version = Get-InstalledGtnhVersion -InstancePath $minecraftDir

                    $results += [PSCustomObject]@{
                        Name    = $name
                        Path    = $minecraftDir
                        Version = $version
                    }
                    continue
                }

                # Check direct mods folder (ATLauncher style)
                $directMods = Join-Path $dir.FullName 'mods'
                if (Test-IsGtnhInstance -ModsPath $directMods) {
                    $name = $dir.Name
                    $version = Get-InstalledGtnhVersion -InstancePath $dir.FullName

                    $results += [PSCustomObject]@{
                        Name    = $name
                        Path    = $dir.FullName
                        Version = $version
                    }
                }
            }
        }
        catch {
            # Silently continue if access denied
        }
    }

    Write-Info "Found $($results.Count) GTNH client instance(s)."
    return $results
}
