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
$_dt = Join-Path $script:ScriptDir 'lib\DevTools.ps1'
if (Test-Path -LiteralPath $_dt) {
    . $_dt
    $script:DevMode = $true
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Prevent concurrent instances from corrupting config or instance files
$script:LockFilePath = Join-Path $script:ScriptDir '.gtnh-updater.lock'

function Test-LockFile {
    if (-not (Test-Path -LiteralPath $script:LockFilePath)) { return $false }
    try {
        $lockContent = Get-Content -LiteralPath $script:LockFilePath -Raw -ErrorAction Stop
        $lockPid = [int]($lockContent.Trim())
        # Check if the process is still running
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        return ($null -ne $proc)
    }
    catch {
        # Lock file is corrupt or unreadable - treat as stale
        return $false
    }
}

function New-LockFile {
    try {
        $PID.ToString() | Set-Content -LiteralPath $script:LockFilePath -Encoding UTF8 -Force
    }
    catch {
        # Non-fatal: warn but continue (might be a read-only filesystem edge case)
        Write-Host "  [!] Could not create lock file. Concurrent runs are not protected." -ForegroundColor DarkYellow
    }
}

function Remove-LockFile {
    if (Test-Path -LiteralPath $script:LockFilePath) {
        try { Remove-Item -LiteralPath $script:LockFilePath -Force } catch {}
    }
}

if (Test-LockFile) {
    Write-Host ""
    Write-Host "  [!] Another instance of GTNH Updater appears to be running." -ForegroundColor Red
    Write-Host "  If this is wrong (e.g., a previous crash), delete:" -ForegroundColor DarkYellow
    Write-Host "  $($script:LockFilePath)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

New-LockFile

try {
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
    Remove-LockFile
}
