# ============================================================================
# Group 4: Instance & Java Detection - Auto-detect installations and Java paths
# ============================================================================
# Functions:
#   Find-JavaInstallations   - Scan Adoptium, Oracle, Zulu, BellSoft, Microsoft
#                               paths, JAVA_HOME, PATH for java.exe (not javaw.exe);
#                               return sorted list with major version
#   Find-AmpInstances        - Scan all fixed drives for server.properties
#                               co-located with GTNH mod JARs in common AMP paths
#   Find-PrismInstances      - Scan %APPDATA%/PrismLauncher/instances/ for
#                               GTNH client instances
#   Test-IsGtnhInstance      - Check if a mods/ folder contains GregTech/GT5 JARs
#   Get-InstalledGtnhVersion - Detect version from gtnh_version.txt or
#                               changelog filenames, return 'unknown' if not found
#
# All registry and file system access is wrapped in try/catch blocks.
# ============================================================================

function Find-JavaInstallations {
    <#
    .SYNOPSIS
        Scan common Java installation locations, JAVA_HOME, and PATH for java.exe.
    .DESCRIPTION
        Searches Adoptium, Oracle, Microsoft, Zulu, and BellSoft install directories
        in both Program Files and Program Files (x86), plus JAVA_HOME and PATH.
        For each found java.exe, runs -version to determine the major version.
        Returns an array of PSCustomObjects sorted by MajorVersion descending.
    .OUTPUTS
        Array of [PSCustomObject]@{ Path; MajorVersion; VersionText }
    #>

    Write-Step "Scanning for Java installations..."

    $found = @{}  # Use hashtable to deduplicate by resolved path

    # Common installation glob patterns
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

    # Check JAVA_HOME
    if ($env:JAVA_HOME) {
        try {
            $javaHomePath = Join-Path $env:JAVA_HOME 'bin\java.exe'
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

    # Check PATH via Get-Command
    try {
        $pathJava = Get-Command 'java' -ErrorAction SilentlyContinue
        if ($pathJava) {
            $resolved = $pathJava.Source
            if ($resolved -and (-not $found.ContainsKey($resolved))) {
                $found[$resolved] = $true
            }
        }
    }
    catch {
        # Silently continue
    }

    # For each found java.exe, get version info
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

    # Method 1: gtnh_version.txt (written by the nightly updater JAR)
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
                # Sort: highest base version first, then stable before beta for same base
                $sorted = $toVersions | Sort-Object {
                    $base = '0.0.0'
                    if ($_ -match '^(\d+\.\d+\.\d+)') { $base = $Matches[1] }
                    [version]$base
                }, {
                    # Stable (no suffix) sorts after beta so it ends up first in descending
                    if ($_ -match '[-_](beta|rc)') { 0 } else { 1 }
                }, { $_ } -Descending
                return $sorted[0]
            }
        }
    }
    catch {
        # Fall through to return unknown
    }

    return 'unknown'
}

function Find-AmpInstances {
    <#
    .SYNOPSIS
        Scan all fixed drives for GTNH server instances.
    .DESCRIPTION
        Checks common server hosting paths (AMP/CubeCoders, standalone server folders,
        common naming patterns) on each fixed drive for server.properties files
        co-located with GTNH mod JARs.
    .OUTPUTS
        Array of [PSCustomObject]@{ Name; Path; Version }
    #>

    Write-Step "Scanning for GTNH server instances..."

    $results = @()
    $foundPaths = @{}  # Deduplicate

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

    Write-Info "Found $($results.Count) GTNH server instance(s)."
    return $results
}

function Find-PrismInstances {
    <#
    .SYNOPSIS
        Scan common launcher instance directories for GTNH client instances.
    .DESCRIPTION
        Checks PrismLauncher, MultiMC, PolyMC, and ATLauncher instance directories
        for GTNH client instances containing GregTech mod JARs.
    .OUTPUTS
        Array of [PSCustomObject]@{ Name; Path; Version }
    #>

    Write-Step "Scanning for GTNH client instances..."

    $results = @()

    # All launcher instance directories to check
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
