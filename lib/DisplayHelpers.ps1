# ============================================================================
# Group 1: Display Helpers - Color-coded console output, input, and shared utils
# ============================================================================
# Functions:
#   Write-Banner        - Display ASCII art banner at startup
#   Write-Header        - Cyan section header with separator lines
#   Write-Step          - Yellow ">>" prefixed progress message
#   Write-Info          - Gray informational text
#   Write-Success       - Green "[OK]" prefixed success message
#   Write-Warn          - Dark yellow "[!]" prefixed warning
#   Write-Err           - Red "[ERROR]" prefixed error message
#   Write-MenuOption    - Formatted "[key] description" menu line
#   Read-MenuChoice     - Prompt for menu selection, log input
#   Read-UserInput      - Prompt with optional default value
#   Confirm-Action      - (y/n) confirmation prompt
#   Wait-ForKey         - Press any key to continue
#   Open-FolderInFileManager - Open folder in system file manager (cross-platform)
#   Remove-TempDir      - Safely remove a temp directory (shared utility)
#
# All Write-* functions that log also guard against Write-Log not being loaded
# yet (DisplayHelpers.ps1 is dot-sourced before Logging.ps1).
# ============================================================================

# ── Channel Constants ─────────────────────────────────────────────────────────
$script:ValidChannels = @('stable', 'daily', 'experimental')

# Channel display names (internal value -> user-facing label)
$script:ChannelDisplayNames = @{
    'stable'       = 'release'
    'daily'        = 'daily'
    'experimental' = 'experimental'
}
function Get-ChannelDisplayName { param([string]$Channel) return $script:ChannelDisplayNames[$Channel] ?? $Channel }

# ── Terminal Width Helper ─────────────────────────────────────────────────────
# Safe cross-platform terminal width detection. Returns a usable width for
# progress bars and line clearing. Falls back to 120 if console is unavailable
# (non-interactive terminals, SSH pipes, systemd services on Linux).
function Get-TerminalWidth {
    try {
        $width = [Console]::BufferWidth
        if ($width -gt 0) {
            return [math]::Min(($width - 1), 120)
        }
    } catch {}
    # Fallback: try $Host.UI.RawUI (works in some PS hosts where Console doesn't)
    try {
        $width = $Host.UI.RawUI.BufferSize.Width
        if ($width -gt 0) {
            return [math]::Min(($width - 1), 120)
        }
    } catch {}
    # Final fallback: safe default
    return 80
}

function Write-Banner {
    <#
    .SYNOPSIS
        Display ASCII art banner with version and author.
    #>
    $ver = $script:UpdaterVersion ?? '?.?.?'
    $banner = @"

  ════════════════════════════════════
   ██████╗ ████████╗███╗   ██╗██╗  ██╗
  ██╔════╝ ╚══██╔══╝████╗  ██║██║  ██║
  ██║  ███╗   ██║   ██╔██╗ ██║███████║
  ██║   ██║   ██║   ██║╚██╗██║██╔══██║
  ╚██████╔╝   ██║   ██║ ╚████║██║  ██║
   ╚═════╝    ╚═╝   ╚═╝  ╚═══╝╚═╝  ╚═╝
  ════════════════════════════════════
"@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host "  Updater v$ver" -NoNewline -ForegroundColor White
    Write-Host "  by HELLSANGEL" -ForegroundColor DarkGray
}

function Write-Header {
    <#
    .SYNOPSIS
        Display a cyan section header with a thin separator line below.
    .PARAMETER Message
        The header text to display.
    #>
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Host ""
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "  $('-' * 56)" -ForegroundColor DarkCyan
    Write-Host ""
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[HEADER] $Message"
    }
}

function Write-Step {
    <#
    .SYNOPSIS
        Display a yellow step indicator with colored step number.
    .PARAMETER Message
        The step/progress text to display.
    #>
    param(
        [Parameter(Mandatory)][string]$Message
    )
    # Color the step number differently if present (e.g., "Step 3/13: ...")
    if ($Message -match '^(Step \d+/\d+)(:.*)$') {
        Write-Host "  >> " -NoNewline -ForegroundColor DarkYellow
        Write-Host $Matches[1] -NoNewline -ForegroundColor White
        Write-Host $Matches[2] -ForegroundColor Yellow
    } else {
        Write-Host "  >> $Message" -ForegroundColor Yellow
    }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[STEP] $Message"
    }
}

function Write-Info {
    <#
    .SYNOPSIS
        Display gray informational text.
    .PARAMETER Message
        The informational text to display. Pass empty string for a blank line.
    #>
    param(
        [Parameter(Mandatory=$false)][string]$Message = ''
    )
    Write-Host "  $Message" -ForegroundColor Gray
    if ($Message -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
        Write-Log "[INFO] $Message"
    }
}

