# Changelog

## [1.1.0-beta] - 2026-04-30

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
