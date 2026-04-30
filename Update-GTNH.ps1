#Requires -Version 7.0

<#
.SYNOPSIS
    GTNH Updater - Automates updating GregTech: New Horizons modpack installations.

.DESCRIPTION
    A PowerShell 7+ script that automates updating GTNH server (AMP/CubeCoders) and
    client (Prism Launcher) installations on Windows. Fully interactive and menu-driven
    with no CLI flags. Supports three update channels (Stable, Daily, Experimental),
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
    Write-Host "  ║  You are running PowerShell $($PSVersionTable.PSVersion).                        ║" -ForegroundColor Red
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

$script:UpdaterVersion = '0.1.0-beta'

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:ConfigPath = Join-Path $script:ScriptDir 'gtnh-updater-config.json'
$script:LogDir = Join-Path $script:ScriptDir 'logs'
$script:TempDir = Join-Path $script:ScriptDir '.temp'
$script:CacheDir = Join-Path $script:ScriptDir 'cache'
$script:NightlyUpdaterDir = Join-Path $script:ScriptDir '.nightly-updater'

# API URLs and download base
$script:GtnhDownloadsBase = 'https://downloads.gtnewhorizons.com'
$script:NightlyUpdaterApi = 'https://api.github.com/repos/GTNewHorizons/gtnh-nightly-updater/releases/latest'
$script:ScriptUpdateApi = ''  # Set to your GitHub repo's releases/latest API URL when published

# Folder lists for deletion during updates
$script:ServerFoldersToDelete = @('config', 'libraries', 'mods', 'resources', 'scripts')
$script:ClientFoldersToDelete = @('config', 'mods', 'serverutilities', 'resources', 'scripts')

# Java 17+ specific files to delete for server updates
$script:ServerJava17FilesToDelete = @('lwjgl3ify-forgePatches.jar', 'java9args.txt', 'startserver-java9.bat', 'startserver-java9.sh')

# Java 17+ specific items at Prism instance root for client updates
$script:ClientJava17InstanceRootItems = @('libraries', 'patches', 'mmc-pack.json')

# Log file reference (set during Initialize-Logging)
$script:LogFile = $null

# ============================================================================
# DOT-SOURCE LIB FILES (dependency order)
# ============================================================================

. "$ScriptDir\lib\DisplayHelpers.ps1"
. "$ScriptDir\lib\Logging.ps1"
. "$ScriptDir\lib\ConfigManager.ps1"
. "$ScriptDir\lib\Detection.ps1"
. "$ScriptDir\lib\SetupWizard.ps1"
. "$ScriptDir\lib\NetworkApi.ps1"
. "$ScriptDir\lib\FilePreservation.ps1"
. "$ScriptDir\lib\CustomMods.ps1"
. "$ScriptDir\lib\ConfigPatcher.ps1"
. "$ScriptDir\lib\StableEngine.ps1"
. "$ScriptDir\lib\NightlyEngine.ps1"
. "$ScriptDir\lib\Verification.ps1"
. "$ScriptDir\lib\BackupManager.ps1"
. "$ScriptDir\lib\CacheManager.ps1"
. "$ScriptDir\lib\HistoryVersion.ps1"
. "$ScriptDir\lib\MenuSystem.ps1"

# ============================================================================
# ENTRY POINT
# ============================================================================

# Prevent concurrent runs with a lock file
$script:LockFile = Join-Path $script:ScriptDir '.updater.lock'
$script:WeCreatedLock = $false

try {
    # Check for existing lock file (another instance running)
    if (Test-Path -LiteralPath $script:LockFile) {
        $lockContent = Get-Content -LiteralPath $script:LockFile -Raw -ErrorAction SilentlyContinue
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
    # Only remove lock file if we created it (don't delete another instance's lock)
    if ($script:WeCreatedLock -and $script:LockFile -and (Test-Path -LiteralPath $script:LockFile)) {
        try { Remove-Item -LiteralPath $script:LockFile -Force } catch {}
    }
}
