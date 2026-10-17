# BSManager Frame

Unofficial helper for setting up and maintaining **BSManager** and **modded Beat Saber** on **Valve Steam Frame** (**ARM64 / aarch64**, **SteamOS**).

It focuses on the validated Steam Frame stack: **Proton 11.0 (ARM64)** for Beat Saber, **Proton Experimental (ARM64)** for BSIPA / modding operations, and a native ARM64 BSManager install when available.

## Disclaimer

This project is **unofficial** and is **not affiliated with or endorsed by**:

- Valve
- Steam
- Beat Games
- Meta
- BSManager / Zagrios

Steam Frame, Steam, SteamOS, Beat Saber, and related marks belong to their respective owners.

## Features (v0.1)

- Detect Steam Frame / SteamOS / ARM64
- Locate Steam libraries
- Detect required Proton / Steam Linux Runtime installations
- Request missing tools through Steam (`steam://install/<appid>`)
- Install / update native ARM64 BSManager builds
- Optional Flatpak fallback available only with explicit opt-in (`--allow-flatpak`)
- Configure Proton paths when BSManager config format is verified
- Create launch wrappers for modded Beat Saber instances
- Create / repair desktop shortcuts
- Create / repair Steam shortcuts when a safe live API is available
- Diagnostics report suitable for GitHub issues
- Configuration backups
- Self-update
- Uninstall (tool-scoped by default)
- Non-interactive mode
- Dry-run mode

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/sannier3/bsmanager-frame/main/bsmanager-frame.sh | bash
```

or:

```bash
wget -qO- https://raw.githubusercontent.com/sannier3/bsmanager-frame/main/bsmanager-frame.sh | bash
```

### Safer inspect-first method

```bash
curl -fsSLo bsmanager-frame.sh \
  https://raw.githubusercontent.com/sannier3/bsmanager-frame/main/bsmanager-frame.sh

less bsmanager-frame.sh
bash bsmanager-frame.sh
```

The script installs itself to `~/.local/bin/bsmanager-frame` when possible so later runs are simply:

```bash
bsmanager-frame
```

Ensure `~/.local/bin` is on your `PATH`.

## Installed usage

```bash
bsmanager-frame
bsmanager-frame install
bsmanager-frame update
bsmanager-frame setup
bsmanager-frame proton
bsmanager-frame shortcuts
bsmanager-frame diagnose
bsmanager-frame backup
bsmanager-frame self-update
bsmanager-frame uninstall
```

Common flags:

```bash
bsmanager-frame --help
bsmanager-frame --version
bsmanager-frame --dry-run diagnose
bsmanager-frame --non-interactive --yes install
bsmanager-frame shortcuts --version 1.40.8
bsmanager-frame update --allow-flatpak   # advanced Flatpak only
```

## Native vs Flatpak

**Native ARM64** under `~/.local/opt/bs-manager` is the recommended Steam Frame path.

Flatpak is **not** used automatically:

- Updates never convert `native → Flatpak` or `Flatpak → native`
- If a native install exists and upstream has no native ARM64 artifact, the native install is **kept unchanged**
- Flatpak is only available with explicit `--allow-flatpak` (or `BSMF_ALLOW_FLATPAK=1`)
- Running native **and** Flatpak together may create **duplicate BSManager entries** in the SteamVR application picker

**Current upstream status:** BSManager release **v1.6.0** provides an aarch64 Flatpak bundle, but not an equivalent native ARM64 archive suitable for this project's preferred install path. That may change in future upstream releases — the script always prefers a native ARM64 asset when one exists.

Until upstream publishes a native ARM64 build containing [PR #1136](https://github.com/Zagrios/bs-manager/pull/1136) (separate modding Proton), prefer testing with:

```bash
bsmanager-frame install --bsmanager-url 'https://example.invalid/bs-manager-linux-arm64.tar.gz'
bsmanager-frame install --bsmanager-dir /path/to/unpacked/bs-manager
```

## Filesystem layout

```text
BSManager application:
~/.local/opt/bs-manager

BSManager command:
~/.local/bin/bs-manager

BSManager data:
~/.local/share/BSManager

BSManager Frame command:
~/.local/bin/bsmanager-frame

BSManager Frame state:
~/.local/share/bsmanager-frame

BSManager Frame logs:
${XDG_STATE_HOME:-~/.local/state}/bsmanager-frame

Desktop entries:
~/.local/share/applications
```

## Proton architecture

Validated Steam Frame configuration:

```text
Beat Saber
    ↓
Proton 11.0 (ARM64)

BSIPA / IPA.exe / prefix operations
    ↓
Proton Experimental (ARM64)
```

Why two Proton installs?

- **Proton 11 ARM64** works for launching Beat Saber on Steam Frame.
- **Proton Experimental ARM64** is required for the currently validated BSIPA workflow.
- BSManager [PR #1136](https://github.com/Zagrios/bs-manager/pull/1136) adds the optional separate Proton for modding operations (`prefix-proton-folder`).

Future Proton versions may behave differently. AppIDs are treated as currently verified defaults and can be overridden if Valve changes them:

| Role | Default AppID | Env override |
|------|---------------|--------------|
| Proton 11.0 (ARM64) | `4628740` | `BSMF_PROTON_STABLE_APPID` |
| Proton Experimental (ARM64) | `4427310` | `BSMF_PROTON_EXPERIMENTAL_APPID` |
| Steam Linux Runtime 4.0 ARM64 | `4185400` | `BSMF_STEAM_RUNTIME_ARM64_APPID` |

Manifest `installdir` values are always taken from Steam app manifests — directory names are never hard-coded as install paths.

## Safety model

- No `sudo` required
- No SteamOS root filesystem modifications
- No redistribution of Beat Saber
- No redistribution of mods
- No automatic Steam shutdown / restart
- Backups before configuration / shortcut changes
- Prefer official GitHub / Steam sources
- No direct `shortcuts.vdf` write while Steam is running
- BSManager user data is preserved during application updates

## Advanced / development builds

While upstream PR #1136 (separate modding Proton) is pending or for CI artifacts:

```bash
bsmanager-frame install --bsmanager-url 'https://example.invalid/bs-manager-linux-arm64.tar.gz'
bsmanager-frame install --bsmanager-dir /path/to/unpacked/bs-manager
```

Environment alternative: `BSMANAGER_ASSET_URL`.

## Troubleshooting

1. Run diagnostics and save a report:

```bash
bsmanager-frame diagnose > report.txt
```

2. Check logs under:

```text
${XDG_STATE_HOME:-~/.local/state}/bsmanager-frame/bsmanager-frame.log
```

3. Open a GitHub issue with the report (omit tokens / account secrets).

Useful overrides:

```bash
BSMF_STEAM_INSTALL_TIMEOUT=1800
BSMF_PROTON_STABLE_APPID=4628740
GITHUB_TOKEN=...   # optional, never printed
```

## License

GNU General Public License v3.0 — see [`LICENSE`](LICENSE).

Copyright (C) 2026 sannier3
