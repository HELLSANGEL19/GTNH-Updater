# GTNH Updater

**Version 0.3.1-beta**

Automates updating [GregTech: New Horizons](https://www.gtnewhorizons.com/) server and client instances on Windows and Linux. Interactive and menu-driven. Works with any server setup and any launcher that uses a standard `.minecraft` folder structure (Prism Launcher, MultiMC, PolyMC, ATLauncher, etc.).

> **Beta**: Please back up your instance before using. Report issues on GitHub.

## Requirements

- **Windows 10/11 or Linux**
- **PowerShell 7** - The launcher will offer to install it if not found. Or [download manually](https://github.com/PowerShell/PowerShell/releases).
- **No other dependencies** - Everything is handled natively. No Java, Git, or external binaries required.

## Getting Started

### Windows

1. Download or clone this repository
2. Double-click **`Launch-GTNHUpdater.bat`**
3. The setup wizard walks you through everything on first run

To put it on your desktop, right-click `Launch-GTNHUpdater.bat` > Create shortcut > move to desktop.

If the `.bat` file closes instantly, open PowerShell 7 (search "pwsh" in Start) and run:

```powershell
cd "C:\path\to\GTNHUpdater"
.\Update-GTNH.ps1
```

### Linux

1. Download or clone this repository
2. Run:
   ```bash
   chmod +x Launch-GTNHUpdater.sh
   ./Launch-GTNHUpdater.sh
   ```
3. The setup wizard walks you through everything on first run

Or directly: `pwsh -File ./Update-GTNH.ps1`

## How It Works

### Setup Wizard

On first run, the wizard asks:
1. What you manage (server only, client only, or both)
2. Detects Java installations and GTNH instances
3. Sets preferences (channel, pack type)
4. Optionally configures custom mods and config patches
5. Optionally sets up a second profile (e.g. a daily test instance)

If you only manage a server, you'll never be asked about client paths.

### Stable Updates

1. Pick a version from the version picker (stable and beta/RC releases listed)
2. Downloads the pack zip (with progress bar, speed display, and integrity verification)
3. Shows a full color-coded mod comparison before applying anything:
   - Green: new mods | Red: removed mods | Yellow: updated | Cyan: your custom mods
4. Lets you mark removed mods as custom (they'll be preserved in future updates)
5. Choose: **Apply**, **Open staging folder**, or **Cancel**
6. If you apply: rollback snapshot, preserve files, replace pack, restore files, apply patches, verify

You always see what will happen before anything is changed.

### Daily / Experimental Updates

1. Fetches the latest mod manifest from DreamAssemblerXXL
2. Shows an update plan (version change, mod counts, what will happen) and confirms
3. Creates a rollback snapshot
4. On first run from stable: cleanly transitions (wipes mods/config/scripts, preserves custom mods)
5. Downloads only changed mods in parallel from GTNH Maven (with GitHub fallback)
6. Syncs configs, scripts, and resources from the release zip
7. Downloads any missing external mods from the GTNH assets database
8. Restores user files, applies config patches, runs verification

Custom mods, override mods, and user files are preserved automatically. If something goes wrong, the tool offers one-click rollback.

## Update Channels

| Channel      | What it is |
|--------------|------------|
| Stable       | Official releases from gtnewhorizons.com. The version picker also lists beta/RC builds. |
| Daily        | Dev builds from GitHub. Updated daily. |
| Experimental | Bleeding-edge builds from GitHub. May be unstable. |

GTNH's release cycle: Experimental > Daily > Beta > Stable.

## Features

### Config Patches

Settings you always change after an update (like disabling pollution) can be saved as patches. They get applied automatically after every update.

- **Browse** config files interactively and pick keys to change
- **Add manually** or pick from **common patches** (pollution, render distance, etc.)
- **Export/import** patches to share with friends
- **Auto-detection**: During stable updates, the updater detects settings you've changed and saves them as patches automatically

Supports Forge `.cfg`, `.properties`, and `server.properties`. Section-aware matching handles duplicate keys.

### Custom Mods

Mods you've added that aren't part of the GTNH pack are preserved during updates.

- **Scan** against the official mod list to find custom mods automatically
- **Browse** the mods/ folder and pick from a list
- **Validate** to find stale entries and auto-fix them

During stable updates, unknown mods are detected in the preview and you can mark them as custom on the spot.

### Override Mods

If you use your own version of a pack mod (e.g., a custom-compiled GregTech), mark it as an override. The updater won't replace it with the pack version.

### Automatic Rollback

Before applying any update, the tool saves a snapshot. If the update fails mid-way, it offers one-click rollback. Works for both stable and daily updates.

### Post-Update Verification

After every update, the tool checks:
- Critical directories exist (mods/, config/, libraries/)
- Mod count is reasonable (150+ JARs)
- GregTech core mod is present
- No duplicate mods (filename matching, fuzzy matching, and mod ID scanning)
- No corrupted (zero-byte) JARs

### Download Integrity

Pack zips are verified with SHA256 checksums when available. Config packs are validated as real zip files before extraction. Corrupted downloads are caught and removed automatically.

### Multiple Profiles

Manage multiple independent GTNH instances (e.g., a main server and a daily test instance) each with its own paths, channel, custom mods, and patches.

### Other Features

- **Config export/import** for moving to a new machine
- **GTNH changelog viewer** to see what changed before updating
- **Update history** log of all past updates
- **Version auto-detection** from changelog files in your instance
- **Self-update** checks for new updater versions on startup
- **Download cache** so re-running an update doesn't re-download

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

Shows installed versions, latest available version, channel, and counts of custom mods and config patches. Versions are color-coded: green if up to date, yellow if an update is available.

## Files Preserved During Updates

### Server
- `config/JourneyMapServer/` - Server JourneyMap UUID
- `serverutilities/` - Server Utilities config and data
- `opencomputers/` - OpenComputers data
- `ops.json`, `whitelist.json`, `server.properties`
- `banned-ips.json`, `banned-players.json`, `usercache.json`

### Client
- `journeymap/` - Waypoints and maps
- `config/NEI/` - NEI settings, hidden items, bookmarks
- `config/shaders.properties` - Active shader selection
- `config/vendingmachine/` - Vending machine favourites
- `opencomputers/` - OpenComputers data
- `maps/` - Map data
- `options.txt`, `optionsof.txt`, `optionsnf.txt`, `servers.dat`
- `resourcepacks/`

## Backups

The script does **not** create persistent backups by default. You can enable them in Settings > Backups and Cache.

A lightweight **rollback snapshot** is always saved before applying. It's deleted after a successful update.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "PowerShell 7+ Required" | Use the launcher (`.bat`/`.sh`) or run with `pwsh` not `powershell`. |
| Download fails or times out | Check internet. Cached files are reused automatically. |
| Update failed after applying | The tool will offer rollback. If that fails, restore from backup. |
| Integrity check failed | Clear the cache in Settings and try again. |
| Custom mods warning at startup | Go to Settings > Custom Mods > Validate to auto-fix. |
| Duplicate mods detected | Multiple versions of the same mod. Remove the older one(s). |
| Config file is broken | Delete `gtnh-updater-config.json` and re-run. Setup wizard starts fresh. |
| Want to reset everything | Delete `gtnh-updater-config.json`, `cache/`, `logs/`, and `.temp/`. |
| Wrong profile loaded | Switch via Settings > Profiles. |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for project structure and development details.

## License

MIT License. See [LICENSE](LICENSE) for details.

Not affiliated with the GTNH team.
