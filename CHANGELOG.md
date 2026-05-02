# Changelog

## [0.1.2.5-beta] - 2026-05-02

### Fixed
- Re-applied missing 404 silent handler in NetworkApi.ps1 (lost during force-push)
- Java 8 pack users no longer have Java 17 instance-root items (libraries/, patches/, mmc-pack.json) incorrectly moved during client updates
- Removed dead $javaVersion = 'java17' variable from Save-RollbackSnapshot in BackupManager.ps1
- Startup cleanup now skips staging folders modified within the last 2 hours, preventing wipeout if the tool is reopened mid-update
- Post-update verification mod count threshold raised from 200 to 400 (GTNH 2.8.x ships ~580 mods)
- PS5 error banner now dynamically pads the version string to prevent box border misalignment
- Renamed Validate-Config to Repair-Config to comply with PowerShell approved verb list
## [0.1.2.4-beta] - 2026-05-01

### Fixed
- Self-update check now uses semantic version comparison instead of string equality, so local versions newer than the latest GitHub release no longer trigger a false update prompt

## [0.1.2.5-beta] - 2026-05-02

### Fixed
- Re-applied missing 404 silent handler in NetworkApi.ps1 (lost during force-push)
- Java 8 pack users no longer have Java 17 instance-root items (libraries/, patches/, mmc-pack.json) incorrectly moved during client updates
- Removed dead $javaVersion = 'java17' variable from Save-RollbackSnapshot in BackupManager.ps1
- Startup cleanup now skips staging folders modified within the last 2 hours, preventing wipeout if the tool is reopened mid-update
- Post-update verification mod count threshold raised from 200 to 400 (GTNH 2.8.x ships ~580 mods)
- PS5 error banner now dynamically pads the version string to prevent box border misalignment
- Renamed Validate-Config to Repair-Config to comply with PowerShell approved verb list
## [0.1.2.4-beta] - 2026-05-01

### Fixed
- Version picker date now correctly shows for the latest/newest release - the HTML search window was 500 chars but the latest release has extra badge HTML pushing the date to ~583 chars away

## [0.1.2.3-beta] - 2026-05-01

### Fixed
- Version picker date column now always renders in Gray regardless of install state, making it visible for the installed/latest entry

## [0.1.2.1-beta] - 2026-05-01

### Fixed
- GitHub API 404 responses are now handled silently instead of flashing an error before the main menu (affected private repos and installs with no releases published)
- Version input in setup wizard and settings now validates X.Y.Z format, preventing invalid values like "2" from being saved
- Startup config repair now also corrects invalid version strings, not just empty ones (silent auto-fix on next launch)

## [0.1.2-beta] - 2026-04-30

### Fixed
- Version history page regex updated to match HTML span tags (was finding zero releases)
- Version detection validates gtnh_version.txt content (rejects non-version strings like "2")
- Self-update API URL corrected to match actual GitHub repo name

## [0.1.1-beta] - 2026-04-30

### Added
- Version picker for stable channel showing all releases (stable + beta/RC) with dates and color coding
- Beta/RC version support through the version picker (no channel switching needed)
- Custom mod scanner that compares mods/ folder against the official GitHub mod list
- Version auto-detection from changelog files in the instance folder
- Independent server/client version detection in setup wizard and settings
- Auto-detect installed version on startup if unknown
- Path validation on startup with warnings if configured paths no longer exist
- Self-update with automatic download and install from GitHub releases
- Release dates (MM/DD/YYYY) shown in the version picker
- Installed version marker in the version picker
- Latest stable and latest beta indicators in the version picker

### Changed
- Downgrade detection now covers nightly-to-older-base, zip-to-older-zip, and same-base beta ordering
- Main menu condensed: beta info on same line as stable, removed paths (available in Settings)
- Startup flow cleaned up: removed messages that get cleared by main menu
- Banner borders aligned to match block letter width, UPDATER line dynamically centered
- Self-update detection simplified to tag comparison (any different tag = update available)
- Version string automatically patched from release tag after self-update

### Fixed
- $matches variable shadowing PowerShell automatic $Matches in Get-WebsiteReleases
- Downgrade warning now uses channel label instead of hardcoded "stable"
- Version comparison handles beta suffixes correctly (2.8.0-beta-4 parses properly)
- Type field normalized to title case for consistent comparison
- Dead novelty release filter removed (regex already excluded non-version strings)

## [0.1.0-beta] - 2026-04-29

Initial beta release.
