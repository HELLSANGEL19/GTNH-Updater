# ============================================================================
# Group 2: Logging - Log file initialization and writing
# ============================================================================
# Functions:
#   Initialize-Logging  - Create logs/ dir, open timestamped log file, prune
#                          old logs (keep 20 most recent)
#   Write-Log           - Append timestamped message to current log file
#
# Log files are named: gtnh-update-yyyy-MM-dd_HHmmss.log
# Stored in the logs/ folder next to the main script.
# ============================================================================

function Initialize-Logging {
    <#
    .SYNOPSIS
        Creates the logs/ directory, opens a new timestamped log file, and prunes old logs.
    .DESCRIPTION
        Sets up logging for the current session. Creates the logs/ directory if it
        doesn't exist, generates a timestamped log filename, sets $script:LogFile,
        writes an initial entry, and prunes old log files keeping only the 20 most recent.
    #>

    # Ensure the logs directory exists
    $logDir = $script:LogDir
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    # Create timestamped log file
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $logFileName = "gtnh-update-${timestamp}.log"
    $script:LogFile = Join-Path $logDir $logFileName

    # Write initial log entry
    $startTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $scriptDir = $script:ScriptDir
    $updaterVer = $script:UpdaterVersion ?? '?.?.?'
    $psVer = $PSVersionTable.PSVersion.ToString()
    $osInfo = [System.Environment]::OSVersion.VersionString

    $scriptDirRedacted = $scriptDir -replace '\\Users\\[^\\]+', '\Users\***' -replace '/Users/[^/]+', '/Users/***' -replace '/home/[^/]+', '/home/***' -replace '(?<=[A-Za-z]:/)Users/[^/]+', 'Users/***'

    $initMessage = @(
        "========================================"
        "GTNH Updater v$updaterVer - Log started at $startTime"
        "PowerShell: $psVer"
        "OS: $osInfo"
        "Script directory: $scriptDirRedacted"
        "========================================"
    ) -join [Environment]::NewLine

    $initMessage | Out-File -FilePath $script:LogFile -Encoding UTF8

    # Prune old logs: keep only the 20 most recent .log files
    $logFiles = Get-ChildItem -LiteralPath $logDir -Filter '*.log' | Sort-Object Name
    $maxLogs = 20
    if ($logFiles.Count -gt $maxLogs) {
        $filesToDelete = $logFiles | Select-Object -First ($logFiles.Count - $maxLogs)
        foreach ($file in $filesToDelete) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force
            }
            catch {
                # Silently continue if we can't delete an old log
            }
        }
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Appends a timestamped message to the current log file.
    .DESCRIPTION
        Writes a message with HH:mm:ss timestamp prefix to the log file set by
        Initialize-Logging. If logging has not been initialized ($script:LogFile
        is null or empty), silently returns without error.
    .PARAMETER Message
        The message text to write to the log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string]$Message
    )

    # If logging not initialized, silently return
    if ([string]::IsNullOrEmpty($script:LogFile)) {
        return
    }

    $timestamp = Get-Date -Format 'HH:mm:ss'
    # Redact usernames from paths before writing to log (handles both slash directions)
    $safeMessage = $Message -replace '\\Users\\[^\\]+', '\Users\***' -replace '/Users/[^/]+', '/Users/***' -replace '/home/[^/]+', '/home/***' -replace '(?<=[A-Za-z]:/)Users/[^/]+', 'Users/***'
    try {
        "${timestamp}  ${safeMessage}" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    } catch {
        # Log directory may have been deleted — silently fail
    }
}
