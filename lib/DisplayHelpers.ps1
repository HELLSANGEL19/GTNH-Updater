# ============================================================================
# Group 1: Display Helpers - Color-coded console output and input functions
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
#
# All Write-* functions that log also guard against Write-Log not being loaded
# yet (DisplayHelpers.ps1 is dot-sourced before Logging.ps1).
# ============================================================================

function Write-Banner {
    <#
    .SYNOPSIS
        Display ASCII art banner for "GTNH Updater" at startup with version and beta tag.
    #>
    $ver = $script:UpdaterVersion ?? '?.?.?'
    $updaterLine = "U P D A T E R   v$ver"
    # Center the updater line under the 36-char-wide border
    $padLeft = [math]::Max(0, [math]::Floor((36 - $updaterLine.Length) / 2))
    $centeredUpdater = (' ' * $padLeft) + $updaterLine
    $banner = @"

  ════════════════════════════════════
   ██████╗ ████████╗███╗   ██╗██╗  ██╗
  ██╔════╝ ╚══██╔══╝████╗  ██║██║  ██║
  ██║  ███╗   ██║   ██╔██╗ ██║███████║
  ██║   ██║   ██║   ██║╚██╗██║██╔══██║
  ╚██████╔╝   ██║   ██║ ╚████║██║  ██║
   ╚═════╝    ╚═╝   ╚═╝  ╚═══╝╚═╝  ╚═╝
  $centeredUpdater
  ════════════════════════════════════

"@
    Write-Host $banner -ForegroundColor Cyan
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
    $result = $userInput ? $userInput : $Default
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "[INPUT] $Prompt`: $result"
    }
    return $result
}

function Confirm-Action {
    <#
    .SYNOPSIS
        (y/n) confirmation prompt. Returns $true for y/Y, $false for anything else.
    .PARAMETER Prompt
        The confirmation question to display.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt
    )
    Write-Host ""
    Write-Host "  $Prompt (y/n): " -NoNewline -ForegroundColor White
    $response = (Read-Host).Trim()
    $confirmed = $response -eq 'y' -or $response -eq 'Y'
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

function Open-FolderInFileManager {
    <#
    .SYNOPSIS
        Open a folder in the system file manager (cross-platform).
    .DESCRIPTION
        On Windows: uses explorer.exe.
        On Linux: uses xdg-open.
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
