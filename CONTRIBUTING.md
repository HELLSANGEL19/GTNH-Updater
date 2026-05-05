# Contributing

## Project Structure

```
GTNHUpdater/
  Update-GTNH.ps1              Entry point, version check, atomic lock file, main dispatch
  Launch-GTNHUpdater.bat       Desktop shortcut launcher (Windows)
  Launch-GTNHUpdater.sh        Shell launcher (Linux)
  lib/                         Module files (16 files)
    DisplayHelpers.ps1         Banner, colors, prompts, input helpers, cross-platform file manager
    Logging.ps1                Structured log files with PII redaction
    ConfigManager.ps1          JSON config load, save, validate, export, import
    Detection.ps1              Auto-detect Java, servers, Prism, MultiMC, PolyMC, ATLauncher, version
    SetupWizard.ps1            First-run interactive setup (adapts to server/client/both)
    NetworkApi.ps1             Downloads with progress/speed, API calls, integrity check, self-update
    FilePreservation.ps1       Preserve and restore critical files across updates
    CustomMods.ps1             Mod base name normalization for version-independent matching
    ConfigPatcher.ps1          Config patching with browse, templates, import/export, section awareness
    StableEngine.ps1           Preview-first stable/beta update with rollback and mod search
    NightlyEngine.ps1          Daily/Experimental via updater JAR with rollback
    Verification.ps1           Post-update integrity checks and duplicate mod detection
    BackupManager.ps1          Backups, restore, retention, rollback snapshots
    CacheManager.ps1           Download cache, startup cleanup, pruning
    HistoryVersion.ps1         Update history tracking and version mismatch warnings
    MenuSystem.ps1             Main menu, settings, changelog viewer, update history, main loop
```

## Development Requirements

- PowerShell 7.0 or newer
- No external modules or dependencies

## Code Conventions

- 4-space indentation
- Single quotes for string literals, double quotes for interpolation
- All display output goes through the `Write-*` functions in `DisplayHelpers.ps1`
- All user input goes through `Read-MenuChoice`, `Read-UserInput`, or `Confirm-Action`
- Error handling with try/catch throughout
- `$script:` scope for global variables defined in `Update-GTNH.ps1`
- Use `-LiteralPath` instead of `-Path` for all file operations with variable paths (prevents square bracket interpretation)
- Use `New-Item -Path` for creating directories (not affected by wildcards)
- All web requests must include `-TimeoutSec` (30s for API calls, 10min for downloads)
- Clean up partial files on failure (downloads, backups, staging folders)

## Cross-Platform Guidelines

The script supports both Windows and Linux. Use these patterns:

- **Platform branching**: Use `$IsWindows` and `$IsLinux` automatic variables (PS7+)
- **Java binary**: Use `if ($IsWindows) { 'java.exe' } else { 'java' }` when referencing the binary name
- **Path separators**: Use `[IO.Path]::DirectorySeparatorChar` when normalizing stored paths. PowerShell handles `/` on both platforms in most contexts, but stored config paths use `/` as the canonical separator.
- **Opening folders**: Use `Open-FolderInFileManager` (in DisplayHelpers.ps1) instead of calling `explorer.exe` directly
- **Path examples in UI**: Show platform-appropriate examples using `if ($IsWindows) { ... } else { ... }`
- **Instance detection**: Windows scans drive roots and AppData; Linux scans `~/.local/share/`, `~/Games/`, `/opt/`, etc.
- **Environment variables**: `$env:APPDATA` and `$env:LOCALAPPDATA` only exist on Windows. On Linux, use `$env:XDG_DATA_HOME` (defaults to `~/.local/share`) and `$HOME`.

## UX Principles

- **Skip unnecessary prompts**: If only one target (server/client) is configured, auto-select it instead of showing a menu with one option.
- **Validate early**: Check paths and custom mods at startup so users see problems before they try to update.
- **Flat menus where possible**: Export/Import are direct options in Settings, not a sub-menu. Custom mods auto-selects the target if only one exists.
- **Show what will happen**: The stable update preview shows every change before applying. No surprises.

## Reserved Variables

Do not use these as local variable names (PowerShell automatic variables):

`$args`, `$input`, `$this`, `$_`, `$Error`, `$Host`, `$Matches`, `$foreach`, `$switch`

## File Cleanup Rules

Every file or folder the script creates must have a cleanup path:

| Location | Retention | Cleanup |
|---|---|---|
| `logs/*.log` | 20 most recent | Pruned on startup |
| `cache/*` | 5 most recent | Pruned on startup |
| `backups/gtnh-backup-*` | Configurable (default 5) | Pruned after each backup |
| `.temp/*` | Single run | Cleaned in finally blocks + startup cleanup |
| `staging-*/` | Single run | Cleaned on success, startup cleanup removes stale |
| `.nightly-updater/*.jar` | 1 (newest) | Old JARs cleaned on startup |
| `*.broken-*.json` | 3 most recent | Pruned on startup |
| `.updater.lock` | Single run | Removed in finally block (held open via FileStream) |

## Adding a New Config Patch Type

The config patcher (`ConfigPatcher.ps1`) handles any `key=value` format. To add support for a new file format:

1. Update the regex in `Set-ConfigValue` to match the new pattern
2. Update the key parser in `Invoke-ConfigBrowse` to extract keys from the new format
3. Update the file filter in `Invoke-ConfigBrowse` to include the new extension

## Adding a Config Patch Template

Add a new entry to the `$templates` array in `Invoke-ConfigPatchMenu` (the `'E'` case):

```powershell
[PSCustomObject]@{
    Name        = 'Short description'
    FilePath    = 'config/path/to/file.cfg'
    Key         = 'B:keyName'
    Value       = 'newValue'
    Description = 'What this patch does'
}
```

## Adding Verification Checks

Post-update verification lives in `Verification.ps1`. To add a new check:

1. Add the check logic inside `Invoke-Verification`
2. Use `Write-Success` for passes and `Write-Warn` for issues
3. Set `$allPassed = $false` if the check fails
4. Update the header comment with the new check description
