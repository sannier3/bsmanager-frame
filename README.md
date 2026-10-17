# BSManager Frame

Unofficial helper to **install and manage BSManager** and the **Beat Saber versions** it installs, on **Valve Steam Frame** (**ARM64 / aarch64**, **SteamOS**).

This is **not** an official BSManager, Beat Games, or Valve project. It does not replace BSManager. It prepares the Steam Frame environment (Proton, native BSManager, launchers) and keeps the pieces pointed at each other.

Three repositories stay separate:

| Role | Repository |
|------|------------|
| BSManager application source | [Zagrios/bs-manager](https://github.com/Zagrios/bs-manager) |
| Steam Frame native builds | [sannier3/bs-manager](https://github.com/sannier3/bs-manager), branch `steam-frame-build` |
| Installer / helper (this project) | [sannier3/bsmanager-frame](https://github.com/sannier3/bsmanager-frame) |

`sannier3/bs-manager` is a fork of upstream BSManager. Upstream changes are merged by hand and the branch is **not fully synchronized** yet; that synchronization will be automated. The Steam Frame work on `steam-frame-build` includes the separate modding Proton path ([PR #1136](https://github.com/Zagrios/bs-manager/pull/1136)). That branch builds a native ARM64 application and publishes it as a GitHub Release this script can install. The binaries are **not** stored in `bsmanager-frame`.

## Disclaimer

This project is **unofficial** and is **not affiliated with or endorsed by**:

- Valve
- Steam
- Beat Games
- Meta
- BSManager / Zagrios

The Steam Frame builds are unofficial native builds from the fork above, with recorded source commit and checksums. They are not “official BSManager releases”.

Steam Frame, Steam, SteamOS, Beat Saber, and related marks belong to their respective owners.

## Features (v0.2)

- Detect Steam Frame / SteamOS / ARM64
- Locate Steam libraries
- Detect required Proton / Steam Linux Runtime installations
- Request missing tools through Steam (`steam://install/<appid>`)
- Install / update the native ARM64 Steam Frame BSManager build
- Optional Flatpak path, experimental and not validated (`--allow-flatpak` only)
- Configure Proton paths, creating `config.json` when BSManager has not launched yet
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
bsmanager-frame update --allow-flatpak   # experimental, not a Frame-compatible alternative
```

## Native Steam Frame builds vs Flatpak

**Native ARM64** under `~/.local/opt/bs-manager` is the normal Steam Frame path.

`bsmanager-frame install` / `update` download the newest valid `steam-frame-*` Release from [sannier3/bs-manager](https://github.com/sannier3/bs-manager). A Release is used only when it is not a draft and contains all three assets:

```text
BSManager-SteamFrame-linux-arm64.tar.gz
SHA256SUMS
build-info.json
```

Before anything is replaced, the helper checks, in order:

```text
GitHub Release filtering
→ build-info.json provenance
→ SHA256 of the archive
→ archive paths and link targets stay inside bs-manager/
→ ELF ARM64 executable + resources/app.asar
→ atomic install into ~/.local/opt/bs-manager
```

`build-info.json` must name this fork, the `steam-frame-build` branch, architecture `aarch64` or `arm64`, and the expected archive. The installed copy is recorded in:

```text
~/.local/opt/bs-manager/.bsmanager-frame-build.json
```

Updates compare **source commit**, not only the BSManager version string. A newer Steam Frame commit can still report application version `1.6.0`.

These builds stay unofficial until upstream ships the Steam Frame fix and a native ARM64 package of its own. The helper does **not** fall back to official `Zagrios/bs-manager` release archives.

Flatpak is **not** used automatically, and it is **not** a Frame-compatible alternative:

- The current official Flatpak is **v1.6.0**, which predates the Steam Frame fixes this helper depends on, including [PR #1136](https://github.com/Zagrios/bs-manager/pull/1136)
- `--allow-flatpak` remains an explicit opt-in for an **unvalidated / experimental** package
- Updates never convert `native → Flatpak` or `Flatpak → native`
- If no valid Steam Frame Release exists, an existing native install is **kept unchanged**
- Running native **and** Flatpak together may create **duplicate BSManager entries** in the SteamVR application picker

Developer overrides still take precedence over the Steam Frame Release:

```bash
bsmanager-frame install --bsmanager-url 'https://example.invalid/bs-manager-linux-arm64.tar.gz'
bsmanager-frame install --bsmanager-dir /path/to/unpacked/bs-manager
```

Environment alternative: `BSMANAGER_ASSET_URL`. Advanced repository override: `BSMF_BSMANAGER_RELEASE_REPO`.

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

If one of those components is missing, `bsmanager-frame` sends a normal Steam install request:

```bash
steam "steam://install/<appid>"
```

Steam shows its usual confirmation **inside the Steam Frame headset**. No Steam Desktop window is required, and Steam is not restarted. After you accept, the helper watches `appmanifest_<appid>.acf` in the Steam libraries it already discovered, prints download progress, checks the real files (`proton` and `files/bin-arm64/wine` for Proton), then continues on its own. Steam stays responsible for the download.

The three components are requested one at a time. If installing Proton also installs the ARM64 runtime, the later check sees that and does not open another headset popup.

`--dry-run` only reports the request. `--yes` lets the helper send the URI without an extra shell prompt; it does not skip the headset confirmation or the file check.

On a first install, if `~/.config/bs-manager/config.json` does not exist yet, the helper creates it and writes the Proton folders it just installed. You do not need to launch BSManager once before that.

## Safety model

- No `sudo` required
- No SteamOS root filesystem modifications
- No redistribution of Beat Saber
- No redistribution of mods
- No automatic Steam shutdown / restart
- Backups before configuration / shortcut changes
- Prefer GitHub Steam Frame Releases and Steam for the normal path
- No direct `shortcuts.vdf` write while Steam is running
- BSManager user data is preserved during application updates
- Default Steam Frame builds are checksum-verified; `--force` does not skip that check

## Advanced / development builds

Custom native ARM64 trees or URLs bypass the Steam Frame Release contract (no `build-info.json` required) but still refuse a non-ARM64 executable:

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
