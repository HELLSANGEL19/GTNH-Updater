# ============================================================================
# Group 13: Post-Update Verification - Validate instance integrity after update
# ============================================================================
# Functions:
#   Invoke-Verification  - Check critical directories and files exist after update
#
# Checks performed:
#   - mods/, config/, libraries/ directories exist
#   - Mod count (warn if < 400 JARs)
#   - GregTech JAR present (core mod)
#   - Duplicate mods (same base name, different versions)
#   - Target-specific: JourneyMapServer (server), options.txt (client)
# ============================================================================

function Invoke-Verification {
    <#
    .SYNOPSIS
        Run post-update verification checks on an instance.
    .DESCRIPTION
        Checks that critical directories exist, counts mods (warns if < 400),
        verifies GregTech JAR is present, and checks target-specific files.
        Displays results via Write-Success for passes and Write-Warn for issues.
    .PARAMETER InstancePath
        The root path of the instance (server root or .minecraft for client).
    .PARAMETER Target
        The target type: 'server' or 'client'.
    #>
    param(
        [Parameter(Mandatory)][string]$InstancePath,
        [Parameter(Mandatory)][ValidateSet('server', 'client')][string]$Target
    )

    Write-Header "Post-Update Verification ($Target)"

    $allPassed = $true

    # Check mods/ directory exists
    $modsPath = Join-Path $InstancePath 'mods'
    if (Test-Path -LiteralPath $modsPath) {
        Write-Success "mods/ directory exists"
    } else {
        Write-Warn "mods/ directory is MISSING"
        $allPassed = $false
    }

    # Check config/ directory exists
    $configPath = Join-Path $InstancePath 'config'
    if (Test-Path -LiteralPath $configPath) {
        Write-Success "config/ directory exists"
    } else {
        Write-Warn "config/ directory is MISSING"
        $allPassed = $false
    }

    # Check libraries/ directory exists
    # For client, libraries/ is at the Prism instance root (parent of .minecraft)
    if ($Target -eq 'client') {
        $librariesPath = Join-Path (Split-Path -Parent $InstancePath) 'libraries'
    } else {
        $librariesPath = Join-Path $InstancePath 'libraries'
    }
    if (Test-Path -LiteralPath $librariesPath) {
        Write-Success "libraries/ directory exists"
    } else {
        Write-Warn "libraries/ directory is MISSING"
        $allPassed = $false
    }

    # Count .jar files in mods/
    if (Test-Path -LiteralPath $modsPath) {
        $modCount = (Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File).Count
        if ($modCount -ge 400) {
            Write-Success "Mod count: $modCount JARs"
        } else {
            Write-Warn "Mod count: $modCount JARs (expected 400+, may indicate incomplete extraction)"
            $allPassed = $false
        }
    }

    # Check for GregTech JAR
    if (Test-Path -LiteralPath $modsPath) {
        $gregTechJar = Get-ChildItem -LiteralPath $modsPath -Filter '*.jar' -File |
            Where-Object { $_.Name -like '*gregtech*' -or $_.Name -like '*GT5*' }
        if ($gregTechJar) {
            Write-Success "GregTech JAR found: $($gregTechJar[0].Name)"
        } else {
            Write-Warn "GregTech JAR NOT found - this may not be a valid GTNH instance"
            $allPassed = $false
        }
    }

    # Target-specific checks
    if ($Target -eq 'server') {
        $journeyMapServer = Join-Path $InstancePath 'config\JourneyMapServer'
        if (Test-Path -LiteralPath $journeyMapServer) {
            Write-Success "config/JourneyMapServer exists"
        } else {
            Write-Warn "config/JourneyMapServer is MISSING (may need first server start to generate)"
        }
    } else {
        $optionsFile = Join-Path $InstancePath 'options.txt'
        if (Test-Path -LiteralPath $optionsFile) {
            Write-Success "options.txt exists"
        } else {
            Write-Warn "options.txt is MISSING (may need first client launch to generate)"
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
        if ($duplicates) {
            $dupCount = @($duplicates).Count
            Write-Warn "Found $dupCount mod(s) with multiple versions:"
            foreach ($dup in $duplicates) {
                $files = $dup.Value | Sort-Object
                Write-Host "    * $($files -join ', ')" -ForegroundColor DarkYellow
            }
            Write-Warn "Multiple versions of the same mod can cause crashes. Remove the older version(s)."
            $allPassed = $false
        } else {
            Write-Success "No duplicate mods detected"
        }
    }

    # Summary
    Write-Host ""
    if ($allPassed) {
        Write-Success "All verification checks passed."
    } else {
        Write-Warn "Some verification checks failed - review warnings above."
    }
}
