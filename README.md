# GTNH Updater

**Version 0.3.1-beta**

Automates updating [GregTech: New Horizons](https://www.gtnewhorizons.com/) server and client instances on Windows and Linux. Interactive and menu-driven. Works with any server setup and any launcher that uses a standard `.minecraft` folder structure (Prism Launcher, MultiMC, PolyMC, ATLauncher, etc.). Auto-detection finds common server paths and launcher directories, but any instance path can be entered manually.

> **Beta**: This tool has been reviewed and tested for correctness but has not yet been validated at scale with real GTNH instances. Please back up your instance before using it. Report issues on GitHub.

## Requirements

- **Windows 10/11 or Linux** (any distro with a desktop environment or headless server)
- **PowerShell 7** - The launcher will offer to install it for you if it's not found. Or [download it manually](https://github.com/PowerShell/PowerShell/releases).

## Getting Started

### Windows

1. Download or clone this repository
2. Double-click **`Launch-GTNHUpdater.bat`**
   - If PowerShell 7 isn't installed, it will offer to install it via `winget`
3. The setup wizard walks you through everything on first run

To put it on your desktop, right-click `Launch-GTNHUpdater.bat`, select "Create shortcut", and move the shortcut to your desktop.

If the `.bat` file closes instantly, open PowerShell 7 manually (search for "pwsh" in the Start menu) and run:

```powershell
cd "C:\path\to\GTNHUpdater"
.\Update-GTNH.ps1
```

### Linux

1. Download or clone this repository
2. Make the launcher executable and run it:
   ```bash
   chmod +x Launch-GTNHUpdater.sh
   ./Launch-GTNHUpdater.sh
   ```
   - If PowerShell 7 isn't installed, it will offer to install it via your package manager (apt, dnf, pacman, zypper, or snap)
3. The setup wizard walks you through everything on first run

Or if you already have `pwsh` installed, run directly:

```bash
pwsh -File ./Update-GTNH.ps1
```

## How It Works

### Setup Wizard

On first run, the wizard asks:
1. What you manage (server only, client only, or both)
2. Detects Java installations
3. Detects GTNH instances (skips server or client steps based on your answer)
4. Sets preferences (channel, pack type, version)
5. Optionally configures custom mods and config patches
6. Optionally sets up a second profile (e.g. a daily test instance)

If you only manage a server, you'll never be asked about client paths. The tool adapts to your setup.

### Stable Updates

When you select **Update GTNH** with the Stable channel:

1. Shows a **Version 0.3.1-beta** listing all available releases (stable and beta/RC), newest first
2. If both server and client are configured, asks which target. If only one is configured, it's selected automatically.
3. Downloads the selected pack (with progress bar and speed display) and verifies integrity
4. Extracts to a staging folder for preview
5. Shows a full color-coded mod comparison:
   - Green: new mods added to the pack
   - Red: mods removed (with option to mark as custom)
   - Yellow: mods with version updates
   - Cyan: your custom mods that will be preserved
6. Lets you search mods by name if the list is long
7. Shows what folders will be deleted
8. Reminds you to back up before applying
9. Lets you choose: **Apply**, **Open staging folder**, or **Cancel**
10. If you apply: saves a rollback snapshot, preserves your files, replaces the pack, restores your files, applies config patches, and runs verification

You always see what will happen before anything is changed.

### Daily / Experimental Updates

When you select Daily or Experimental:

1. If both targets are configured, asks which one. Otherwise auto-selects.
2. Checks that Java 21+ is available
3. Downloads or updates the official updater JAR
4. Backs up your custom mods from the saved list
5. Reminds you to back up before proceeding
6. Runs the updater JAR, which downloads individual mods from the GTNH Maven
7. Restores your custom mods
8. Applies config patches and runs verification

Daily/Experimental updates do not have a preview step. The updater JAR handles downloading and applying changes directly, and its output is streamed to the console (and saved to the log file).

If something goes wrong mid-update, the tool offers automatic rollback for both stable and daily updates.

## Update Channels

| Channel      | What it is                                              |
|--------------|---------------------------------------------------------|
| Stable       | Official releases from gtnewhorizons.com. Recommended. The version picker also lists beta/RC builds. |
| Daily        | Dev builds from GitHub. Updated daily. |
| Experimental | Bleeding-edge builds from GitHub. May be unstable. |

GTNH's release cycle is: Experimental -> Daily -> Beta -> Stable. When you pick "Update GTNH" on the Stable channel, the version picker shows both stable and beta/RC releases from the [version history page](https://www.gtnewhorizons.com/version-history). No channel switching needed to install a beta.

Daily and Experimental channels use the official [gtnh-nightly-updater](https://github.com/GTNewHorizons/gtnh-nightly-updater) JAR, which downloads individual mods from the GTNH Maven. No Java 21+ is needed for stable updates.

## Features

### Config Patches

Settings you always change after an update (like disabling pollution) can be saved as patches. They get applied automatically after every update. You can:
- **Browse** config files interactively and pick keys to preserve or change
- **Add manually** by entering file path, key, and value (with examples and validation)
- Pick from **common patches** (pollution, render distance, command blocks, etc.)
- **Export/import** patches to share with friends
- **Test** patches without applying them

**Auto-detection**: During stable updates, the updater automatically compares your config files against the pack's defaults to detect settings you have changed. Confirmed changes are saved as patches automatically — no manual setup needed. You can also trigger a manual scan at any time from Settings > Config Patches > Re-scan, which downloads the current version's pack zip (or uses the cache) and compares it against your instance.

Supports Forge `.cfg` files, `.properties` files, and `server.properties`. Section-aware matching handles duplicate keys in different config sections.

### Custom Mods

Mods you have added that are not part of the GTNH pack are preserved during updates. You can manage them in several ways:
- **Scan** against the official mod list to automatically find custom mods (compares your mods/ folder against the GitHub mod list for your version)
- **Browse** the mods/ folder and pick from a list (no typing filenames)
- **Add manually** by typing filenames (with validation and examples)
- **Validate** your custom mods list to find stale or outdated entries and auto-fix them (e.g., a mod was updated from v2.0.3 to v2.0.5 and the tracked filename no longer matches)

During stable updates, unknown mods are detected automatically and you can mark them as custom in the preview. For daily/experimental updates, only mods saved in your custom mods list are preserved (there is no preview step), so make sure to add your custom mods in Settings before running a daily update.

On startup, the tool checks your custom mods list against the actual mods/ folder. If any entries are stale (mod removed or filename changed from a version bump), you'll see a warning directing you to Settings > Custom Mods > Validate to review and auto-fix.

### Post-Update Verification

After every update, the tool automatically checks:
- Critical directories exist (mods/, config/, libraries/)
- Mod count is reasonable (150+ JARs expected for GTNH)
- GregTech core mod is present
- No duplicate mods (catches cases like `xmod-2.0.3.jar` and `xmod-2.0.5.jar` both present)
- Target-specific files (server.properties, options.txt, etc.)

### Download Integrity

Downloaded pack zips are verified with SHA256 checksums when available. Corrupted downloads are caught before they can damage your instance, and bad cached files are automatically removed. Partial downloads from interrupted connections are cleaned up automatically.

### Automatic Rollback

Before applying an update, the tool saves a snapshot of everything it's about to change. If the update fails mid-way, it offers one-click rollback to restore your instance. Works for both stable and daily updates. If the script detects leftover rollback snapshots on startup (from an interrupted update), it will notify you.

### Config Export/Import

Moving to a new machine? Export your full configuration (paths, custom mods, patches) to a file and import it on the new machine. Available directly from the Settings menu.

### GTNH Changelog Viewer

View the changelog for any recent GTNH release directly from the main menu. Fetches release notes from GitHub so you can see what changed before deciding to update.

### Update History

View a log of all past updates with dates, versions, channels, and targets from the main menu.

### Version Auto-Detection

The updater automatically detects your installed GTNH version from changelog files in your instance folder (e.g., "changelog from 2.7.3 to 2.7.4.txt"). Server and client versions are detected independently. This runs during the setup wizard and on every startup if the version is unknown.

### Self-Update

The updater checks for new versions of itself on startup. If a newer release is available on GitHub, it offers to download and install the update automatically. After updating, it exits so you can restart with the new version. No manual download needed.

### Multiple Profiles

Profiles let you manage multiple independent GTNH instances — for example, a main server and a daily/experimental test instance — each with its own paths, channel, custom mods, config patches, and version tracking.

Each profile is a separate config file in the updater folder:

```
gtnh-updater-config.json           ← default profile
gtnh-updater-config-daily.json     ← "daily" profile
gtnh-updater-config-experimental.json
```

**At startup**, if more than one profile exists, you'll be asked which one to use. If you only have one profile (the common case), startup is unchanged.

**In Settings > Profiles** you can:
- **Create** a new profile — either copied from the current one (same paths, mods, patches as a starting point) or started fresh with the setup wizard
- **Switch** to a different profile mid-session
- **Rename** the active profile's display label
- **Delete** a profile (blocked if it's the only one)

The active profile name is shown on the main menu status line (only when a non-default profile is active).

## Main Menu

```
[1] Update GTNH (channel)
[2] Settings
[3] View logs
[4] View GTNH changelog
[5] Update history
[H] Help
[Q] Quit
```

The main menu shows your installed versions, the latest available version, your channel, and counts of custom mods and config patches. Versions are color-coded: green if up to date, yellow if an update is available.

## Settings

Settings are organized into groups:

- **Instance paths** - Server, client, and Java paths (with platform-appropriate examples)
- **Update preferences** - Default channel, Java version for downloads, installed version, auto-update check
- **Custom mods** - Scan, browse, add, validate, remove, or clear (auto-selects server/client if only one is configured)
- **Config patches** - Browse, add, edit, import/export, test, re-scan for changes, or clear patches
- **Backups and cache** - Backup settings, manage backups, manage download cache
- **Re-run setup wizard** - Start the guided setup again
- **Export config [E]** - Save your full configuration to a file
- **Import config [I]** - Restore configuration from a file
- **Profiles [P]** - Create and manage multiple profiles (see below)

## Backups

The script does **not** create persistent backups by default (they can use a lot of disk space). You can enable them in Settings > Backups and Cache.

Before every update, the script saves a **rollback snapshot** automatically. If the update fails mid-way, it offers to restore your instance to its pre-update state. This snapshot is temporary and deleted after a successful update.

For full protection, maintain your own backups:

- **Server**: Use your server management tool or copy the server folder
- **Client**: Export your launcher instance or copy the `.minecraft` folder

## Files Preserved During Updates

### Server
- `config/JourneyMapServer/` - Server JourneyMap UUID (clients lose map data if this is lost)
- `serverutilities/` - Server Utilities config and data
- `ops.json`, `whitelist.json`, `server.properties`
- `banned-ips.json`, `banned-players.json`

### Client
- `journeymap/` - Client JourneyMap waypoints and maps
- `config/NEI/` - NEI settings, hidden items, bookmarks
- `config/shaders.properties` - Active shader selection
- `config/vendingmachine/` - Vending machine favourites
- `options.txt`, `optionsnf.txt`, `servers.dat`
- `resourcepacks/`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "PowerShell 7+ Required" | You used `powershell` instead of `pwsh`. Use the launcher (`.bat` on Windows, `Launch-GTNHUpdater.sh` on Linux) or open PowerShell 7 manually. |
| "Java 21 or newer is required" | Only affects Daily/Experimental channels. Update the Java path in Settings. Stable works with any Java. |
| Download fails or times out | Check your internet connection. Previously downloaded files are cached and reused. API requests time out after 30 seconds. |
| Update failed after applying | The tool will offer automatic rollback. If that fails, restore from your own backup. |
| Download integrity check failed | The file may be corrupted. Clear the cache in Settings and try again. |
| "Another instance may be running" | A previous run crashed without cleaning up. Choose yes to continue. |
| "Java path no longer exists" | Java was updated or moved. Update the path in Settings > Instance Paths. |
| Custom mods warning at startup | Some tracked mods have changed. Go to Settings > Custom Mods > Validate to auto-fix. |
| Duplicate mods detected | Multiple versions of the same mod in your mods/ folder. Remove the older one(s). |
| Config file is broken | Delete `gtnh-updater-config.json` and re-run. The setup wizard will start fresh. |
| Want to reset everything | Delete `gtnh-updater-config.json`, `cache/`, `logs/`, and `.temp/`. |
| Wrong profile loaded | Select the correct profile at startup, or switch via Settings > Profiles. |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for project structure and development details.

## License

MIT License. See [LICENSE](LICENSE) for details.

Not affiliated with the GTNH team.
