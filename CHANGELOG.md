# Changelog

## [0.2.0-beta] - 2026-05-05

### Added

* lib/Version.ps1 extracted as a dedicated version file; version string removed from main script
* Client preservation now includes the full config/NEI directory and config/shaders.properties

### Fixed

* Config patcher now correctly resets section tracking on closing braces, preventing cross-section key matches
* Duplicate Save-Config call removed from nightly update flow
* SHA256 hash fetch now has a 10-second timeout to avoid hanging on slow responses
* Fixed a brace alignment bug in stable engine hash-fetching block
* $latestNorm moved outside server/client blocks so client version comparison works correctly

### Improved

* Pack type display now shows human-readable labels (Java 17+ / Java 8) instead of raw config values
* Custom mod marking prompt consolidated into a single Read-UserInput call
* Update history table widened to accommodate longer version strings
* Mod count verification threshold lowered from 400 to 150 JARs
* Version string corrected in README and CHANGELOG
* Dot-source paths use $script:ScriptDir consistently

## [0.1.3-beta] - 2026-05-05

### Added
- **Linux support**: New `Launch-GTNHUpdater.sh` launcher with package manager detection (apt, dnf, pacman, zypper, snap)
- **Cross-platform detection**: Java scans `/usr/lib/jvm/`, SDKMAN, `$JAVA_HOME` on Linux; server detection scans `/opt/`, `~/servers/`, `~/Games/`; client detection scans `~/.local/share/PrismLauncher/`, flatpak paths, etc.
- **Setup wizard asks what you manage**: New step asks "server only / client only / both" and skips irrelevant detection steps
- **Auto-target selection**: If only one target is configured, update skips the "server/client/both?" menu entirely
- **Duplicate mod detection**: Post-update verification catches multiple versions of the same mod (e.g., xmod-2.0.3.jar and xmod-2.0.5.jar)
- **Custom mods validation**: New `[V] Validate` option checks for stale/outdated entries and offers auto-fix
- **Custom mods auto-check at startup**: Warns if tracked mods are outdated or missing
- **Java path validation at startup**: Warns if configured Java path no longer exists
- **Export/Import directly in Settings**: No longer a sub-menu, just `[E]` and `[I]` options

### Fixed
- **Atomic lock file**: Replaced check-then-create with `FileMode::CreateNew` to eliminate race condition
- **Partial download cleanup**: Failed downloads no longer leave corrupted files on disk
- **Failed backup cleanup**: Partial backup folders are removed if the backup fails mid-copy
- **Web request timeouts**: All API calls have 30-second timeouts; file downloads have 10-minute timeouts
- **Path normalization on Linux**: Uses `[IO.Path]::DirectorySeparatorChar` instead of hardcoded backslash
- Mod search in version picker and custom mods browser uses -ilike for case-insensitive matching
- Critical error box word-wraps long error messages instead of truncating
- Setup wizard Read-Host calls replaced with Read-UserInput for consistency
- Setup wizard version input validates X.Y.Z format on all paths
- SHA256 hash fetch warns on unexpected network errors instead of silently skipping
- NightlyEngine cleanup null guard applied to all customModTempDir Test-Path calls
- View Logs menu sorts by filename instead of LastWriteTime
- Scan flow in Custom Mods menu was using Read-Host instead of Read-UserInput
- Manual version entry validates X.Y.Z format and loops until valid
- Removed config patch templates that pointed to non-existent config files
- Get-ModBaseName regex is now case-insensitive
- Test-ConfigPatches correctly tracks section headers

### Improved
- **Renamed `Find-AmpInstances` to `Find-ServerInstances`**: Scans for any GTNH server, not just AMP
- **Custom mods menu auto-selects target**: Skips "which one?" prompt when only one is configured
- **Cross-platform file manager**: `Open-FolderInFileManager` uses `xdg-open` on Linux, `explorer.exe` on Windows
- **Platform-appropriate path examples**: Settings menus show Linux paths on Linux, Windows paths on Windows
- Setup wizard custom mod picker supports N/P pagination for large mod lists
- Version cache block extracted into Update-VersionCache helper function
- Changelog viewer word-wraps long lines at 76 chars
- What's new banner reads full CHANGELOG.md instead of only first 30 lines
- Removed dead $abbreviatePath scriptblock from Show-MainMenu
- Config patch template library expanded from 1 to 9 verified templates
- FilePreservation calls Write-Log on preserve/restore
- Log pruning sorts by filename instead of LastWriteTime
- Preservation lists now include opencomputers/, config/NEI.cfg, maps/

## [0.1.2.7-beta] - 2026-05-03

### Fixed
- Self-update check now uses /releases endpoint instead of /releases/latest
- Self-update response handler handles both array and single-object API responses

## [0.1.2.5-beta] - 2026-05-02

### Fixed
- Re-applied missing 404 silent handler in NetworkApi.ps1
- Java 8 pack users no longer have Java 17 instance-root items incorrectly moved
- Removed dead $javaVersion variable from Save-RollbackSnapshot
- Startup cleanup skips staging folders modified within the last 2 hours
- Post-update verification mod count threshold raised from 200 to 400
- PS5 error banner dynamically pads the version string
- Renamed Validate-Config to Repair-Config (approved verb list)

## [0.1.2.4-beta] - 2026-05-01

### Fixed
- Self-update check now uses semantic version comparison instead of string equality
- Version picker date now correctly shows for the latest/newest release

## [0.1.2.3-beta] - 2026-05-01

### Fixed
- Version picker date column now always renders in Gray regardless of install state

## [0.1.2.1-beta] - 2026-05-01

### Fixed
- GitHub API 404 responses handled silently instead of flashing an error
- Version input validates X.Y.Z format, preventing invalid values
- Startup config repair corrects invalid version strings

## [0.1.2-beta] - 2026-04-30

### Fixed
- Version history page regex updated to match HTML span tags
- Version detection validates gtnh_version.txt content
- Self-update API URL corrected to match actual GitHub repo name

## [0.1.1-beta] - 2026-04-30

### Added
- Version picker for stable channel showing all releases with dates and color coding
- Beta/RC version support through the version picker
- Custom mod scanner comparing against official GitHub mod list
- Version auto-detection from changelog files
- Independent server/client version detection
- Auto-detect installed version on startup if unknown
- Path validation on startup with warnings
- Self-update with automatic download and install from GitHub

### Changed
- Downgrade detection covers nightly-to-older-base, zip-to-older-zip, and beta ordering
- Main menu condensed: beta info on same line as stable
- Self-update detection simplified to tag comparison

### Fixed
- $matches variable shadowing PowerShell automatic $Matches
- Downgrade warning uses channel label instead of hardcoded "stable"
- Version comparison handles beta suffixes correctly

## [0.1.0-beta] - 2026-04-29

Initial beta release.