function Write-Success {
    <#
    .SYNOPSIS
        Display a green [OK] prefixed success message.
    .PARAMETER Message
        The success text to display.
    #>
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Host "  [OK] $Message" -ForegroundColor Green
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[OK] $Message"
    }
}

function Write-Warn {
    <#
    .SYNOPSIS
        Display a dark yellow [!] prefixed warning message.
    .PARAMETER Message
        The warning text to display.
    #>
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Host "  [!] $Message" -ForegroundColor DarkYellow
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[WARN] $Message"
    }
}

function Write-Err {
    <#
    .SYNOPSIS
        Display a red [ERROR] prefixed error message.
    .PARAMETER Message
        The error text to display.
    #>
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[ERROR] $Message"
    }
}

function Write-MenuOption {
    <#
    .SYNOPSIS
        Display a formatted [key] description menu line.
    .PARAMETER Key
        The menu key/number shown in brackets.
    .PARAMETER Description
        The description text for this menu option.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Description
    )
    Write-Host "  [" -NoNewline
    Write-Host $Key -ForegroundColor Cyan -NoNewline
    Write-Host "] $Description"
}

function Read-MenuChoice {
    <#
    .SYNOPSIS
        Prompt for menu selection, log input, return trimmed choice.
    .PARAMETER Prompt
        The prompt text to display. Defaults to 'Choose an option'.
    #>
    param(
        [string]$Prompt = 'Choose an option'
    )
    Write-Host ""
    Write-Host "  $Prompt`: " -NoNewline -ForegroundColor White
    $choice = (Read-Host).Trim()
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[INPUT] Menu choice: $choice"
    }
    return $choice
}

function Read-UserInput {
    <#
    .SYNOPSIS
        Prompt with optional default value. If user presses Enter with empty
        input, return the default.
    .PARAMETER Prompt
        The prompt text to display.
    .PARAMETER Default
        Optional default value shown in DarkGray brackets.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = ''
    )
    Write-Host ""
    if ($Default) {
        Write-Host "  $Prompt " -NoNewline -ForegroundColor White
        Write-Host "[$Default]" -NoNewline -ForegroundColor DarkGray
        Write-Host ": " -NoNewline
    } else {
        Write-Host "  $Prompt`: " -NoNewline -ForegroundColor White
    }
    $userInput = (Read-Host).Trim()
    # Strip surrounding quotes (Windows "Copy as path" adds them)
    if ($userInput -match '^"(.*)"$' -or $userInput -match "^'(.*)'$") { $userInput = $Matches[1] }
    # Expand leading ~ to home directory (Linux/Mac path shorthand)
    if ($userInput -match '^~[/\\]') { $userInput = $userInput -replace '^~', $HOME }
    elseif ($userInput -eq '~') { $userInput = $HOME }
    # Strip trailing slashes/backslashes (common when pasting paths from Explorer)
    if ($userInput -and $userInput.Length -gt 3) {
        $userInput = $userInput.TrimEnd('\', '/')
    }
    $result = $userInput ? $userInput : $Default
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[INPUT] $Prompt`: $result"
    }
    return $result
}

function Confirm-Action {
    <#
    .SYNOPSIS
        Confirmation prompt. Returns $true for y/Y/Enter (when DefaultYes), $false for n/N.
    .PARAMETER Prompt
        The confirmation question to display.
    .PARAMETER DefaultYes
        If $true, pressing Enter without typing anything returns $true (Y is default).
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$DefaultYes
    )
    Write-Host ""
    $hint = if ($DefaultYes) { '(Y/n)' } else { '(y/n)' }
    Write-Host "  $Prompt $hint`: " -NoNewline -ForegroundColor White
    $response = (Read-Host).Trim()
    $confirmed = if ($DefaultYes) {
        # Default yes: empty or y/Y = true, n/N = false
        -not ($response -eq 'n' -or $response -eq 'N')
    } else {
        $response -eq 'y' -or $response -eq 'Y'
    }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $logValue = $confirmed ? 'yes' : 'no'
        Write-Log "[INPUT] Confirm '$Prompt': $logValue"
    }
    return $confirmed
}

