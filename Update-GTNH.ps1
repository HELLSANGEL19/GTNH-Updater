#Requires -Version 7.0

<#
.SYNOPSIS
    GTNH Updater - Automates updating GregTech: New Horizons modpack installations.

.DESCRIPTION
    A PowerShell 7+ script that automates updating GTNH server (AMP/CubeCoders) and
    client (Prism Launcher) installations on Windows. Fully interactive and menu-driven
    with no CLI flags. Supports three update channels (Stable, Daily, Experimental)
    with beta/RC version support through the stable channel's version picker,
    auto-detects instance paths and Java installations, preserves critical files across
    updates, and provides config patching, custom mod management, preview-first updates,
    download caching, backup management, and structured logging.

.NOTES
    Requires PowerShell 7.0 or newer (pwsh).
    No external modules or dependencies beyond PowerShell 7+ and .NET.
#>

[CmdletBinding()]
param()

# ============================================================================
# POWERSHELL VERSION CHECK
# ============================================================================
# Display a friendly error if running on PowerShell 5.1 (Windows PowerShell)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  ERROR: PowerShell 7+ Required                              ║" -ForegroundColor Red
    Write-Host "  ╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Red
    Write-Host "  ║  This script requires PowerShell 7.0 or newer (pwsh).       ║" -ForegroundColor Red
    $verLine = "  You are running PowerShell $($PSVersionTable.PSVersion)."; $verLine = "  " + $verLine.PadRight(60) + "  "; Write-Host "  $([char]0x2551)$($verLine.Substring(0, [Math]::Min(62, $verLine.Length)).PadRight(62))$([char]0x2551)" -ForegroundColor Red
    Write-Host "  ║                                                              ║" -ForegroundColor Red
    Write-Host "  ║  Download PowerShell 7+:                                     ║" -ForegroundColor Red
    Write-Host "  ║  https://github.com/PowerShell/PowerShell/releases           ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  After installing, run this script with 'pwsh' instead of 'powershell'." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:ConfigPath = Join-Path $script:ScriptDir 'gtnh-updater-config.json'
$script:LogDir = Join-Path $script:ScriptDir 'logs'
$script:TempDir = Join-Path $script:ScriptDir '.temp'
$script:CacheDir = Join-Path $script:ScriptDir 'cache'
$script:NightlyUpdaterDir = Join-Path $script:ScriptDir '.nightly-updater'

# API URLs and download base
$script:GtnhDownloadsBase = 'https://downloads.gtnewhorizons.com'
$script:NightlyUpdaterApi = 'https://api.github.com/repos/Caedis/gtnh-daily-updater/releases/latest'
$script:ScriptUpdateApi = 'https://api.github.com/repos/HELLSANGEL19/GTNH-Updater/releases'

# Folder lists for deletion during updates
$script:ServerFoldersToDelete = @('config', 'libraries', 'mods', 'resources', 'scripts')
$script:ClientFoldersToDelete = @('config', 'mods', 'serverutilities', 'resources', 'scripts')

# Java 17+ specific files to delete for server updates
$script:ServerJava17FilesToDelete = @('lwjgl3ify-forgePatches.jar', 'java9args.txt', 'startserver-java9.bat', 'startserver-java9.sh')

# Java 17+ specific items at Prism instance root for client updates
$script:ClientJava17InstanceRootItems = @('libraries', 'patches', 'mmc-pack.json')

# Log file reference (set during Initialize-Logging)
$script:LogFile = $null
$script:CachedWebsiteReleases = $null

# ============================================================================
# DOT-SOURCE LIB FILES (dependency order)
# ============================================================================

. "$script:ScriptDir\lib\Version.ps1"
. "$script:ScriptDir\lib\DisplayHelpers.ps1"
. "$script:ScriptDir\lib\Logging.ps1"
. "$script:ScriptDir\lib\ConfigManager.ps1"
. "$script:ScriptDir\lib\Detection.ps1"
. "$script:ScriptDir\lib\SetupWizard.ps1"
. "$script:ScriptDir\lib\NetworkApi.ps1"
. "$script:ScriptDir\lib\FilePreservation.ps1"
. "$script:ScriptDir\lib\CustomMods.ps1"
. "$script:ScriptDir\lib\ConfigPatcher.ps1"
. "$script:ScriptDir\lib\StableEngine.ps1"
. "$script:ScriptDir\lib\NightlyEngine.ps1"
. "$script:ScriptDir\lib\Verification.ps1"
. "$script:ScriptDir\lib\BackupManager.ps1"
. "$script:ScriptDir\lib\CacheManager.ps1"
. "$script:ScriptDir\lib\HistoryVersion.ps1"
. "$script:ScriptDir\lib\MenuSystem.ps1"
$script:DevMode = $false
if ($script:ScriptDir -like '*-DEV*') {
    . "$script:ScriptDir\lib\DevTools.ps1"
    $script:DevMode = $true
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Prevent concurrent runs with a lock file
$script:LockFile = Join-Path $script:ScriptDir '.updater.lock'
$script:WeCreatedLock = $false

try {
    # Check for existing lock file (another instance running or previous crash)
    if (Test-Path -LiteralPath $script:LockFile) {
        $lockContent = Get-Content -LiteralPath $script:LockFile -Raw -ErrorAction SilentlyContinue
        $lockAge = $null
        try {
            $lockTime = [datetime]::ParseExact($lockContent.Trim(), 'yyyy-MM-dd HH:mm:ss', $null)
            $lockAge = (Get-Date) - $lockTime
        } catch {}

        # If the lock is older than 12 hours, it's definitely stale - auto-clean
        if ($lockAge -and $lockAge.TotalHours -gt 12) {
            try { Remove-Item -LiteralPath $script:LockFile -Force } catch {}
        } else {
            Write-Host ""
            Write-Host "  [!] Another instance of GTNH Updater may be running." -ForegroundColor DarkYellow
            Write-Host "  Lock file: $($script:LockFile)" -ForegroundColor Gray
            if ($lockContent) {
                Write-Host "  Started: $($lockContent.Trim())" -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  If the previous run crashed, you can safely continue." -ForegroundColor Gray
            Write-Host "  Continue? (y/n): " -NoNewline -ForegroundColor White
            $lockResponse = (Read-Host).Trim()
            if ($lockResponse -ne 'y' -and $lockResponse -ne 'Y') {
                Write-Host "  Exiting." -ForegroundColor Gray
                exit 0
            }
        }
    }

    # Create lock file with timestamp
    Get-Date -Format 'yyyy-MM-dd HH:mm:ss' | Set-Content -LiteralPath $script:LockFile -Force
    $script:WeCreatedLock = $true

    Invoke-MainLoop
}
catch {
    Write-Host ""
    Write-Host "  [FATAL] Unhandled exception in GTNH Updater:" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  If this persists, check the logs/ folder or delete gtnh-updater-config.json to reset." -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}
finally {
    # Remove lock file if we created it
    if ($script:WeCreatedLock -and $script:LockFile -and (Test-Path -LiteralPath $script:LockFile)) {
        try { Remove-Item -LiteralPath $script:LockFile -Force } catch {}
    }
}
