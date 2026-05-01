# GTNH Updater

**Version 1.1.0-beta**

Automates updating [GregTech: New Horizons](https://www.gtnewhorizons.com/) server and client instances on Windows. Interactive and menu-driven. Works with any server setup and any launcher that uses a standard `.minecraft` folder structure (Prism Launcher, MultiMC, PolyMC, ATLauncher, etc.). Auto-detection is included for AMP (CubeCoders) and common launcher directories, but any instance path can be entered manually.

> **Beta**: This tool has been reviewed and tested for correctness but has not yet been validated at scale with real GTNH instances. Please back up your instance before using it. Report issues on GitHub.

## Requirements

- **Windows 10 or 11**
- **PowerShell 7** - The launcher will offer to install it for you if it's not found. Or [download it manually](https://github.com/PowerShell/PowerShell/releases).
- **Java 21+** - Only needed if you use the Daily or Experimental update channels. [Download here](https://adoptium.net/temurin/releases/).

## Getting Started

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

## How It Works

### Stable Updates

When you select **Update GTNH** with the Stable channel:

1. Shows a **version picker** listing all available releases (stable and beta/RC), newest first
2. Asks which target (Server, Client, or Both)
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
9. Lets you choose: **Apply**, **Open staging folder in Explorer**, or **Cancel**
10. If you apply: saves a rollback snapshot, preserves your files, replaces the pack, restores your files, applies config patches, and verifies the result

You always see what will happen before anything is changed.

### Daily / Experimental Updates

When you select Daily or Experimental:

1. Asks which target (Server, Client, or Both)
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
| Daily        | Dev builds from GitHub. Updated daily. Requires Java 21+. |
| Experimental | Bleeding-edge builds from GitHub. May be unstable. Requires Java 21+. |

GTNH's release cycle is: Daily -> Experimental -> Beta -> Stable. When you pick "Update GTNH" on the Stable channel, the version picker shows both stable and beta/RC releases from the [version history page](https://www.gtnewhorizons.com/version-history). No channel switching needed to install a beta.

Daily and Experimental channels use the official [gtnh-nightly-updater](https://github.com/GTNewHorizons/gtnh-nightly-updater) JAR, which downloads individual mods from the GTNH Maven. No Java 21+ is needed for stable updates.

## Features

### Config Patches

Settings you always change after an update (like disabling pollution) can be saved as patches. They get applied automatically after every update. You can:
- **Browse** config files interactively and pick keys to preserve or change
- **Add manually** by entering file path, key, and value (with examples and validation)
- Pick from **common patches** (pollution, render distance, command blocks, etc.)
- **Export/import** patches to share with friends
- **Test** patches without applying them

Supports Forge `.cfg` files, `.properties` files, and `server.properties`. Section-aware matching handles duplicate keys in different config sections.

### Custom Mods

Mods you have added that are not part of the GTNH pack are preserved during updates. You can manage them in several ways:
- **Scan** against the official mod list to automatically find custom mods (compares your mods/ folder against the GitHub mod list for your version)
- **Browse** the mods/ folder and pick from a list (no typing filenames)
- **Add manually** by typing filenames (with validation and examples)

During stable updates, unknown mods are detected automatically and you can mark them as custom in the preview. For daily/experimental updates, only mods saved in your custom mods list are preserved (there is no preview step), so make sure to add your custom mods in Settings before running a daily update.

If a saved custom mod file is not found (for example, you updated it and the filename changed), the tool will ask you to remove it or pick the replacement.

### Download Integrity

Downloaded pack zips are verified with SHA256 checksums when available. Corrupted downloads are caught before they can damage your instance, and bad cached files are automatically removed.

### Automatic Rollback

Before applying an update, the tool saves a snapshot of everything it's about to change. If the update fails mid-way, it offers one-click rollback to restore your instance. Works for both stable and daily updates. If the script detects leftover rollback snapshots on startup (from an interrupted update), it will notify you.

### Config Export/Import

Moving to a new machine? Export your full configuration (paths, custom mods, patches) to a file and import it on the new machine.

### GTNH Changelog Viewer

View the changelog for any recent GTNH release directly from the main menu. Fetches release notes from GitHub so you can see what changed before deciding to update.

### Update History

View a log of all past updates with dates, versions, channels, and targets from the main menu.

### Version Auto-Detection

The updater automatically detects your installed GTNH version from changelog files in your instance folder (e.g., "changelog from 2.7.3 to 2.7.4.txt"). Server and client versions are detected independently. This runs during the setup wizard and on every startup if the version is unknown.

### Self-Update

The updater checks for new versions of itself on startup. If a newer release is available on GitHub, it offers to download and install the update automatically. After updating, it exits so you can restart with the new version. No manual download needed.

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

- **Instance paths** - Server, client, and Java paths (with examples)
- **Update preferences** - Default channel, Java version for downloads, installed version, auto-update check
- **Custom mods** - Browse mods/ folder to pick (with search), add manually, remove, or clear
- **Config patches** - Browse, add, edit, import/export, test, or clear patches
- **Backups and cache** - Backup settings, manage backups, manage download cache
- **Re-run setup wizard** - Start the guided setup again
- **Export/Import config** - Save or restore your full configuration

## Backups

The script does **not** create persistent backups by default (they can use a lot of disk space). You can enable them in Settings > Backups and Cache.

Before every update, the script saves a **rollback snapshot** automatically. If the update fails mid-way, it offers to restore your instance to its pre-update state. This snapshot is temporary and deleted after a successful update.

For full protection, maintain your own backups:

- **Server**: Use your server management tool or copy the server folder
- **Client**: Export your launcher instance or copy the `.minecraft` folder

## Files Preserved During Updates

### Server
- `journeymap/` - Server JourneyMap data
- `serverutilities/` - Server Utilities config and data
- `ops.json`, `whitelist.json`, `server.properties`
- `banned-ips.json`, `banned-players.json`

### Client
- `journeymap/` - Client JourneyMap waypoints and maps
- `options.txt`, `optionsof.txt`, `servers.dat`
- `resourcepacks/`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "PowerShell 7+ Required" | You used `powershell` instead of `pwsh`. Use the `.bat` launcher or open PowerShell 7 manually. |
| "Java 21 or newer is required" | Only affects Daily/Experimental channels. Update the Java path in Settings. Stable works with any Java. |
| Download fails | Check your internet connection. Previously downloaded files are cached and reused. |
| Update failed after applying | The tool will offer automatic rollback. If that fails, restore from your own backup. |
| Download integrity check failed | The file may be corrupted. Clear the cache in Settings and try again. |
| "Another instance may be running" | A previous run crashed without cleaning up. Choose yes to continue. |
| Config file is broken | Delete `gtnh-updater-config.json` and re-run. The setup wizard will start fresh. |
| Want to reset everything | Delete `gtnh-updater-config.json`, `cache/`, `logs/`, and `.temp/`. |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for project structure and development details.

## License

MIT License. See [LICENSE](LICENSE) for details.

Not affiliated with the GTNH team.
