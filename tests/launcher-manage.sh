#!/usr/bin/env bash
# Launcher list/remove and BSManager uninstall. No real Steam client.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
export HOME="$WORKDIR/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$WORKDIR/runtime"
export LC_ALL=C
unset BSMF_LANG || true
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
export BSMF_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/bsmanager-frame.sh"
trap 'rm -rf "$WORKDIR"' EXIT
UI_LANG=en

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'OK %s\n' "$1"; }

instance="$XDG_DATA_HOME/BSManager/BSInstances/1.40.8"
mkdir -p "$instance"
printf 'game\n' >"$instance/Beat Saber.exe"
mkdir -p "$LOCAL_BIN" "$APPLICATIONS_DIR"
printf '#!/bin/sh\n' >"$LOCAL_BIN/beat-saber-1.40.8-modded"
printf '[Desktop Entry]\n' >"$APPLICATIONS_DIR/beat-saber-1.40.8-modded.desktop"
printf '#!/bin/sh\n' >"$LOCAL_BIN/beat-saber-9.9.9-modded"
chmod +x "$LOCAL_BIN/beat-saber-1.40.8-modded" "$LOCAL_BIN/beat-saber-9.9.9-modded" || true

refresh_managed_launchers
[[ "${#BSMF_LAUNCHER_SLUGS[@]}" -eq 2 ]] || fail "expected 2 launchers, got ${#BSMF_LAUNCHER_SLUGS[@]}"
orphan_at=""
live_at=""
i=0
for ((i = 0; i < ${#BSMF_LAUNCHER_SLUGS[@]}; i++)); do
    if [[ "${BSMF_LAUNCHER_SLUGS[$i]}" == "9.9.9" ]]; then
        orphan_at=$i
        [[ "${BSMF_LAUNCHER_ORPHAN[$i]}" -eq 1 ]] || fail "9.9.9 should be orphan"
    fi
    if [[ "${BSMF_LAUNCHER_SLUGS[$i]}" == "1.40.8" ]]; then
        live_at=$i
        [[ "${BSMF_LAUNCHER_ORPHAN[$i]}" -eq 0 ]] || fail "1.40.8 should stay linked to its folder"
        [[ "${BSMF_LAUNCHER_HAS_WRAPPER[$i]}" -eq 1 ]] || fail "wrapper missing in list"
        [[ "${BSMF_LAUNCHER_HAS_DESKTOP[$i]}" -eq 1 ]] || fail "desktop missing in list"
    fi
done
[[ -n "$orphan_at" && -n "$live_at" ]] || fail "list did not contain both launchers"
pass "list versions and orphan launchers"

remove_managed_launcher "9.9.9" "9.9.9"
[[ ! -e "$LOCAL_BIN/beat-saber-9.9.9-modded" ]] || fail "orphan wrapper still present"
[[ -f "$instance/Beat Saber.exe" ]] || fail "instance was removed with the launcher"
[[ -e "$LOCAL_BIN/beat-saber-1.40.8-modded" ]] || fail "other launcher was removed"
pass "delete launcher keeps the instance"

if is_safe_remove_path "$XDG_DATA_HOME/BSManager"; then
    fail "instance data dir must not be a removable path"
fi
pass "instances are not a removable path"

mkdir -p "$BSMANAGER_INSTALL_DIR" "$BSMANAGER_CONFIG_DIR" "$XDG_DATA_HOME/BSManager/BSInstances/1.40.8"
printf 'app\n' >"$BSMANAGER_INSTALL_DIR/bs-manager"
printf '{}\n' >"$BSMANAGER_CONFIG_DIR/config.json"
printf 'save\n' >"$XDG_DATA_HOME/BSManager/BSInstances/1.40.8/Beat Saber.exe"
FLAG_YES=1
FLAG_NON_INTERACTIVE=1
FLAG_REMOVE_DATA=1
cmd_uninstall_bsmanager
[[ ! -e "$BSMANAGER_INSTALL_DIR/bs-manager" ]] || fail "BSManager app still present"
[[ -f "$BSMANAGER_CONFIG_DIR/config.json" ]] || fail "settings were deleted without an explicit yes"
[[ -f "$XDG_DATA_HOME/BSManager/BSInstances/1.40.8/Beat Saber.exe" ]] || fail "instance deleted with BSManager"
pass "uninstall BSManager keeps settings and instances"

printf 'ALL_OK\n'
