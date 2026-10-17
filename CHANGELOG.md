# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

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
