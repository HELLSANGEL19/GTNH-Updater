# Contributing

## Project Structure

```
GTNHUpdater/
  Update-GTNH.ps1              Entry point, version check, lock file, main dispatch
  Launch-GTNHUpdater.bat        Desktop shortcut launcher
  lib/                          Module files (16 files)
    DisplayHelpers.ps1          Banner, colors, prompts, input helpers
    Logging.ps1                 Structured log files with PII redaction
    ConfigManager.ps1           JSON config load, save, validate, export, import
    Detection.ps1               Auto-detect Java, AMP, Prism, MultiMC, PolyMC, ATLauncher, version from changelogs
    SetupWizard.ps1             First-run interactive setup
    NetworkApi.ps1              Downloads with progress/speed, API calls, integrity check, version history scraping, self-update
    FilePreservation.ps1        Preserve and restore critical files across updates
    CustomMods.ps1              Mod base name normalization for version-independent matching
    ConfigPatcher.ps1           Config patching with browse, templates, import/export, section awareness
    StableEngine.ps1            Preview-first stable/beta update with rollback and mod search
    NightlyEngine.ps1           Daily/Experimental via updater JAR with rollback
    Verification.ps1            Post-update integrity checks
    BackupManager.ps1           Backups, restore, retention, rollback snapshots
    CacheManager.ps1            Download cache, startup cleanup, pruning
    HistoryVersion.ps1          Update history tracking and version mismatch warnings
    MenuSystem.ps1              Main menu, settings, changelog viewer, update history, main loop
  tests/
    check-syntax.ps1            Parse-check all files (requires PS7)
```

## Development Requirements

- PowerShell 7.0 or newer
- No external modules or dependencies

## Syntax Check

After making changes, run the syntax checker to verify all files parse correctly:

```powershell
pwsh -File tests\check-syntax.ps1
```

This uses the PowerShell AST parser to check every `.ps1` file without executing them. Must be run on PS7 (PS5.1 will flag PS7 syntax as errors).

## Code Conventions

- 4-space indentation
- Single quotes for string literals, double quotes for interpolation
- All display output goes through the `Write-*` functions in `DisplayHelpers.ps1`
- All user input goes through `Read-MenuChoice`, `Read-UserInput`, or `Confirm-Action`
- Error handling with try/catch throughout
- `$script:` scope for global variables defined in `Update-GTNH.ps1`
- Use `-LiteralPath` instead of `-Path` for all file operations with variable paths (prevents square bracket interpretation)
- Use `New-Item -Path` for creating directories (not affected by wildcards)

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
| `.updater.lock` | Single run | Removed in finally block |

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
