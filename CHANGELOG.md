# Changelog

## [0.4.6-beta] - 2026-05-21

### Added

* Backups now stored as compressed .zip files — significantly smaller on disk than raw folder copies
* Rollback snapshots now persist until the next update — allows rollback even if the game crashes after a successful update
* "Rollback last update" option in Settings > Backups and Cache — restores mods/config/scripts to pre-update state
* Backup progress bar with ETA matching the style used for mod downloads
* Backup integrity verification (warns if backup appears incomplete)
* Internal directories (logs, crash-reports, cache, .temp, backups) always excluded from backups
* Already-compressed files (.jar, .zip, .png, .ogg, etc.) stored without re-compression for speed
* Delete individual backups from the Manage Backups menu

### Fixed

* Server backups now only back up the server folder itself, not the entire parent directory (previously could back up 100 unrelated server folders if they shared a parent)
* Backup no longer fails on the `.gtnh-updater.lock` file (held open by the running process)
* Backup excludes rollback snapshot directories and the updater's own folder when inside the backup source
* Fixed `-or` parsing error in backup safety check that crashed when source had >10 subdirectories
* Restoring old-format server backups (created before 0.4.6) is detected automatically and handled correctly

## [0.4.5-beta] - 2026-05-19

### Added

* Running instance detection — blocks updates if the game/server is running (prevents file corruption)
* Downgrade warning — warns if the target version is older than what's installed
* Custom mod conflict warning — warns when marking a pack mod as custom (it won't receive updates)
* SHA1 checksum verification for downloaded mods (catches corrupted downloads from Maven)
* Download progress now shows estimated time remaining (both pack zip and individual mods)
* Stale auto-detected config patches are now offered for removal when the pack removes/renames those keys
* Stale custom mod detection for daily/experimental — warns when custom mod entries don't match any file on disk
* Interactive custom mod marking during daily/experimental updates — mark removed mods as custom on the fly
* Search in daily/experimental update plan — type a mod name to find it when 20+ mods are changing

### Improved

* Daily/experimental rollback now uses same-drive Move (instant) instead of Copy for config/scripts folders
* Update plan box style now matches stable updates (consistent DarkGray borders, version arrow)
* Custom mod scan for daily/experimental now correctly excludes external mods (UniMixins, Witchery, IC2, etc.) — previously flagged them as custom candidates
* Custom mod scan now also checks the mods/1.7.10/ subfolder (coremods)

### Fixed

* Full instance backup no longer runs endlessly if the backup directory is inside the instance root (infinite recursion)
* Backup size estimation capped to prevent hanging on very large directory trees

### Changed

* Config diff detection is now manual-only (Settings > Config Patches > Re-scan) — no longer runs automatically before updates (caused false positives from game-modified config files)

## [0.4.4-beta] - 2026-05-18

### Added

* Custom mod scan now works for daily/experimental channels (uses state file mod list)
* Config diff (re-scan for changes) now works for daily/experimental channels (downloads the correct config zip for the installed version)
* GTNH daily version format detection (GTNH-YYYY-MM-DD+NNN) in auto-detection and manual input
* Setup wizard and Settings now show daily version format examples and accept them
* Transition decision logging for easier diagnostics
* External mods now tracked in ManifestMods (fixes false positives in custom mod scan)
* Disk space pre-check before updates (warns if free space is low)
* GitHub API ETag caching (reduces rate limit usage, works offline with cached data)
* External mod downloads now run in parallel (same speed as Maven mods)
* Auto-detect config changes before daily/experimental updates (saves them as patches so they survive future updates)
* First-time update warning about config reset with guidance on how to re-scan afterward

### Fixed

* Lock file no longer gets stuck after closing the terminal window (uses OS-level file lock instead of PID file)
* Main menu no longer shows "nightly" in version labels (uses channel name or just the date)
* "Latest daily/experimental" label now uses the user's actual channel name and aligns properly
* User-facing messages replaced "nightly" with the actual channel name throughout
* Version input validation now accepts GTNH daily format (GTNH-YYYY-MM-DD+NNN)
* Backup cleanup now correctly finds old backups to prune (was looking for wrong folder name pattern)
* Java detection in setup wizard no longer leaks temp files
* Backup safety check prevents accidentally backing up an entire instances folder
* Stale version cache after profile switch (menu could show wrong "latest" version)
* Zip file handles now properly released on errors (4 locations could lock files on Windows)
* Network requests to gtnh-assets.json now have 30-second timeout (could hang indefinitely)
* Pasted paths with trailing backslash no longer cause issues
* GitHub API 304 handling works correctly on all PowerShell 7.x versions
* Update plan no longer shows "Current version" in yellow (was confusing - looked like a warning)
* Mod update list in both stable and daily previews uses readable colors instead of a wall of yellow text
* Daily/experimental update plan no longer shows updated mods in the "removed" list
* Custom mods no longer accidentally deleted if you manually update them to a newer version
* Override mod version conflicts now shown in the update plan
* Update history now shows mod change counts for daily/experimental updates

### Improved

* Update confirmation defaults to Yes (just press Enter to proceed after reviewing the plan)
* Settings changes no longer require "press any key" after each toggle
* Target selection remembers your last choice (press Enter to repeat)
* Faster verification for daily/experimental updates (skips deep jar scan since the updater controls all mods)
* Smarter download cache pruning (keeps one file per category instead of just the 5 newest)
* Config change detection now shows both your value and the pack default side-by-side
* Faster daily/experimental updates — rollback snapshot only backs up mods being replaced
* Faster stable updates — rollback step is now near-instant
* Faster mod comparison during daily/experimental updates
* Daily/experimental update plan now shows all updated mods (no longer capped at 15)

## [0.4.3-beta] - 2026-05-14

### Fixed

* Config patcher crash when reading files ("Cannot bind argument to parameter 'Lines'")
* Config patches now apply reliably on all systems regardless of file encoding or content
* Expanded client file preservation to match GTNH wiki (visualprospecting, TCNodeTracker, saves, schematics, screenshots, shaderpacks, localconfig.cfg, BotaniaVars.dat)
* Added visualprospecting to server preservation list
* Version detection now re-runs on every startup (fixes stale version display when switching between updater instances)
* Linux launcher script now has executable permission set in the repo

### Improved

* Added debug logging to config patch pre-flight validation for easier troubleshooting

## [0.4.2-beta] - 2026-05-14

### Fixed

* Stale nightly state detection: spot-checks mods on disk vs recorded state
* Custom mods that conflict with manifest mods are now skipped during stable-to-nightly transition
* "Already on this version" check moved after state validation to prevent false positives

## [0.4.1-beta] - 2026-05-12

### Fixed

* Hotfix re-release of 0.4.0 with corrected files

## [0.4.0-beta] - 2026-05-12

### Added

* Native daily/experimental update engine (no external binaries, no Java, no Git required)
* Downloads mods directly from GTNH Maven with GitHub fallback
* Downloads external mods from gtnh-assets.json database
* Parallel mod downloads (up to 8 concurrent)
* Stable-to-nightly transition with clean wipe and custom mod preservation
* Nightly state tracking (.gtnh-nightly-state.json)
* Main menu shows latest daily version from DreamAssemblerXXL manifest
* "Mods updated" hint when manifest is newer than config tag date

### Fixed

* HttpClient resource leaks (8 locations)
* Config sync no longer overwrites Maven-sourced mods from the release zip
* Atomic writes for config and state files
* Lock file mechanism to prevent concurrent runs
* Self-update recovery on failure
* Profile management edge cases
* Linux disk space detection
* Zip handle leaks
* Nested section key collisions in config diff
* Double-nested zip detection
* Version comparison ordering

### Improved

* Cleaner console output: collapsed preserve/restore lists, progress bar for external mods, collapsed verification into pass/fail
* README rewritten (trimmed, user-focused)
* CONTRIBUTING updated with development guidelines

## [0.3.1-beta] - 2026-05-11

### Improved

* Daily/Experimental updates now use the gtnh-daily-updater Go binary instead of the Java-based nightly updater JAR ΓÇö Java 21+ is no longer required
* Switched nightly updater source to the Caedis/gtnh-daily-updater GitHub repository
* Updated README, help screen, and channel descriptions to reflect no Java requirement for daily/experimental channels


## [0.3.0-beta] - 2026-05-08

### Added

* Multiple profiles support: create, switch, rename, and delete independent GTNH instances from Settings > Profiles
* Setup wizard now offers to create a second profile after initial configuration
* Config auto-detection: stable updates automatically compare configs against pack defaults and save detected changes as patches
* Active profile indicator on main menu status line
* Override mods lists (OverrideServerMods, OverrideClientMods) with counts shown on main menu
* Pre-update backup warning prompt shown before download begins
* Pre-flight disk space check before downloading pack zip
* Write-BackupWarning helper for color-coded backup reminder box
* Test-IsNetworkException and New-ZipUrls helpers to reduce duplication in NetworkApi

### Fixed

* Disk space check in BackupManager now uses DriveInfo.AvailableFreeSpace instead of PSDrive.Free for accuracy
* Startup cleanup no longer deletes rollback snapshots (deferred to main loop after user notification)
* Linux file manager launch uses array arguments instead of quoted string to handle paths with spaces
* Join-Path in Verification uses separate arguments instead of backslash concatenation for cross-platform correctness

### Improved

* Remove-TempDir helper consolidates repeated temp directory cleanup patterns across StableEngine and NightlyEngine
* Find-KeyInLines extracted as a standalone function in ConfigPatcher with proper brace-depth tracking for section-aware key lookup
* Target selection menu wrapped in a loop for consistent re-prompt behavior
* Get-ProfileList and Switch-Profile added to ConfigManager for profile management


## [0.2.1-beta] - 2026-05-06

### Added
- Path input now strips surrounding quotes (Windows "Copy as path" behaviour) and expands leading ~ to the home directory
- Config repair now expands tilde paths saved by Linux users on startup
- Help screen now includes "What Gets Replaced" and "What Gets Preserved" sections
- Config patches from browse/templates now preserve the Section field when added
### Fixed
- Config section tracking now resets on closing }, preventing keys from wrong sections matching patches
- Self-update path calculation no longer breaks when the content root ends with a directory separator
- Java process arguments now use ArgumentList array instead of a manually quoted string, fixing paths with spaces
- Cache clear now uses Get-ChildItem | Remove-Item instead of a wildcard path to avoid edge cases
- Removed duplicate error log lines in file preservation and restore error handlers
### Improved
- Client preservation list corrected: replaced config/journeymap with config/vendingmachine; optionsnf.txt replaces optionsof.txt
- Server preservation list corrected: config/JourneyMapServer/ replaces journeymap/
- README: fixed GTNH release cycle order (Experimental -> Daily -> Beta -> Stable), mod count threshold (150+), preserved files lists, and a stray version string in the stable update description
- Mod scan selection prompt uses Read-Host directly to avoid double-processing by Read-UserInput
- Help screen update description tightened for clarity


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
* Update history mod diff now shows labeled counts (e.g. `+9 added  -9 removed  ~179 updated`) instead of raw symbols

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