function Wait-ForKey {
    <#
    .SYNOPSIS
        Display "Press any key to continue..." in DarkGray and wait for keypress.
    #>
    Write-Host ""
    Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Write-BackupWarning {
    <#
    .SYNOPSIS
        Display the pre-update backup reminder box (server=Red, client=DarkYellow).
    .PARAMETER Target
        'server' or 'client'.
    #>
    param([Parameter(Mandatory)][string]$Target)
    $color = $Target -eq 'server' ? 'Red' : 'DarkYellow'
    $msg   = $Target -eq 'server' ? 'Back up your server and make sure it is STOPPED.           ' `
                                   : 'Back up your client instance before continuing.            '
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor $color
    Write-Host "  ║  $msg║" -ForegroundColor $color
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor $color
}

function Show-UpdatePlan {
    <#
    .SYNOPSIS
        Display a summary box of what the update will do, then confirm.
    .DESCRIPTION
        Shows version change, target, instance path, and steps at a glance.
        Returns $true if user confirms, $false if they cancel.
    .PARAMETER Config
        The config PSCustomObject.
    .PARAMETER Target
        'server' or 'client'.
    .PARAMETER Version
        The version being installed (e.g., '2.8.5' or '2.9.0-nightly-2026-05-11').
    .PARAMETER Channel
        The update channel: 'stable', 'daily', 'experimental'.
    .PARAMETER InstancePath
        The instance path being updated.
    .OUTPUTS
        $true if user confirms, $false if cancelled.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$InstancePath
    )

    $currentVer = $Target -eq 'server' ? ($Config.InstalledServerVersion ?? '?') : ($Config.InstalledClientVersion ?? '?')
    $backupLabel = $Config.BackupEnabled ? 'Full backup (auto)' : 'Rollback snapshot only'
    $patchCount = @($Config.ConfigPatches | Where-Object { $_.Target -eq $Target -or $_.Target -eq 'both' }).Count
    $customModCount = $Target -eq 'server' ? ($Config.CustomServerMods ?? @()).Count : ($Config.CustomClientMods ?? @()).Count

    # Shorten instance path for display if too long
    $displayPath = $InstancePath
    if ($displayPath.Length -gt 50) {
        $displayPath = '...' + $displayPath.Substring($displayPath.Length - 47)
    }

    # Build all content lines first to calculate the box width
    $versionLine = "Version:  $currentVer  ->  $Version"
    $channelLine = "Channel:  $Channel"
    $targetLine  = "Target:   $Target"
    $instanceLine = "Instance: $displayPath"

    $stepLines = @()
    if ($Channel -eq 'stable') {
        $stepLines += "  1. Download + extract pack"
        $stepLines += "  2. $backupLabel"
        $stepLines += "  3. Replace pack files"
        $stepLines += "  4. Restore preserved files"
    } else {
        $stepLines += "  1. $backupLabel"
        $stepLines += "  2. Run $Channel updater"
        $stepLines += "  3. Restore preserved files"
    }
    if ($customModCount -gt 0) { $stepLines += "  +  Restore $customModCount custom mod(s)" }
    if ($patchCount -gt 0) { $stepLines += "  +  Apply $patchCount config patch(es)" }

    $warnLines = @()
    if ($Target -eq 'server') { $warnLines += "[!] Make sure the server is stopped." }
    if (-not $Config.BackupEnabled) {
        $warnLines += "[!] Full backup is off. Only a rollback snapshot will be saved."
        $warnLines += "    Enable in Settings > Backups and Cache."
    }

    # Calculate box width (minimum 56, expand if content is wider)
    $allContentLengths = @($versionLine.Length, $channelLine.Length, $targetLine.Length, $instanceLine.Length)
    $allContentLengths += $stepLines | ForEach-Object { $_.Length }
    $allContentLengths += $warnLines | ForEach-Object { $_.Length }
    $innerWidth = [math]::Max(56, ($allContentLengths | Measure-Object -Maximum).Maximum + 2)

    # Helper to pad a line to fill the box
    $pad = { param($text, $len) $text + (' ' * [math]::Max(1, $innerWidth - $len)) }

    # Draw the box
    $border = '─' * ($innerWidth + 2)
    Write-Host ""
    Write-Host "  ┌${border}┐" -ForegroundColor DarkGray
    $headerText = "Update Plan"
    Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$headerText" -NoNewline -ForegroundColor Cyan
    Write-Host "$(' ' * ($innerWidth - $headerText.Length))│" -ForegroundColor DarkGray
    Write-Host "  ├${border}┤" -ForegroundColor DarkGray

    # Version line (with colors)
    Write-Host "  │  Version:  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$currentVer" -NoNewline -ForegroundColor Yellow
    Write-Host "  ->  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Version" -NoNewline -ForegroundColor Green
    Write-Host "$(' ' * [math]::Max(1, $innerWidth - $versionLine.Length))│" -ForegroundColor DarkGray

    # Channel
    $channelColor = $Channel -eq 'stable' ? 'Cyan' : 'Magenta'
    Write-Host "  │  Channel:  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Channel" -NoNewline -ForegroundColor $channelColor
    Write-Host "$(' ' * [math]::Max(1, $innerWidth - $channelLine.Length))│" -ForegroundColor DarkGray

    # Target
    Write-Host "  │  Target:   " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Target" -NoNewline -ForegroundColor White
    Write-Host "$(' ' * [math]::Max(1, $innerWidth - $targetLine.Length))│" -ForegroundColor DarkGray

    # Instance path
    Write-Host "  │  Instance: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$displayPath" -NoNewline -ForegroundColor Gray
    Write-Host "$(' ' * [math]::Max(1, $innerWidth - $instanceLine.Length))│" -ForegroundColor DarkGray

    # Blank line
    Write-Host "  │$(' ' * ($innerWidth + 2))│" -ForegroundColor DarkGray

    # Steps
    Write-Host "  │  Steps:" -NoNewline -ForegroundColor DarkGray
    Write-Host "$(' ' * ($innerWidth - 6))│" -ForegroundColor DarkGray
    foreach ($step in $stepLines) {
        Write-Host "  │  $step" -NoNewline -ForegroundColor Gray
        Write-Host "$(' ' * [math]::Max(1, $innerWidth - $step.Length))│" -ForegroundColor DarkGray
    }

    # Blank line before warnings
    if ($warnLines.Count -gt 0) {
        Write-Host "  │$(' ' * ($innerWidth + 2))│" -ForegroundColor DarkGray
        foreach ($warn in $warnLines) {
            Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
            Write-Host "$warn" -NoNewline -ForegroundColor DarkYellow
            Write-Host "$(' ' * [math]::Max(1, $innerWidth - $warn.Length))│" -ForegroundColor DarkGray
        }
    }

    Write-Host "  └${border}┘" -ForegroundColor DarkGray

    return (Confirm-Action "Proceed?")
}

function Open-FolderInFileManager {
    <#
    .SYNOPSIS
        Open a folder in the system file manager (cross-platform).
    .DESCRIPTION
        On Windows: uses explorer.exe.
        On Linux: uses xdg-open (requires a display server).
    .PARAMETER Path
        The folder path to open.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if ($IsWindows) {
        Start-Process explorer.exe -ArgumentList "`"$Path`""
    }
    else {
        # Check for a display server (headless servers won't have one)
        if (-not $env:DISPLAY -and -not $env:WAYLAND_DISPLAY) {
            throw "No display server detected (headless). Path: $Path"
        }

        # Linux: use xdg-open (available on most desktop environments)
        try {
            Start-Process 'xdg-open' -ArgumentList @($Path)
        }
        catch {
            # Fallback: try common alternatives
            $opened = $false
            foreach ($opener in @('nautilus', 'dolphin', 'thunar', 'nemo', 'pcmanfm')) {
                if (Get-Command $opener -ErrorAction SilentlyContinue) {
                    Start-Process $opener -ArgumentList @($Path)
                    $opened = $true
                    break
                }
            }
            if (-not $opened) {
                throw "No file manager found. Install xdg-utils or open manually: $Path"
            }
        }
    }
}

