# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added

- Initial `bsmanager-frame.sh` helper for Steam Frame ARM64 / SteamOS.
- Interactive menu and CLI commands: `install`, `update`, `setup`, `proton`,
  `shortcuts`, `diagnose`, `backup`, `self-update`, `uninstall`.
- Global flags: `--yes`, `--non-interactive`, `--dry-run`, `--verbose`, `--force`.
- Pipe-safe prompts via `/dev/tty` (curl/wget `| bash` friendly).
- Steam Frame / SteamOS / ARM64 detection with `--force` override.
- Steam root and multi-library discovery via `libraryfolders.vdf`.
- Steam AppID manifest parsing and Proton validation
  (`proton` + `files/bin-arm64/wine`).
- Configurable Proton / Steam Runtime AppIDs with Steam install URI requests.
- Native ARM64 BSManager install/update under `~/.local/opt/bs-manager` with
  atomic replacement, rollback, and Flatpak ARM64 fallback (opt-in).
- Custom BSManager sources via `--bsmanager-url` / `--bsmanager-dir`.
- Safe Proton path configuration for `proton-folder` and optional
  `prefix-proton-folder` when BSManager `config.json` is present.
- Beat Saber instance discovery, launch wrappers, and KDE/desktop entries.
- Steam shortcut repair via live CEF/CDP feature detection (no VDF writes
  while Steam is running).
- Diagnostics report, configuration backups, self-update, and scoped uninstall.
- GitHub Actions CI with `bash -n` and ShellCheck.
