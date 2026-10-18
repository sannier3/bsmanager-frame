# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-17

### Added

- Default native BSManager source is the unofficial Steam Frame Releases from
  `sannier3/bs-manager` (`steam-frame-*`), not official upstream archives.
- Release selection requires `BSManager-SteamFrame-linux-arm64.tar.gz`,
  `SHA256SUMS`, and `build-info.json`.
- Provenance checks on `build-info.json` (repository, branch, architecture,
  artifact, commit).
- SHA256 verification before extraction, plus archive path checks.
  Symlink and hardlink targets must also stay inside `bs-manager/`.
  ARM64 ELF validation of the full Electron tree.
- Missing Proton 11 ARM64, Proton Experimental ARM64, and Steam Linux
  Runtime ARM64 are requested with `steam://install/<appid>`, then monitored
  from the Steam appmanifest (headset confirmation, download progress,
  `StateFlags` bitmask, then real file checks) before setup continues.
- A missing BSManager `config.json` is created with the installed Proton
  folders. A first launch of BSManager is not required for that.
- Installed build metadata in `~/.local/opt/bs-manager/.bsmanager-frame-build.json`.
- Update detection by source commit, including legacy native installs that
  have no provenance file yet.

### Changed

- Official `Zagrios/bs-manager` native release lookup is no longer the normal
  Steam Frame install/update path, and it is not a silent fallback.
- The launcher menu lists installed versions and leftover launchers. Adding a
  version rewrites its command, desktop entry, and Steam shortcut. Removing a
  launcher leaves the Beat Saber instance, maps, and saves in place.
- Uninstall is split: `bsmanager-frame` removes only the helper. BSManager
  removal asks before deleting `~/.config/bs-manager`. Enter keeps those
  settings. Instances, maps, saves, Proton, and Steam tools are not offered.
- Flatpak remains an explicit opt-in (`--allow-flatpak` / `BSMF_ALLOW_FLATPAK`)
  and is documented as experimental. Official Flatpak v1.6.0 is not a
  Frame-compatible alternative: it predates PR #1136.
- The Steam Frame fork is described as manually merged, not fully
  synchronized with upstream. Synchronization will be automated.
- `--bsmanager-url` and `--bsmanager-dir` remain supported and take precedence.
- `--force` can reinstall the same commit; it does not skip checksum,
  provenance, or architecture checks.
- An existing native install is kept when no valid Steam Frame Release can be
  downloaded.

## [0.1.0] - 2026-10-17

### Added

- Initial `bsmanager-frame.sh` helper for Steam Frame ARM64 / SteamOS.
- Interactive menu and CLI commands: `install`, `update`, `setup`, `proton`,
  `shortcuts`, `diagnose`, `backup`, `self-update`, `uninstall`.
- Global flags: `--yes`, `--non-interactive`, `--dry-run`, `--verbose`, `--force`,
  `--allow-flatpak`, `--lang`.
- Pipe-safe prompts via `/dev/tty` (curl/wget `| bash` friendly).
- Steam Frame / SteamOS / ARM64 detection with `--force` override.
- Steam root and multi-library discovery via `libraryfolders.vdf`.
- Steam AppID manifest parsing and Proton validation
  (`proton` + `files/bin-arm64/wine`).
- Configurable Proton / Steam Runtime AppIDs with Steam install URI requests.
- Native ARM64 BSManager install/update under `~/.local/opt/bs-manager` with
  atomic replacement and rollback.
- Custom BSManager sources via `--bsmanager-url` / `--bsmanager-dir`.
- Safe Proton path configuration for `proton-folder` and optional
  `prefix-proton-folder` when support is detected.
- Beat Saber instance discovery, launch wrappers, and KDE/desktop entries.
- Steam shortcut repair via live CEF/CDP feature detection (no VDF writes
  while Steam is running).
- Diagnostics report, configuration backups, self-update, and scoped uninstall.
- Installation type detection (`native`, `flatpak-user`, `flatpak-system`,
  `native+flatpak`, `none`, `unknown`).
- Feature detection for separate modding Proton (`prefix-proton-folder`).
- GitHub Actions CI with `bash -n`, ShellCheck, and non-destructive smoke tests.

### Changed

- Flatpak is an **explicit advanced opt-in** only (`--allow-flatpak` /
  `BSMF_ALLOW_FLATPAK`); it is no longer offered on the normal update path.
- Native installs are preserved when the latest upstream release has no
  compatible native ARM64 artifact (not treated as an update failure).
- Package format is never changed automatically (`native ↔ Flatpak`).
- Proton setup order: Proton 11 → Proton Experimental → verify/request
  Steam Linux Runtime 4.0 ARM64 afterward.
- Refuse to edit BSManager `config.json` while BSManager is running.
- Only write `prefix-proton-folder` when installed BSManager resources contain
  the feature token (PR #1136); otherwise configure main Proton only.

### Fixed

- Warning when native and Flatpak BSManager coexist (duplicate SteamVR entries).
- Diagnostics cover native/Flatpak scopes, running state, and modding Proton
  support.