# ── Shared Utility Functions ──────────────────────────────────────────────────

function Remove-TempDir {
    <#
    .SYNOPSIS
        Safely remove a temporary directory if it exists.
    .PARAMETER Path
        The directory path to remove. Handles $null gracefully.
    #>
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Remove-Item -LiteralPath $Path -Recurse -Force
            $ProgressPreference = $oldProgress
        } catch {}
    }
}

function Write-Dots {
    <#
    .SYNOPSIS
        Show a message with trailing "..." to indicate a brief operation is running.
        Call this before the operation, then Write-Host "" or Write-Success after.
    .PARAMETER Message
        Text to show (e.g., "Fetching manifest").
    #>
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  $Message..." -NoNewline -ForegroundColor Gray
}

function Complete-Dots {
    <#
    .SYNOPSIS
        Complete a Write-Dots line with a result (overwrites the dots line).
    .PARAMETER Result
        Short result text (e.g., "done", "v2.8.5", "287 mods").
    .PARAMETER Color
        Color for the result text. Default: DarkGreen.
    #>
    param(
        [string]$Result = 'done',
        [string]$Color = 'DarkGreen'
    )
    Write-Host " $Result" -ForegroundColor $Color
}

function Clear-ProgressLine {
    <#
    .SYNOPSIS
        Clear the current console line (used after progress bars).
    #>
    Write-Host "`r$(' ' * (Get-TerminalWidth))`r" -NoNewline
}

function Write-Phase {
    <#
    .SYNOPSIS
        Display a thin phase separator for update flow sections.
    .PARAMETER Name
        Short phase name (e.g., "Mods", "Config", "Finalize").
    #>
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ""
    Write-Host "  ── " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Name " -NoNewline -ForegroundColor White
    Write-Host $('─' * [math]::Max(1, 47 - $Name.Length)) -ForegroundColor DarkGray
}
