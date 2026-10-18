#!/usr/bin/env bash
# BSManager Frame — unofficial Steam Frame ARM64 helper for BSManager / modded Beat Saber
# Copyright (C) 2026 sannier3
# SPDX-License-Identifier: GPL-3.0-only
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

set -Eeuo pipefail

VERSION="0.2.0"
GITHUB_OWNER="sannier3"
GITHUB_REPO="bsmanager-frame"
UPSTREAM_BSMANAGER_REPO="Zagrios/bs-manager"
# Unofficial Steam Frame native builds (not the bsmanager-frame helper repo).
BSMANAGER_FRAME_RELEASE_REPO="${BSMF_BSMANAGER_RELEASE_REPO:-sannier3/bs-manager}"
BSMANAGER_FRAME_RELEASE_TAG_PREFIX="${BSMF_BSMANAGER_RELEASE_TAG_PREFIX:-steam-frame-}"
BSMANAGER_FRAME_SOURCE_BRANCH="${BSMF_BSMANAGER_SOURCE_BRANCH:-steam-frame-build}"
BSMANAGER_FRAME_ARCHIVE="BSManager-SteamFrame-linux-arm64.tar.gz"
BSMANAGER_FRAME_CHECKSUMS="SHA256SUMS"
BSMANAGER_FRAME_BUILD_INFO="build-info.json"
BSMANAGER_PROVENANCE_NAME=".bsmanager-frame-build.json"

USER_AGENT="bsmanager-frame/${VERSION}"

# --- Configurable AppIDs (Valve may change these) ---
PROTON_STABLE_APPID="${BSMF_PROTON_STABLE_APPID:-4628740}"
PROTON_EXPERIMENTAL_APPID="${BSMF_PROTON_EXPERIMENTAL_APPID:-4427310}"
STEAM_RUNTIME_ARM64_APPID="${BSMF_STEAM_RUNTIME_ARM64_APPID:-4185400}"
BEAT_SABER_APPID="620980"

PROTON_STABLE_LABEL="Proton 11.0 (ARM64)"
PROTON_EXPERIMENTAL_LABEL="Proton Experimental (ARM64)"
STEAM_RUNTIME_LABEL="Steam Linux Runtime 4.0 ARM64"

STEAM_INSTALL_TIMEOUT="${BSMF_STEAM_INSTALL_TIMEOUT:-900}"
# Seconds between Steam manifest polls. Override with BSMF_STEAM_POLL_INTERVAL (1–60).
STEAM_POLL_INTERVAL="${BSMF_STEAM_POLL_INTERVAL:-2}"
BACKUP_KEEP_COUNT="${BSMF_BACKUP_KEEP_COUNT:-3}"
CDP_PORT_CANDIDATES="${BSMF_CDP_PORTS:-8080 8081 9222}"
FLATPAK_APP_ID_EXPECTED="io.bsmanager.bsmanager"

# --- XDG-aware paths ---
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

LOCAL_BIN="$HOME/.local/bin"
TOOL_DATA_DIR="$XDG_DATA_HOME/bsmanager-frame"
TOOL_STATE_DIR="$XDG_STATE_HOME/bsmanager-frame"
TOOL_TMP_DIR="$TOOL_DATA_DIR/tmp"
TOOL_LOG_FILE="$TOOL_STATE_DIR/bsmanager-frame.log"
TOOL_ACTION_LOG="$TOOL_STATE_DIR/actions.log"
TOOL_LANG_FILE="$TOOL_DATA_DIR/language"

BSMANAGER_INSTALL_DIR="$HOME/.local/opt/bs-manager"
BSMANAGER_DATA_DIR="$XDG_DATA_HOME/BSManager"
BSMANAGER_CONFIG_DIR="$XDG_CONFIG_HOME/bs-manager"
BSMANAGER_BIN="$LOCAL_BIN/bs-manager"
SELF_INSTALL_PATH="$LOCAL_BIN/bsmanager-frame"
APPLICATIONS_DIR="$XDG_DATA_HOME/applications"

# --- Runtime flags ---
FLAG_YES=0
FLAG_NON_INTERACTIVE=0
FLAG_DRY_RUN=0
FLAG_VERBOSE=0
FLAG_FORCE=0
FLAG_REMOVE_DATA=0
FLAG_ALLOW_FLATPAK=0
if [[ "${BSMF_ALLOW_FLATPAK:-0}" == "1" || "${BSMF_ALLOW_FLATPAK:-}" == "true" ]]; then
    FLAG_ALLOW_FLATPAK=1
fi

OPT_BS_VERSION=""
OPT_COMPATDATA=""
OPT_BSMANAGER_URL="${BSMANAGER_ASSET_URL:-}"
OPT_BSMANAGER_DIR=""

COMMAND=""
COLOR_ENABLED=0
TMP_PATHS=()
CLEANUP_DONE=0
UI_LANG="${BSMF_LANG:-}"
OPT_LANG=""
ALLOW_CONTINUE_ON_ERROR=0
ACTION_DEPTH=0
# Filled by refresh_beat_saber_instances (same shell as the menu — not a pipe).
BSMF_BS_NAMES=()
BSMF_BS_PATHS=()
BSMF_SELECTED_BS_NAME=""
BSMF_SELECTED_BS_DIR=""
BSMF_LAUNCHER_SLUGS=()
BSMF_LAUNCHER_LABELS=()
BSMF_LAUNCHER_DIRS=()
BSMF_LAUNCHER_HAS_WRAPPER=()
BSMF_LAUNCHER_HAS_DESKTOP=()
BSMF_LAUNCHER_ORPHAN=()

# =============================================================================
# Logging
# =============================================================================

_init_color() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        COLOR_ENABLED=0
        return
    fi
    if [[ -t 1 ]]; then
        COLOR_ENABLED=1
    else
        COLOR_ENABLED=0
    fi
}

_c() {
    local code="$1"
    shift
    if [[ "$COLOR_ENABLED" -eq 1 ]]; then
        printf '\033[%sm%s\033[0m' "$code" "$*"
    else
        printf '%s' "$*"
    fi
}

_ensure_log_dir() {
    mkdir -p "$TOOL_STATE_DIR" "$TOOL_DATA_DIR" 2>/dev/null || true
}

_timestamp() {
    date -Iseconds 2>/dev/null || date
}

_log_to_file() {
    local level="$1"
    shift
    _ensure_log_dir
    printf '%s [%s] %s\n' "$(_timestamp)" "$level" "$*" >>"$TOOL_LOG_FILE" 2>/dev/null || true
}

log_action() {
    local status="$1"
    shift
    _ensure_log_dir
    printf '%s [%s] lang=%s cmd=%s %s\n' \
        "$(_timestamp)" "$status" "${UI_LANG:-?}" "${COMMAND:-menu}" "$*" \
        >>"$TOOL_ACTION_LOG" 2>/dev/null || true
    _log_to_file ACTION "[$status] $*"
}

action_begin() {
    local name="$1"
    shift
    ACTION_DEPTH=$((ACTION_DEPTH + 1))
    log_action START "$name $*"
    debug "action begin: $name $*"
}

action_end() {
    local name="$1"
    local rc="${2:-0}"
    shift 2 || true
    if [[ "$ACTION_DEPTH" -gt 0 ]]; then
        ACTION_DEPTH=$((ACTION_DEPTH - 1))
    fi
    if [[ "$rc" -eq 0 ]]; then
        log_action OK "$name $*"
    else
        log_action FAIL "rc=$rc $name $*"
    fi
}

info() {
    _log_to_file INFO "$*"
    # stderr: keep stdout clean for functions that return paths/values via capture
    printf '%s %s\n' "$(_c 34 '[INFO]')" "$*" >&2
}

success() {
    _log_to_file OK "$*"
    printf '%s %s\n' "$(_c 32 '[OK]')" "$*" >&2
}

warn() {
    _log_to_file WARN "$*"
    printf '%s %s\n' "$(_c 33 '[WARN]')" "$*" >&2
}

error() {
    _log_to_file ERROR "$*"
    printf '%s %s\n' "$(_c 31 '[ERROR]')" "$*" >&2
}

debug() {
    _log_to_file DEBUG "$*"
    if [[ "$FLAG_VERBOSE" -eq 1 ]]; then
        printf '%s %s\n' "$(_c 90 '[DEBUG]')" "$*" >&2
    fi
}

die() {
    error "$*"
    log_action FATAL "$*"
    if [[ "$ALLOW_CONTINUE_ON_ERROR" -eq 1 ]]; then
        return 1
    fi
    exit 1
}

# Run a command without aborting the interactive menu on failure.
run_menu_action() {
    local rc=0
    local label="$1"
    shift
    action_begin "$label"
    ALLOW_CONTINUE_ON_ERROR=1
    # set -e is suspended for failing commands inside `||`
    "$@" || rc=$?
    ALLOW_CONTINUE_ON_ERROR=0
    action_end "$label" "$rc"
    if [[ "$rc" -ne 0 ]]; then
        warn "$(t err_action_failed "$label" "$rc")"
        warn "$(t err_see_logs "$TOOL_LOG_FILE" "$TOOL_ACTION_LOG")"
    fi
    return 0
}

# =============================================================================
# Internationalization (fr, en, es, de, sw)
# =============================================================================

is_supported_lang() {
    case "${1:-}" in
        en|fr|es|de|sw) return 0 ;;
        *) return 1 ;;
    esac
}

# Map a locale tag (fr_FR.UTF-8, es-ES, etc.) to a supported UI language code.
locale_to_ui_lang() {
    local tag="${1:-}"
    local code
    tag="${tag//-/_}"
    tag="${tag%%.*}"
    tag="${tag%%@*}"
    code="${tag%%_*}"
    code="${code,,}"
    case "$code" in
        en|fr|es|de|sw) printf '%s\n' "$code" ;;
        *) return 1 ;;
    esac
}

# Prefer LC_ALL → LC_MESSAGES → LANG → LANGUAGE (colon-separated list).
detect_system_lang() {
    local candidate="" part mapped=""
    for candidate in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        [[ -z "$candidate" || "$candidate" == "C" || "$candidate" == "C.UTF-8" || "$candidate" == "POSIX" ]] && continue
        if mapped="$(locale_to_ui_lang "$candidate")"; then
            printf '%s\n' "$mapped"
            return 0
        fi
    done
    if [[ -n "${LANGUAGE:-}" ]]; then
        IFS=':' read -r -a _lang_parts <<<"${LANGUAGE}"
        for part in "${_lang_parts[@]}"; do
            [[ -z "$part" || "$part" == "C" || "$part" == "POSIX" ]] && continue
            if mapped="$(locale_to_ui_lang "$part")"; then
                printf '%s\n' "$mapped"
                return 0
            fi
        done
    fi
    printf 'en\n'
}

lang_menu_number() {
    case "${1:-en}" in
        en) printf '1\n' ;;
        fr) printf '2\n' ;;
        es) printf '3\n' ;;
        de) printf '4\n' ;;
        sw) printf '5\n' ;;
        *) printf '1\n' ;;
    esac
}

# Message catalog: English is the fallback for every key.
_t_en() {
    case "$1" in
        lang_prompt_title) printf '%s' "Select language / Choisir la langue / Elegir idioma / Sprache wählen / Chagua lugha" ;;
        lang_system_detected) printf '%s' "System language detected: %s (pre-selected)" ;;
        lang_opt_en) printf '%s' "English" ;;
        lang_opt_fr) printf '%s' "Français" ;;
        lang_opt_es) printf '%s' "Español" ;;
        lang_opt_de) printf '%s' "Deutsch" ;;
        lang_opt_sw) printf '%s' "Kiswahili" ;;
        lang_invalid) printf '%s' "Invalid language selection." ;;
        lang_saved) printf '%s' "Language saved: %s" ;;
        lang_using) printf '%s' "Using language: %s" ;;
        ask_self_desktop) printf '%s' "Create a KDE/desktop shortcut for BSManager Frame Script?" ;;
        ok_self_desktop) printf '%s' "Desktop shortcut created: %s" ;;
        skip_self_desktop) printf '%s' "Desktop shortcut skipped" ;;
        menu_banner) printf '%s' "BSManager Frame v%s" ;;
        menu_1) printf '%s' "Install / repair" ;;
        menu_2) printf '%s' "Update BSManager" ;;
        menu_3) printf '%s' "Configure Proton" ;;
        menu_4) printf '%s' "Manage Beat Saber launchers" ;;
        menu_5) printf '%s' "Create / repair shortcuts" ;;
        menu_uninstall_frame) printf '%s' "Uninstall bsmanager-frame" ;;
        menu_uninstall_bsmanager) printf '%s' "Uninstall BSManager" ;;
        menu_6) printf '%s' "Diagnose" ;;
        menu_7) printf '%s' "Backup configuration" ;;
        menu_8) printf '%s' "Update bsmanager-frame" ;;
        menu_9) printf '%s' "Uninstall" ;;
        menu_0) printf '%s' "Quit" ;;
        menu_10) printf '%s' "Change language" ;;
        menu_select) printf '%s' "Select" ;;
        menu_invalid) printf '%s' "Invalid choice" ;;
        menu_needs_tty) printf '%s' "Interactive menu requires /dev/tty. Pass a command or --non-interactive." ;;
        bs_versions_detected) printf '%s' "Detected Beat Saber versions:" ;;
        bs_versions_none) printf '%s' "No Beat Saber instances detected under BSInstances" ;;
        bs_version_prompt) printf '%s' "Select Beat Saber version" ;;
        bs_version_pick_number) printf '%s' "Enter number" ;;
        bs_version_using) printf '%s' "Using Beat Saber %s" ;;
        bs_version_none_die) printf '%s' "No Beat Saber instances found under %s" ;;
        launcher_ready) printf '%s' "Launcher ready: %s" ;;
        launcher_hint_menu5) printf '%s' "The shortcuts command adds the desktop entry and tries to repair the Steam shortcut." ;;
        launcher_title) printf '%s' "Beat Saber launchers" ;;
        launcher_add) printf '%s' "Add or repair a version" ;;
        launcher_delete) printf '%s' "Delete a launcher" ;;
        launcher_back) printf '%s' "Back" ;;
        launcher_line) printf '%s' "%s — command %s, desktop %s%s" ;;
        launcher_present) printf '%s' "present" ;;
        launcher_absent) printf '%s' "absent" ;;
        launcher_orphan) printf '%s' ", folder missing" ;;
        launcher_none_delete) printf '%s' "There is no launcher to delete." ;;
        launcher_confirm_delete) printf '%s' "Delete the launcher for %s? The Beat Saber instance, maps, and saves are kept." ;;
        launcher_deleted) printf '%s' "Launcher removed: %s" ;;
        launcher_instance_kept) printf '%s' "Beat Saber files were kept." ;;
        launcher_steam_removed) printf '%s' "Steam shortcut removed." ;;
        launcher_steam_left) printf '%s' "Steam shortcut was left in place." ;;
        launcher_added) printf '%s' "Launcher ready for %s" ;;
        launcher_pick) printf '%s' "Select a launcher" ;;
        uninstall_frame_about) printf '%s' "This removes bsmanager-frame only. BSManager, launchers, instances, maps, and saves stay." ;;
        ask_remove_frame) printf '%s' "Remove bsmanager-frame?" ;;
        uninstall_bsm_about) printf '%s' "This removes the BSManager application. Instances, maps, and saves stay." ;;
        uninstall_bsm_missing) printf '%s' "BSManager is not installed." ;;
        ask_remove_bsm_app) printf '%s' "Remove the BSManager application?" ;;
        ask_remove_bsm_config) printf '%s' "Delete BSManager settings (%s)? Instances, maps, and saves are not included." ;;
        bsm_config_kept) printf '%s' "BSManager settings kept." ;;
        bsm_config_removed) printf '%s' "BSManager settings removed." ;;
        bsm_app_removed) printf '%s' "BSManager application removed." ;;
        bsm_flatpak_left) printf '%s' "Flatpak BSManager is still installed." ;;
        bsm_running_uninstall) printf '%s' "BSManager is running. Close it before uninstalling it." ;;
        compat_missing) printf '%s' "No Proton prefix (compatdata folder with pfx/) under %s" ;;
        confirm_yn) printf '%s' "%s [y/N]" ;;
        prompt_no_tty) printf '%s' "No /dev/tty available for interactive prompt. Re-run with --non-interactive and required options, or from a terminal." ;;
        prompt_need_value) printf '%s' "Non-interactive mode requires an explicit value for: %s" ;;
        err_action_failed) printf '%s' "Action failed: %s (exit %s). Returning to menu." ;;
        err_see_logs) printf '%s' "Details: %s | actions: %s" ;;
        err_interrupted) printf '%s' "Interrupted. Steam was left running. Temporary helper files cleaned." ;;
        pipe_installing) printf '%s' "Running without TTY — installing bsmanager-frame itself." ;;
        pipe_installed) printf '%s' "Installed. Open a terminal and run: bsmanager-frame" ;;
        ok_steam_frame) printf '%s' "Steam Frame detected" ;;
        ok_steam_likely) printf '%s' "SteamOS ARM64 likely Steam Frame" ;;
        warn_unknown_platform) printf '%s' "Unsupported / unknown system (arch=%s)" ;;
        ask_continue_platform) printf '%s' "Continue anyway on this unsupported/unknown system?" ;;
        aborted) printf '%s' "Aborted" ;;
        continue_force) printf '%s' "Continuing due to --force" ;;
        diag_complete) printf '%s' "Diagnostics complete" ;;
        backup_written) printf '%s' "Backup written to %s" ;;
        self_installed) printf '%s' "Installed %s" ;;
        self_updated) printf '%s' "bsmanager-frame updated at %s" ;;
        uninstall_done) printf '%s' "bsmanager-frame uninstall complete" ;;
        ask_remove_wrappers) printf '%s' "Remove generated Beat Saber wrappers?" ;;
        ask_remove_desktop) printf '%s' "Remove generated desktop entries?" ;;
        ask_remove_bsmanager) printf '%s' "Remove native BSManager application (~/.local/opt/bs-manager)?" ;;
        ask_shortcuts_now) printf '%s' "Create/repair launchers and shortcuts now?" ;;
        ask_steam_install) printf '%s' "Request Steam to install %s now?" ;;
        steam_not_installed) printf '%s' "%s is not installed." ;;
        steam_already) printf '%s' "%s is already installed" ;;
        steam_requesting) printf '%s' "Requesting installation through Steam..." ;;
        steam_request_sent) printf '%s' "Installation request sent to Steam." ;;
        steam_confirm_headset) printf '%s' "Confirm the installation inside the Steam Frame headset. Waiting for Steam to start the installation..." ;;
        steam_waiting_headset) printf '%s' "Waiting for confirmation in headset... %ss" ;;
        steam_install_detected) printf '%s' "Steam installation detected." ;;
        steam_downloading) printf '%s' "Downloading %s: %s / %s (%s%%)" ;;
        steam_in_progress) printf '%s' "Steam installation in progress..." ;;
        steam_reports_complete) printf '%s' "Steam reports installation complete." ;;
        steam_validating) printf '%s' "Validating %s..." ;;
        steam_timeout) printf '%s' "Steam installation did not complete before timeout. The current system state was left unchanged." ;;
        steam_files_missing) printf '%s' "Steam reports installed, but required files are missing for %s." ;;
        steam_ok_file) printf '%s' "%s" ;;
        steam_left_running) printf '%s' "Steam was left running." ;;
        bsm_config_seeded) printf '%s' "Created BSManager configuration and set the installed Proton folders: %s" ;;
        ask_flatpak) printf '%s' "Install experimental Flatpak (%s)? Not validated on Steam Frame (v1.6.0 predates PR #1136)." ;;
        bsm_native_preserved) printf '%s' "Current native ARM64 BSManager installation preserved" ;;
        bsm_no_native_asset) printf '%s' "No valid Steam Frame native BSManager release is currently available." ;;
        bsm_latest_release) printf '%s' "Latest Steam Frame native build: %s" ;;
        bsm_kept_unchanged) printf '%s' "Current native BSManager installation kept unchanged." ;;
        bsm_no_native_fresh) printf '%s' "No valid native Steam Frame BSManager release is currently available." ;;
        bsm_use_custom) printf '%s' "Use a custom native ARM64 build with --bsmanager-url URL or --bsmanager-dir PATH" ;;
        bsm_sf_repo) printf '%s' "Steam Frame release repository: %s" ;;
        bsm_sf_query_failed) printf '%s' "Could not determine the latest Steam Frame BSManager release (%s)." ;;
        bsm_sf_uptodate) printf '%s' "BSManager Steam Frame native build is already up to date" ;;
        bsm_sf_installed) printf '%s' "Installed: release %s, commit %s" ;;
        bsm_sf_available) printf '%s' "Available: release %s, commit %s" ;;
        bsm_sf_legacy) printf '%s' "Native ARM64 installation: present. Build provenance: unknown / legacy installation" ;;
        bsm_sf_update_available) printf '%s' "Update available" ;;
        bsm_sf_confirm) printf '%s' "Replace the installed BSManager with Steam Frame build %s?" ;;
        bsm_sf_downloading) printf '%s' "Downloading Steam Frame native BSManager %s" ;;
        bsm_sf_need_yes) printf '%s' "Re-run with --yes to install this Steam Frame build in non-interactive mode." ;;
        bsm_sf_bad_build_info) printf '%s' "Steam Frame build-info.json rejected: %s" ;;
        bsm_sf_bad_checksum) printf '%s' "SHA256 verification failed for %s" ;;
        bsm_sf_bad_archive) printf '%s' "Steam Frame archive rejected: %s" ;;
        bsm_sf_source_release) printf '%s' "Source: Steam Frame Release" ;;
        bsm_sf_source_url) printf '%s' "Source: custom URL" ;;
        bsm_sf_source_dir) printf '%s' "Source: local directory" ;;
        diag_sf_heading) printf '%s' "Installed Steam Frame build" ;;
        diag_sf_latest) printf '%s' "Latest Steam Frame release" ;;
        diag_sf_unavailable) printf '%s' "unavailable (%s)" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak is experimental and not validated on Steam Frame. Official v1.6.0 Flatpak predates the Steam Frame fixes (including PR #1136) and is not a compatible alternative. Use only with --allow-flatpak." ;;
        bsm_dup_warn) printf '%s' "Native and Flatpak BSManager installations coexist. This may create duplicate BSManager desktop / SteamVR application entries." ;;
        bsm_prefix_unsupported) printf '%s' "Installed BSManager does not support a separate Proton for modding operations. Use a BSManager build containing PR #1136." ;;
        bsm_prefix_unknown) printf '%s' "Could not determine whether this BSManager build supports prefix-proton-folder; not writing that key." ;;
        bsm_running_config) printf '%s' "BSManager is currently running. Close BSManager before changing its configuration." ;;
        bsm_launch_once) printf '%s' "Launch BSManager once, then rerun: bsmanager-frame proton" ;;
        bsm_flatpak_need_flag) printf '%s' "Flatpak operations require --allow-flatpak (disabled by default)." ;;
        bsm_flatpak_system_exists) printf '%s' "System Flatpak BSManager already installed; refusing to add a second user Flatpak copy." ;;
        bsm_flatpak_update_hint) printf '%s' "Flatpak BSManager is installed. Re-run with --allow-flatpak to manage Flatpak updates." ;;
        unknown_command) printf '%s' "Unknown command: %s" ;;
        unknown_option) printf '%s' "Unknown option: %s" ;;
        *) printf '%s' "$1" ;;
    esac
}

_t_fr() {
    case "$1" in
        lang_system_detected) printf '%s' "Langue système détectée : %s (présélectionnée)" ;;
        lang_saved) printf '%s' "Langue enregistrée : %s" ;;
        lang_using) printf '%s' "Langue utilisée : %s" ;;
        lang_invalid) printf '%s' "Sélection de langue invalide." ;;
        ask_self_desktop) printf '%s' "Créer un raccourci KDE/bureau pour BSManager Frame Script ?" ;;
        ok_self_desktop) printf '%s' "Raccourci bureau créé : %s" ;;
        skip_self_desktop) printf '%s' "Raccourci bureau ignoré" ;;
        menu_1) printf '%s' "Installer / réparer" ;;
        menu_2) printf '%s' "Mettre à jour BSManager" ;;
        menu_3) printf '%s' "Configurer Proton" ;;
        menu_4) printf '%s' "Gérer les lanceurs Beat Saber" ;;
        menu_5) printf '%s' "Créer / réparer les raccourcis" ;;
        menu_uninstall_frame) printf '%s' "Désinstaller bsmanager-frame" ;;
        menu_uninstall_bsmanager) printf '%s' "Désinstaller BSManager" ;;
        menu_6) printf '%s' "Diagnostiquer" ;;
        menu_7) printf '%s' "Sauvegarder la configuration" ;;
        menu_8) printf '%s' "Mettre à jour bsmanager-frame" ;;
        menu_9) printf '%s' "Désinstaller" ;;
        menu_0) printf '%s' "Quitter" ;;
        menu_10) printf '%s' "Changer de langue" ;;
        menu_select) printf '%s' "Choix" ;;
        menu_invalid) printf '%s' "Choix invalide" ;;
        menu_needs_tty) printf '%s' "Le menu interactif nécessite /dev/tty. Passez une commande ou --non-interactive." ;;
        bs_versions_detected) printf '%s' "Versions Beat Saber détectées :" ;;
        bs_versions_none) printf '%s' "Aucune instance Beat Saber détectée sous BSInstances" ;;
        bs_version_prompt) printf '%s' "Choisir une version Beat Saber" ;;
        bs_version_pick_number) printf '%s' "Numéro" ;;
        bs_version_using) printf '%s' "Version Beat Saber utilisée : %s" ;;
        bs_version_none_die) printf '%s' "Aucune instance Beat Saber trouvée sous %s" ;;
        launcher_ready) printf '%s' "Lanceur prêt : %s" ;;
        launcher_hint_menu5) printf '%s' "La commande shortcuts ajoute l'entrée bureau et tente de réparer le raccourci Steam." ;;
        launcher_title) printf '%s' "Lanceurs Beat Saber" ;;
        launcher_add) printf '%s' "Ajouter ou réparer une version" ;;
        launcher_delete) printf '%s' "Supprimer un lanceur" ;;
        launcher_back) printf '%s' "Retour" ;;
        launcher_line) printf '%s' "%s — commande %s, bureau %s%s" ;;
        launcher_present) printf '%s' "présent" ;;
        launcher_absent) printf '%s' "absent" ;;
        launcher_orphan) printf '%s' ", dossier manquant" ;;
        launcher_none_delete) printf '%s' "Aucun lanceur à supprimer." ;;
        launcher_confirm_delete) printf '%s' "Supprimer le lanceur pour %s ? L'instance Beat Saber, les maps et les sauvegardes sont conservées." ;;
        launcher_deleted) printf '%s' "Lanceur supprimé : %s" ;;
        launcher_instance_kept) printf '%s' "Les fichiers Beat Saber ont été conservés." ;;
        launcher_steam_removed) printf '%s' "Raccourci Steam supprimé." ;;
        launcher_steam_left) printf '%s' "Le raccourci Steam a été laissé en place." ;;
        launcher_added) printf '%s' "Lanceur prêt pour %s" ;;
        launcher_pick) printf '%s' "Choisir un lanceur" ;;
        uninstall_frame_about) printf '%s' "Ceci retire seulement bsmanager-frame. BSManager, les lanceurs, les instances, les maps et les sauvegardes restent." ;;
        ask_remove_frame) printf '%s' "Retirer bsmanager-frame ?" ;;
        uninstall_bsm_about) printf '%s' "Ceci retire l'application BSManager. Les instances, les maps et les sauvegardes restent." ;;
        uninstall_bsm_missing) printf '%s' "BSManager n'est pas installé." ;;
        ask_remove_bsm_app) printf '%s' "Retirer l'application BSManager ?" ;;
        ask_remove_bsm_config) printf '%s' "Supprimer les réglages BSManager (%s) ? Les instances, les maps et les sauvegardes ne sont pas concernées." ;;
        bsm_config_kept) printf '%s' "Réglages BSManager conservés." ;;
        bsm_config_removed) printf '%s' "Réglages BSManager supprimés." ;;
        bsm_app_removed) printf '%s' "Application BSManager retirée." ;;
        bsm_flatpak_left) printf '%s' "Le Flatpak BSManager est encore installé." ;;
        bsm_running_uninstall) printf '%s' "BSManager est en cours d'exécution. Fermez-le avant de le désinstaller." ;;
        compat_missing) printf '%s' "Aucun préfixe Proton (dossier compatdata avec pfx/) sous %s" ;;
        confirm_yn) printf '%s' "%s [o/N]" ;;
        prompt_no_tty) printf '%s' "Pas de /dev/tty pour les invites. Relancez avec --non-interactive et les options requises, ou depuis un terminal." ;;
        prompt_need_value) printf '%s' "Le mode non interactif exige une valeur explicite pour : %s" ;;
        err_action_failed) printf '%s' "Action échouée : %s (code %s). Retour au menu." ;;
        err_see_logs) printf '%s' "Détails : %s | actions : %s" ;;
        err_interrupted) printf '%s' "Interrompu. Steam est resté lancé. Fichiers temporaires de l'assistant nettoyés." ;;
        pipe_installing) printf '%s' "Pas de TTY — installation de bsmanager-frame." ;;
        pipe_installed) printf '%s' "Installé. Ouvrez un terminal et lancez : bsmanager-frame" ;;
        ok_steam_frame) printf '%s' "Steam Frame détecté" ;;
        ok_steam_likely) printf '%s' "SteamOS ARM64 : Steam Frame probable" ;;
        warn_unknown_platform) printf '%s' "Système non pris en charge / inconnu (arch=%s)" ;;
        ask_continue_platform) printf '%s' "Continuer quand même sur ce système inconnu ?" ;;
        aborted) printf '%s' "Annulé" ;;
        continue_force) printf '%s' "Poursuite forcée (--force)" ;;
        diag_complete) printf '%s' "Diagnostic terminé" ;;
        backup_written) printf '%s' "Sauvegarde écrite dans %s" ;;
        self_installed) printf '%s' "Installé : %s" ;;
        self_updated) printf '%s' "bsmanager-frame mis à jour : %s" ;;
        uninstall_done) printf '%s' "Désinstallation de bsmanager-frame terminée" ;;
        ask_remove_wrappers) printf '%s' "Supprimer les wrappers Beat Saber générés ?" ;;
        ask_remove_desktop) printf '%s' "Supprimer les entrées bureau générées ?" ;;
        ask_remove_bsmanager) printf '%s' "Supprimer l'application native BSManager (~/.local/opt/bs-manager) ?" ;;
        ask_shortcuts_now) printf '%s' "Créer/réparer les lanceurs et raccourcis maintenant ?" ;;
        ask_steam_install) printf '%s' "Demander à Steam d'installer %s maintenant ?" ;;
        steam_not_installed) printf '%s' "%s n'est pas installé." ;;
        steam_already) printf '%s' "%s est déjà installé" ;;
        steam_requesting) printf '%s' "Demande d'installation envoyée à Steam..." ;;
        steam_request_sent) printf '%s' "Demande d'installation envoyée à Steam." ;;
        steam_confirm_headset) printf '%s' "Confirmez l'installation dans le casque Steam Frame. En attente du démarrage de l'installation par Steam..." ;;
        steam_waiting_headset) printf '%s' "En attente de confirmation dans le casque... %ss" ;;
        steam_install_detected) printf '%s' "Installation Steam détectée." ;;
        steam_downloading) printf '%s' "Téléchargement de %s : %s / %s (%s%%)" ;;
        steam_in_progress) printf '%s' "Installation Steam en cours..." ;;
        steam_reports_complete) printf '%s' "Steam indique que l'installation est terminée." ;;
        steam_validating) printf '%s' "Validation de %s..." ;;
        steam_timeout) printf '%s' "L'installation Steam ne s'est pas terminée avant le délai. L'état actuel du système n'a pas été modifié." ;;
        steam_files_missing) printf '%s' "Steam indique une installation terminée, mais les fichiers requis manquent pour %s." ;;
        steam_ok_file) printf '%s' "%s" ;;
        steam_left_running) printf '%s' "Steam est resté lancé." ;;
        bsm_config_seeded) printf '%s' "Configuration BSManager créée et dossiers Proton installés renseignés : %s" ;;
        ask_flatpak) printf '%s' "Installer le Flatpak expérimental (%s) ? Non validé sur Steam Frame (v1.6.0 est antérieur à la PR #1136)." ;;
        bsm_native_preserved) printf '%s' "Installation native ARM64 BSManager actuelle conservée" ;;
        bsm_no_native_asset) printf '%s' "Aucune release native Steam Frame de BSManager n'est disponible pour le moment." ;;
        bsm_latest_release) printf '%s' "Dernier build natif Steam Frame : %s" ;;
        bsm_kept_unchanged) printf '%s' "L'installation native actuelle de BSManager est conservée." ;;
        bsm_no_native_fresh) printf '%s' "Aucune release native Steam Frame de BSManager n'est disponible pour le moment." ;;
        bsm_use_custom) printf '%s' "Utilisez un build natif ARM64 custom avec --bsmanager-url URL ou --bsmanager-dir PATH" ;;
        bsm_sf_repo) printf '%s' "Dépôt des releases Steam Frame : %s" ;;
        bsm_sf_query_failed) printf '%s' "Impossible de déterminer la dernière release Steam Frame de BSManager (%s)." ;;
        bsm_sf_uptodate) printf '%s' "Le build natif Steam Frame de BSManager est déjà à jour" ;;
        bsm_sf_installed) printf '%s' "Installé : release %s, commit %s" ;;
        bsm_sf_available) printf '%s' "Disponible : release %s, commit %s" ;;
        bsm_sf_legacy) printf '%s' "Installation ARM64 native : présente. Provenance du build : inconnue / installation antérieure" ;;
        bsm_sf_update_available) printf '%s' "Mise à jour disponible" ;;
        bsm_sf_confirm) printf '%s' "Remplacer le BSManager installé par le build Steam Frame %s ?" ;;
        bsm_sf_downloading) printf '%s' "Téléchargement du BSManager natif Steam Frame %s" ;;
        bsm_sf_need_yes) printf '%s' "Relancez avec --yes pour installer ce build Steam Frame en mode non interactif." ;;
        bsm_sf_bad_build_info) printf '%s' "build-info.json Steam Frame refusé : %s" ;;
        bsm_sf_bad_checksum) printf '%s' "Vérification SHA256 échouée pour %s" ;;
        bsm_sf_bad_archive) printf '%s' "Archive Steam Frame refusée : %s" ;;
        bsm_sf_source_release) printf '%s' "Source : release Steam Frame" ;;
        bsm_sf_source_url) printf '%s' "Source : URL personnalisée" ;;
        bsm_sf_source_dir) printf '%s' "Source : dossier local" ;;
        diag_sf_heading) printf '%s' "Build Steam Frame installé" ;;
        diag_sf_latest) printf '%s' "Dernière release Steam Frame" ;;
        diag_sf_unavailable) printf '%s' "indisponible (%s)" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak est expérimental et non validé sur Steam Frame. Le Flatpak officiel v1.6.0 est antérieur aux correctifs Steam Frame (notamment la PR #1136) et n'est pas une alternative compatible. À n'utiliser qu'avec --allow-flatpak." ;;
        bsm_dup_warn) printf '%s' "BSManager natif et Flatpak coexistent. Cela peut créer des entrées BSManager en double dans le bureau / SteamVR." ;;
        bsm_prefix_unsupported) printf '%s' "Ce BSManager ne gère pas un Proton séparé pour le modding. Utilisez un build contenant la PR #1136." ;;
        bsm_prefix_unknown) printf '%s' "Impossible de déterminer le support de prefix-proton-folder ; cette clé ne sera pas écrite." ;;
        bsm_running_config) printf '%s' "BSManager est en cours d'exécution. Fermez BSManager avant de modifier sa configuration." ;;
        bsm_launch_once) printf '%s' "Lancez BSManager une fois, puis relancez : bsmanager-frame proton" ;;
        bsm_flatpak_need_flag) printf '%s' "Les opérations Flatpak exigent --allow-flatpak (désactivé par défaut)." ;;
        bsm_flatpak_system_exists) printf '%s' "BSManager Flatpak système déjà installé ; refus d'ajouter une seconde copie utilisateur." ;;
        bsm_flatpak_update_hint) printf '%s' "BSManager Flatpak est installé. Relancez avec --allow-flatpak pour gérer les mises à jour Flatpak." ;;
        unknown_command) printf '%s' "Commande inconnue : %s" ;;
        unknown_option) printf '%s' "Option inconnue : %s" ;;
        *) return 1 ;;
    esac
}

_t_es() {
    case "$1" in
        lang_system_detected) printf '%s' "Idioma del sistema detectado: %s (preseleccionado)" ;;
        lang_saved) printf '%s' "Idioma guardado: %s" ;;
        lang_using) printf '%s' "Idioma en uso: %s" ;;
        lang_invalid) printf '%s' "Selección de idioma no válida." ;;
        ask_self_desktop) printf '%s' "¿Crear un acceso directo KDE/escritorio para BSManager Frame Script?" ;;
        ok_self_desktop) printf '%s' "Acceso directo creado: %s" ;;
        skip_self_desktop) printf '%s' "Acceso directo omitido" ;;
        menu_1) printf '%s' "Instalar / reparar" ;;
        menu_2) printf '%s' "Actualizar BSManager" ;;
        menu_3) printf '%s' "Configurar Proton" ;;
        menu_4) printf '%s' "Gestionar lanzadores de Beat Saber" ;;
        menu_5) printf '%s' "Crear / reparar accesos directos" ;;
        menu_uninstall_frame) printf '%s' "Desinstalar bsmanager-frame" ;;
        menu_uninstall_bsmanager) printf '%s' "Desinstalar BSManager" ;;
        menu_6) printf '%s' "Diagnosticar" ;;
        menu_7) printf '%s' "Copia de seguridad de la configuración" ;;
        menu_8) printf '%s' "Actualizar bsmanager-frame" ;;
        menu_9) printf '%s' "Desinstalar" ;;
        menu_0) printf '%s' "Salir" ;;
        menu_10) printf '%s' "Cambiar idioma" ;;
        menu_select) printf '%s' "Seleccionar" ;;
        menu_invalid) printf '%s' "Opción no válida" ;;
        menu_needs_tty) printf '%s' "El menú interactivo requiere /dev/tty. Pase un comando o --non-interactive." ;;
        bs_versions_detected) printf '%s' "Versiones de Beat Saber detectadas:" ;;
        bs_versions_none) printf '%s' "No se detectaron instancias de Beat Saber en BSInstances" ;;
        bs_version_prompt) printf '%s' "Elegir una versión de Beat Saber" ;;
        bs_version_pick_number) printf '%s' "Número" ;;
        bs_version_using) printf '%s' "Usando Beat Saber %s" ;;
        bs_version_none_die) printf '%s' "No hay instancias de Beat Saber en %s" ;;
        launcher_ready) printf '%s' "Lanzador listo: %s" ;;
        launcher_hint_menu5) printf '%s' "El comando shortcuts crea el acceso de escritorio e intenta reparar el acceso de Steam." ;;
        launcher_title) printf '%s' "Lanzadores de Beat Saber" ;;
        launcher_add) printf '%s' "Añadir o reparar una versión" ;;
        launcher_delete) printf '%s' "Eliminar un lanzador" ;;
        launcher_back) printf '%s' "Volver" ;;
        launcher_line) printf '%s' "%s — comando %s, escritorio %s%s" ;;
        launcher_present) printf '%s' "presente" ;;
        launcher_absent) printf '%s' "ausente" ;;
        launcher_orphan) printf '%s' ", carpeta ausente" ;;
        launcher_none_delete) printf '%s' "No hay un lanzador que eliminar." ;;
        launcher_confirm_delete) printf '%s' "¿Eliminar el lanzador de %s? La instancia de Beat Saber, los mapas y las partidas se conservan." ;;
        launcher_deleted) printf '%s' "Lanzador eliminado: %s" ;;
        launcher_instance_kept) printf '%s' "Los archivos de Beat Saber se conservaron." ;;
        launcher_steam_removed) printf '%s' "Acceso de Steam eliminado." ;;
        launcher_steam_left) printf '%s' "El acceso de Steam se dejó en su sitio." ;;
        launcher_added) printf '%s' "Lanzador listo para %s" ;;
        launcher_pick) printf '%s' "Elegir un lanzador" ;;
        uninstall_frame_about) printf '%s' "Esto solo retira bsmanager-frame. BSManager, los lanzadores, las instancias, los mapas y las partidas permanecen." ;;
        ask_remove_frame) printf '%s' "¿Retirar bsmanager-frame?" ;;
        uninstall_bsm_about) printf '%s' "Esto retira la aplicación BSManager. Las instancias, los mapas y las partidas permanecen." ;;
        uninstall_bsm_missing) printf '%s' "BSManager no está instalado." ;;
        ask_remove_bsm_app) printf '%s' "¿Retirar la aplicación BSManager?" ;;
        ask_remove_bsm_config) printf '%s' "¿Eliminar los ajustes de BSManager (%s)? Las instancias, los mapas y las partidas no entran." ;;
        bsm_config_kept) printf '%s' "Ajustes de BSManager conservados." ;;
        bsm_config_removed) printf '%s' "Ajustes de BSManager eliminados." ;;
        bsm_app_removed) printf '%s' "Aplicación BSManager retirada." ;;
        bsm_flatpak_left) printf '%s' "El Flatpak de BSManager sigue instalado." ;;
        bsm_running_uninstall) printf '%s' "BSManager está en ejecución. Ciérrelo antes de desinstalarlo." ;;
        compat_missing) printf '%s' "No hay prefijo Proton (carpeta compatdata con pfx/) en %s" ;;
        confirm_yn) printf '%s' "%s [s/N]" ;;
        prompt_no_tty) printf '%s' "No hay /dev/tty para prompts. Use --non-interactive y las opciones necesarias, o un terminal." ;;
        prompt_need_value) printf '%s' "El modo no interactivo requiere un valor explícito para: %s" ;;
        err_action_failed) printf '%s' "Acción fallida: %s (código %s). Volviendo al menú." ;;
        err_see_logs) printf '%s' "Detalles: %s | acciones: %s" ;;
        err_interrupted) printf '%s' "Interrumpido. Steam sigue en ejecución. Archivos temporales del asistente limpiados." ;;
        pipe_installing) printf '%s' "Sin TTY — instalando bsmanager-frame." ;;
        pipe_installed) printf '%s' "Instalado. Abra un terminal y ejecute: bsmanager-frame" ;;
        ok_steam_frame) printf '%s' "Steam Frame detectado" ;;
        ok_steam_likely) printf '%s' "SteamOS ARM64: probable Steam Frame" ;;
        warn_unknown_platform) printf '%s' "Sistema no compatible / desconocido (arch=%s)" ;;
        ask_continue_platform) printf '%s' "¿Continuar de todos modos en este sistema desconocido?" ;;
        aborted) printf '%s' "Cancelado" ;;
        continue_force) printf '%s' "Continuando por --force" ;;
        diag_complete) printf '%s' "Diagnóstico completo" ;;
        backup_written) printf '%s' "Copia de seguridad en %s" ;;
        self_installed) printf '%s' "Instalado %s" ;;
        self_updated) printf '%s' "bsmanager-frame actualizado en %s" ;;
        uninstall_done) printf '%s' "Desinstalación de bsmanager-frame completada" ;;
        ask_remove_wrappers) printf '%s' "¿Eliminar wrappers de Beat Saber generados?" ;;
        ask_remove_desktop) printf '%s' "¿Eliminar entradas de escritorio generadas?" ;;
        ask_remove_bsmanager) printf '%s' "¿Eliminar la aplicación nativa BSManager (~/.local/opt/bs-manager)?" ;;
        ask_shortcuts_now) printf '%s' "¿Crear/reparar lanzadores y accesos directos ahora?" ;;
        ask_steam_install) printf '%s' "¿Pedir a Steam que instale %s ahora?" ;;
        steam_not_installed) printf '%s' "%s no está instalado." ;;
        steam_already) printf '%s' "%s ya está instalado" ;;
        steam_requesting) printf '%s' "Solicitando la instalación a través de Steam..." ;;
        steam_request_sent) printf '%s' "Solicitud de instalación enviada a Steam." ;;
        steam_confirm_headset) printf '%s' "Confirme la instalación dentro del visor Steam Frame. Esperando a que Steam inicie la instalación..." ;;
        steam_waiting_headset) printf '%s' "Esperando confirmación en el visor... %ss" ;;
        steam_install_detected) printf '%s' "Instalación de Steam detectada." ;;
        steam_downloading) printf '%s' "Descargando %s: %s / %s (%s%%)" ;;
        steam_in_progress) printf '%s' "Instalación de Steam en curso..." ;;
        steam_reports_complete) printf '%s' "Steam indica que la instalación ha terminado." ;;
        steam_validating) printf '%s' "Validando %s..." ;;
        steam_timeout) printf '%s' "La instalación de Steam no terminó antes del tiempo límite. El estado actual del sistema no se modificó." ;;
        steam_files_missing) printf '%s' "Steam indica que está instalado, pero faltan los archivos requeridos de %s." ;;
        steam_ok_file) printf '%s' "%s" ;;
        steam_left_running) printf '%s' "Steam sigue en ejecución." ;;
        bsm_config_seeded) printf '%s' "Configuración de BSManager creada y carpetas Proton instaladas escritas: %s" ;;
        ask_flatpak) printf '%s' "¿Instalar el Flatpak experimental (%s)? No validado en Steam Frame (v1.6.0 es anterior a la PR #1136)." ;;
        bsm_native_preserved) printf '%s' "Instalación nativa ARM64 de BSManager conservada" ;;
        bsm_no_native_asset) printf '%s' "No hay una release nativa de BSManager para Steam Frame disponible ahora." ;;
        bsm_latest_release) printf '%s' "Último build nativo de Steam Frame: %s" ;;
        bsm_kept_unchanged) printf '%s' "La instalación nativa actual de BSManager se mantiene sin cambios." ;;
        bsm_no_native_fresh) printf '%s' "No hay una release nativa de BSManager para Steam Frame disponible ahora." ;;
        bsm_use_custom) printf '%s' "Use un build nativo ARM64 personalizado con --bsmanager-url URL o --bsmanager-dir PATH" ;;
        bsm_sf_repo) printf '%s' "Repositorio de releases Steam Frame: %s" ;;
        bsm_sf_query_failed) printf '%s' "No se pudo determinar la última release Steam Frame de BSManager (%s)." ;;
        bsm_sf_uptodate) printf '%s' "El build nativo Steam Frame de BSManager ya está actualizado" ;;
        bsm_sf_installed) printf '%s' "Instalado: release %s, commit %s" ;;
        bsm_sf_available) printf '%s' "Disponible: release %s, commit %s" ;;
        bsm_sf_legacy) printf '%s' "Instalación ARM64 nativa: presente. Procedencia del build: desconocida / instalación anterior" ;;
        bsm_sf_update_available) printf '%s' "Actualización disponible" ;;
        bsm_sf_confirm) printf '%s' "¿Reemplazar el BSManager instalado por el build Steam Frame %s?" ;;
        bsm_sf_downloading) printf '%s' "Descargando BSManager nativo Steam Frame %s" ;;
        bsm_sf_need_yes) printf '%s' "Vuelva a ejecutar con --yes para instalar este build Steam Frame en modo no interactivo." ;;
        bsm_sf_bad_build_info) printf '%s' "build-info.json de Steam Frame rechazado: %s" ;;
        bsm_sf_bad_checksum) printf '%s' "Falló la verificación SHA256 de %s" ;;
        bsm_sf_bad_archive) printf '%s' "Archivo Steam Frame rechazado: %s" ;;
        bsm_sf_source_release) printf '%s' "Fuente: release Steam Frame" ;;
        bsm_sf_source_url) printf '%s' "Fuente: URL personalizada" ;;
        bsm_sf_source_dir) printf '%s' "Fuente: directorio local" ;;
        diag_sf_heading) printf '%s' "Build Steam Frame instalado" ;;
        diag_sf_latest) printf '%s' "Última release Steam Frame" ;;
        diag_sf_unavailable) printf '%s' "no disponible (%s)" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak es experimental y no está validado en Steam Frame. El Flatpak oficial v1.6.0 es anterior a las correcciones de Steam Frame (incluida la PR #1136) y no es una alternativa compatible. Úselo solo con --allow-flatpak." ;;
        bsm_dup_warn) printf '%s' "Coexisten BSManager nativo y Flatpak. Esto puede crear entradas duplicadas en el escritorio / SteamVR." ;;
        bsm_prefix_unsupported) printf '%s' "Este BSManager no admite un Proton separado para modding. Use un build con la PR #1136." ;;
        bsm_prefix_unknown) printf '%s' "No se pudo determinar el soporte de prefix-proton-folder; no se escribirá esa clave." ;;
        bsm_running_config) printf '%s' "BSManager está en ejecución. Ciérrelo antes de cambiar su configuración." ;;
        bsm_launch_once) printf '%s' "Abra BSManager una vez y vuelva a ejecutar: bsmanager-frame proton" ;;
        bsm_flatpak_need_flag) printf '%s' "Las operaciones Flatpak requieren --allow-flatpak (desactivado por defecto)." ;;
        bsm_flatpak_system_exists) printf '%s' "Ya hay BSManager Flatpak de sistema; no se instalará una segunda copia de usuario." ;;
        bsm_flatpak_update_hint) printf '%s' "BSManager Flatpak está instalado. Use --allow-flatpak para gestionar actualizaciones Flatpak." ;;
        unknown_command) printf '%s' "Comando desconocido: %s" ;;
        unknown_option) printf '%s' "Opción desconocida: %s" ;;
        *) return 1 ;;
    esac
}

_t_de() {
    case "$1" in
        lang_system_detected) printf '%s' "Systemsprache erkannt: %s (vorausgewählt)" ;;
        lang_saved) printf '%s' "Sprache gespeichert: %s" ;;
        lang_using) printf '%s' "Verwendete Sprache: %s" ;;
        lang_invalid) printf '%s' "Ungültige Sprachauswahl." ;;
        ask_self_desktop) printf '%s' "KDE-/Desktop-Verknüpfung für BSManager Frame Script erstellen?" ;;
        ok_self_desktop) printf '%s' "Desktop-Verknüpfung erstellt: %s" ;;
        skip_self_desktop) printf '%s' "Desktop-Verknüpfung übersprungen" ;;
        menu_1) printf '%s' "Installieren / reparieren" ;;
        menu_2) printf '%s' "BSManager aktualisieren" ;;
        menu_3) printf '%s' "Proton konfigurieren" ;;
        menu_4) printf '%s' "Beat-Saber-Starter verwalten" ;;
        menu_5) printf '%s' "Verknüpfungen erstellen / reparieren" ;;
        menu_uninstall_frame) printf '%s' "bsmanager-frame deinstallieren" ;;
        menu_uninstall_bsmanager) printf '%s' "BSManager deinstallieren" ;;
        menu_6) printf '%s' "Diagnose" ;;
        menu_7) printf '%s' "Konfiguration sichern" ;;
        menu_8) printf '%s' "bsmanager-frame aktualisieren" ;;
        menu_9) printf '%s' "Deinstallieren" ;;
        menu_0) printf '%s' "Beenden" ;;
        menu_10) printf '%s' "Sprache ändern" ;;
        menu_select) printf '%s' "Auswahl" ;;
        menu_invalid) printf '%s' "Ungültige Auswahl" ;;
        menu_needs_tty) printf '%s' "Interaktives Menü benötigt /dev/tty. Befehl oder --non-interactive angeben." ;;
        bs_versions_detected) printf '%s' "Erkannte Beat-Saber-Versionen:" ;;
        bs_versions_none) printf '%s' "Keine Beat-Saber-Instanzen unter BSInstances gefunden" ;;
        bs_version_prompt) printf '%s' "Beat-Saber-Version wählen" ;;
        bs_version_pick_number) printf '%s' "Nummer" ;;
        bs_version_using) printf '%s' "Verwende Beat Saber %s" ;;
        bs_version_none_die) printf '%s' "Keine Beat-Saber-Instanzen unter %s gefunden" ;;
        launcher_ready) printf '%s' "Starter bereit: %s" ;;
        launcher_hint_menu5) printf '%s' "Der Befehl shortcuts legt den Desktop-Eintrag an und versucht die Steam-Verknüpfung zu reparieren." ;;
        launcher_title) printf '%s' "Beat-Saber-Starter" ;;
        launcher_add) printf '%s' "Version hinzufügen oder reparieren" ;;
        launcher_delete) printf '%s' "Starter löschen" ;;
        launcher_back) printf '%s' "Zurück" ;;
        launcher_line) printf '%s' "%s — Befehl %s, Desktop %s%s" ;;
        launcher_present) printf '%s' "vorhanden" ;;
        launcher_absent) printf '%s' "fehlt" ;;
        launcher_orphan) printf '%s' ", Ordner fehlt" ;;
        launcher_none_delete) printf '%s' "Kein Starter zum Löschen." ;;
        launcher_confirm_delete) printf '%s' "Starter für %s löschen? Beat-Saber-Instanz, Maps und Spielstände bleiben." ;;
        launcher_deleted) printf '%s' "Starter entfernt: %s" ;;
        launcher_instance_kept) printf '%s' "Beat-Saber-Dateien wurden behalten." ;;
        launcher_steam_removed) printf '%s' "Steam-Verknüpfung entfernt." ;;
        launcher_steam_left) printf '%s' "Die Steam-Verknüpfung blieb bestehen." ;;
        launcher_added) printf '%s' "Starter bereit für %s" ;;
        launcher_pick) printf '%s' "Starter auswählen" ;;
        uninstall_frame_about) printf '%s' "Dies entfernt nur bsmanager-frame. BSManager, Starter, Instanzen, Maps und Spielstände bleiben." ;;
        ask_remove_frame) printf '%s' "bsmanager-frame entfernen?" ;;
        uninstall_bsm_about) printf '%s' "Dies entfernt die BSManager-Anwendung. Instanzen, Maps und Spielstände bleiben." ;;
        uninstall_bsm_missing) printf '%s' "BSManager ist nicht installiert." ;;
        ask_remove_bsm_app) printf '%s' "BSManager-Anwendung entfernen?" ;;
        ask_remove_bsm_config) printf '%s' "BSManager-Einstellungen löschen (%s)? Instanzen, Maps und Spielstände sind nicht enthalten." ;;
        bsm_config_kept) printf '%s' "BSManager-Einstellungen behalten." ;;
        bsm_config_removed) printf '%s' "BSManager-Einstellungen entfernt." ;;
        bsm_app_removed) printf '%s' "BSManager-Anwendung entfernt." ;;
        bsm_flatpak_left) printf '%s' "Flatpak-BSManager ist weiterhin installiert." ;;
        bsm_running_uninstall) printf '%s' "BSManager läuft. Schließen Sie es vor der Deinstallation." ;;
        compat_missing) printf '%s' "Kein Proton-Präfix (compatdata-Ordner mit pfx/) unter %s" ;;
        confirm_yn) printf '%s' "%s [j/N]" ;;
        prompt_no_tty) printf '%s' "Kein /dev/tty für Eingaben. Mit --non-interactive und Optionen oder im Terminal erneut ausführen." ;;
        prompt_need_value) printf '%s' "Nicht-interaktiver Modus benötigt einen expliziten Wert für: %s" ;;
        err_action_failed) printf '%s' "Aktion fehlgeschlagen: %s (Code %s). Zurück zum Menü." ;;
        err_see_logs) printf '%s' "Details: %s | Aktionen: %s" ;;
        err_interrupted) printf '%s' "Abgebrochen. Steam läuft weiter. Temporäre Hilfsdateien wurden entfernt." ;;
        pipe_installing) printf '%s' "Kein TTY — installiere bsmanager-frame." ;;
        pipe_installed) printf '%s' "Installiert. Terminal öffnen und ausführen: bsmanager-frame" ;;
        ok_steam_frame) printf '%s' "Steam Frame erkannt" ;;
        ok_steam_likely) printf '%s' "SteamOS ARM64: wahrscheinlich Steam Frame" ;;
        warn_unknown_platform) printf '%s' "Nicht unterstütztes / unbekanntes System (arch=%s)" ;;
        ask_continue_platform) printf '%s' "Trotzdem auf diesem unbekannten System fortfahren?" ;;
        aborted) printf '%s' "Abgebrochen" ;;
        continue_force) printf '%s' "Fortsetzung wegen --force" ;;
        diag_complete) printf '%s' "Diagnose abgeschlossen" ;;
        backup_written) printf '%s' "Sicherung geschrieben nach %s" ;;
        self_installed) printf '%s' "Installiert: %s" ;;
        self_updated) printf '%s' "bsmanager-frame aktualisiert: %s" ;;
        uninstall_done) printf '%s' "Deinstallation von bsmanager-frame abgeschlossen" ;;
        ask_remove_wrappers) printf '%s' "Generierte Beat-Saber-Wrapper entfernen?" ;;
        ask_remove_desktop) printf '%s' "Generierte Desktop-Einträge entfernen?" ;;
        ask_remove_bsmanager) printf '%s' "Native BSManager-Anwendung entfernen (~/.local/opt/bs-manager)?" ;;
        ask_shortcuts_now) printf '%s' "Starter und Verknüpfungen jetzt erstellen/reparieren?" ;;
        ask_steam_install) printf '%s' "Steam bitten, %s jetzt zu installieren?" ;;
        steam_not_installed) printf '%s' "%s ist nicht installiert." ;;
        steam_already) printf '%s' "%s ist bereits installiert" ;;
        steam_requesting) printf '%s' "Installation über Steam wird angefordert..." ;;
        steam_request_sent) printf '%s' "Installationsanfrage an Steam gesendet." ;;
        steam_confirm_headset) printf '%s' "Bestätigen Sie die Installation im Steam Frame Headset. Warten, bis Steam die Installation startet..." ;;
        steam_waiting_headset) printf '%s' "Warten auf Bestätigung im Headset... %ss" ;;
        steam_install_detected) printf '%s' "Steam-Installation erkannt." ;;
        steam_downloading) printf '%s' "Download von %s: %s / %s (%s%%)" ;;
        steam_in_progress) printf '%s' "Steam-Installation läuft..." ;;
        steam_reports_complete) printf '%s' "Steam meldet, dass die Installation abgeschlossen ist." ;;
        steam_validating) printf '%s' "Validierung von %s..." ;;
        steam_timeout) printf '%s' "Die Steam-Installation wurde vor dem Zeitlimit nicht abgeschlossen. Der aktuelle Systemzustand blieb unverändert." ;;
        steam_files_missing) printf '%s' "Steam meldet installiert, aber erforderliche Dateien fehlen für %s." ;;
        steam_ok_file) printf '%s' "%s" ;;
        steam_left_running) printf '%s' "Steam läuft weiter." ;;
        bsm_config_seeded) printf '%s' "BSManager-Konfiguration erstellt und installierte Proton-Ordner eingetragen: %s" ;;
        ask_flatpak) printf '%s' "Experimentelles Flatpak (%s) installieren? Auf Steam Frame nicht validiert (v1.6.0 liegt vor PR #1136)." ;;
        bsm_native_preserved) printf '%s' "Aktuelle native ARM64-BSManager-Installation beibehalten" ;;
        bsm_no_native_asset) printf '%s' "Derzeit ist kein gültiges natives Steam-Frame-BSManager-Release verfügbar." ;;
        bsm_latest_release) printf '%s' "Neuester nativer Steam-Frame-Build: %s" ;;
        bsm_kept_unchanged) printf '%s' "Die aktuelle native BSManager-Installation bleibt unverändert." ;;
        bsm_no_native_fresh) printf '%s' "Derzeit ist kein gültiges natives Steam-Frame-BSManager-Release verfügbar." ;;
        bsm_use_custom) printf '%s' "Nutzen Sie einen eigenen nativen ARM64-Build mit --bsmanager-url URL oder --bsmanager-dir PATH" ;;
        bsm_sf_repo) printf '%s' "Steam-Frame-Release-Repository: %s" ;;
        bsm_sf_query_failed) printf '%s' "Das neueste Steam-Frame-BSManager-Release konnte nicht ermittelt werden (%s)." ;;
        bsm_sf_uptodate) printf '%s' "Der native Steam-Frame-Build von BSManager ist bereits aktuell" ;;
        bsm_sf_installed) printf '%s' "Installiert: Release %s, Commit %s" ;;
        bsm_sf_available) printf '%s' "Verfügbar: Release %s, Commit %s" ;;
        bsm_sf_legacy) printf '%s' "Native ARM64-Installation: vorhanden. Build-Herkunft: unbekannt / ältere Installation" ;;
        bsm_sf_update_available) printf '%s' "Update verfügbar" ;;
        bsm_sf_confirm) printf '%s' "Installiertes BSManager durch Steam-Frame-Build %s ersetzen?" ;;
        bsm_sf_downloading) printf '%s' "Natives Steam-Frame-BSManager wird heruntergeladen: %s" ;;
        bsm_sf_need_yes) printf '%s' "Mit --yes erneut ausführen, um diesen Steam-Frame-Build nicht-interaktiv zu installieren." ;;
        bsm_sf_bad_build_info) printf '%s' "Steam-Frame-build-info.json abgelehnt: %s" ;;
        bsm_sf_bad_checksum) printf '%s' "SHA256-Prüfung fehlgeschlagen für %s" ;;
        bsm_sf_bad_archive) printf '%s' "Steam-Frame-Archiv abgelehnt: %s" ;;
        bsm_sf_source_release) printf '%s' "Quelle: Steam-Frame-Release" ;;
        bsm_sf_source_url) printf '%s' "Quelle: eigene URL" ;;
        bsm_sf_source_dir) printf '%s' "Quelle: lokales Verzeichnis" ;;
        diag_sf_heading) printf '%s' "Installierter Steam-Frame-Build" ;;
        diag_sf_latest) printf '%s' "Neuestes Steam-Frame-Release" ;;
        diag_sf_unavailable) printf '%s' "nicht verfügbar (%s)" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak ist experimentell und auf Steam Frame nicht validiert. Das offizielle Flatpak v1.6.0 liegt vor den Steam-Frame-Korrekturen (einschließlich PR #1136) und ist keine kompatible Alternative. Nur mit --allow-flatpak verwenden." ;;
        bsm_dup_warn) printf '%s' "Native und Flatpak-BSManager-Installationen koexistieren. Das kann doppelte BSManager-Einträge in Desktop/SteamVR erzeugen." ;;
        bsm_prefix_unsupported) printf '%s' "Diese BSManager-Version unterstützt kein separates Modding-Proton. Nutzen Sie einen Build mit PR #1136." ;;
        bsm_prefix_unknown) printf '%s' "Unterstützung für prefix-proton-folder nicht ermittelbar; Schlüssel wird nicht geschrieben." ;;
        bsm_running_config) printf '%s' "BSManager läuft gerade. Schließen Sie BSManager, bevor Sie die Konfiguration ändern." ;;
        bsm_launch_once) printf '%s' "Starten Sie BSManager einmal, dann erneut: bsmanager-frame proton" ;;
        bsm_flatpak_need_flag) printf '%s' "Flatpak-Operationen erfordern --allow-flatpak (standardmäßig deaktiviert)." ;;
        bsm_flatpak_system_exists) printf '%s' "System-Flatpak-BSManager bereits installiert; keine zweite User-Kopie." ;;
        bsm_flatpak_update_hint) printf '%s' "Flatpak-BSManager ist installiert. Mit --allow-flatpak erneut ausführen für Flatpak-Updates." ;;
        unknown_command) printf '%s' "Unbekannter Befehl: %s" ;;
        unknown_option) printf '%s' "Unbekannte Option: %s" ;;
        *) return 1 ;;
    esac
}

_t_sw() {
    case "$1" in
        lang_system_detected) printf '%s' "Lugha ya mfumo imegunduliwa: %s (imechaguliwa awali)" ;;
        lang_saved) printf '%s' "Lugha imehifadhiwa: %s" ;;
        lang_using) printf '%s' "Lugha inayotumika: %s" ;;
        lang_invalid) printf '%s' "Chaguo la lugha si sahihi." ;;
        ask_self_desktop) printf '%s' "Unda njia ya mkato ya KDE/desktop kwa BSManager Frame Script?" ;;
        ok_self_desktop) printf '%s' "Njia ya mkato imeundwa: %s" ;;
        skip_self_desktop) printf '%s' "Njia ya mkato imerukwa" ;;
        menu_1) printf '%s' "Sakinisha / rekebisha" ;;
        menu_2) printf '%s' "Sasisha BSManager" ;;
        menu_3) printf '%s' "Sanidi Proton" ;;
        menu_4) printf '%s' "Simamia vizinduzi vya Beat Saber" ;;
        menu_5) printf '%s' "Unda / rekebisha njia za mkato" ;;
        menu_uninstall_frame) printf '%s' "Ondoa bsmanager-frame" ;;
        menu_uninstall_bsmanager) printf '%s' "Ondoa BSManager" ;;
        menu_6) printf '%s' "Chunguza (diagnose)" ;;
        menu_7) printf '%s' "Hifadhi nakala ya usanidi" ;;
        menu_8) printf '%s' "Sasisha bsmanager-frame" ;;
        menu_9) printf '%s' "Ondoa usakinishaji" ;;
        menu_0) printf '%s' "Toka" ;;
        menu_10) printf '%s' "Badilisha lugha" ;;
        menu_select) printf '%s' "Chagua" ;;
        menu_invalid) printf '%s' "Chaguo si sahihi" ;;
        menu_needs_tty) printf '%s' "Menyu inahitaji /dev/tty. Tumia amri au --non-interactive." ;;
        bs_versions_detected) printf '%s' "Matoleo ya Beat Saber yaliyogunduliwa:" ;;
        bs_versions_none) printf '%s' "Hakuna matukio ya Beat Saber chini ya BSInstances" ;;
        bs_version_prompt) printf '%s' "Chagua toleo la Beat Saber" ;;
        bs_version_pick_number) printf '%s' "Nambari" ;;
        bs_version_using) printf '%s' "Inatumia Beat Saber %s" ;;
        bs_version_none_die) printf '%s' "Hakuna matukio ya Beat Saber chini ya %s" ;;
        launcher_ready) printf '%s' "Kizinduzi kiko tayari: %s" ;;
        launcher_hint_menu5) printf '%s' "Amri ya shortcuts huongeza ingizo la desktop na kujaribu kurekebisha njia ya mkato ya Steam." ;;
        launcher_title) printf '%s' "Vizinduzi vya Beat Saber" ;;
        launcher_add) printf '%s' "Ongeza au rekebisha toleo" ;;
        launcher_delete) printf '%s' "Futa kizinduzi" ;;
        launcher_back) printf '%s' "Rudi" ;;
        launcher_line) printf '%s' "%s — amri %s, desktop %s%s" ;;
        launcher_present) printf '%s' "ipo" ;;
        launcher_absent) printf '%s' "haipo" ;;
        launcher_orphan) printf '%s' ", folda haipo" ;;
        launcher_none_delete) printf '%s' "Hakuna kizinduzi cha kufuta." ;;
        launcher_confirm_delete) printf '%s' "Futa kizinduzi cha %s? Toleo la Beat Saber, ramani na hifadhi zinabaki." ;;
        launcher_deleted) printf '%s' "Kizinduzi kimeondolewa: %s" ;;
        launcher_instance_kept) printf '%s' "Faili za Beat Saber zimehifadhiwa." ;;
        launcher_steam_removed) printf '%s' "Njia ya mkato ya Steam imeondolewa." ;;
        launcher_steam_left) printf '%s' "Njia ya mkato ya Steam imeachwa." ;;
        launcher_added) printf '%s' "Kizinduzi kiko tayari kwa %s" ;;
        launcher_pick) printf '%s' "Chagua kizinduzi" ;;
        uninstall_frame_about) printf '%s' "Hii huondoa bsmanager-frame pekee. BSManager, vizinduzi, matoleo, ramani na hifadhi zinabaki." ;;
        ask_remove_frame) printf '%s' "Ondoa bsmanager-frame?" ;;
        uninstall_bsm_about) printf '%s' "Hii huondoa programu ya BSManager. Matoleo, ramani na hifadhi zinabaki." ;;
        uninstall_bsm_missing) printf '%s' "BSManager haijasakinishwa." ;;
        ask_remove_bsm_app) printf '%s' "Ondoa programu ya BSManager?" ;;
        ask_remove_bsm_config) printf '%s' "Futa mipangilio ya BSManager (%s)? Matoleo, ramani na hifadhi hazihusiki." ;;
        bsm_config_kept) printf '%s' "Mipangilio ya BSManager imehifadhiwa." ;;
        bsm_config_removed) printf '%s' "Mipangilio ya BSManager imeondolewa." ;;
        bsm_app_removed) printf '%s' "Programu ya BSManager imeondolewa." ;;
        bsm_flatpak_left) printf '%s' "Flatpak ya BSManager bado imesakinishwa." ;;
        bsm_running_uninstall) printf '%s' "BSManager inaendesha. Ifunge kabla ya kuiondoa." ;;
        compat_missing) printf '%s' "Hakuna kiambishi awali cha Proton (folda compatdata yenye pfx/) chini ya %s" ;;
        confirm_yn) printf '%s' "%s [d/H]" ;;
        prompt_no_tty) printf '%s' "Hakuna /dev/tty. Tumia --non-interactive na chaguo zinazohitajika, au terminal." ;;
        prompt_need_value) printf '%s' "Hali isiyo ya maingiliano inahitaji thamani wazi kwa: %s" ;;
        err_action_failed) printf '%s' "Kitendo kimeshindwa: %s (kodi %s). Kurudi kwenye menyu." ;;
        err_see_logs) printf '%s' "Maelezo: %s | vitendo: %s" ;;
        err_interrupted) printf '%s' "Imekatizwa. Steam imeendelea kufanya kazi. Faili za muda za msaidizi zimesafishwa." ;;
        pipe_installing) printf '%s' "Hakuna TTY — inasakinisha bsmanager-frame." ;;
        pipe_installed) printf '%s' "Imesakinishwa. Fungua terminal na endesha: bsmanager-frame" ;;
        ok_steam_frame) printf '%s' "Steam Frame imegunduliwa" ;;
        ok_steam_likely) printf '%s' "SteamOS ARM64: inawezekana Steam Frame" ;;
        warn_unknown_platform) printf '%s' "Mfumo haujaungwa mkono / haijulikani (arch=%s)" ;;
        ask_continue_platform) printf '%s' "Endelea hata hivyo kwenye mfumo huu usiojulikana?" ;;
        aborted) printf '%s' "Imeghairiwa" ;;
        continue_force) printf '%s' "Inaendelea kwa sababu ya --force" ;;
        diag_complete) printf '%s' "Uchunguzi umekamilika" ;;
        backup_written) printf '%s' "Nakala ya hifadhi imeandikwa kwa %s" ;;
        self_installed) printf '%s' "Imesakinishwa %s" ;;
        self_updated) printf '%s' "bsmanager-frame imesasishwa kwa %s" ;;
        uninstall_done) printf '%s' "Uondoaji wa bsmanager-frame umekamilika" ;;
        ask_remove_wrappers) printf '%s' "Ondoa wrappers za Beat Saber zilizotengenezwa?" ;;
        ask_remove_desktop) printf '%s' "Ondoa maingizo ya desktop yaliyotengenezwa?" ;;
        ask_remove_bsmanager) printf '%s' "Ondoa programu asilia ya BSManager (~/.local/opt/bs-manager)?" ;;
        ask_shortcuts_now) printf '%s' "Unda/rekebisha vizinduzi na njia za mkato sasa?" ;;
        ask_steam_install) printf '%s' "Omba Steam isakinishe %s sasa?" ;;
        steam_not_installed) printf '%s' "%s haijasakinishwa." ;;
        steam_already) printf '%s' "%s tayari imesakinishwa" ;;
        steam_requesting) printf '%s' "Inaomba usakinishaji kupitia Steam..." ;;
        steam_request_sent) printf '%s' "Ombi la usakinishaji limetumwa kwa Steam." ;;
        steam_confirm_headset) printf '%s' "Thibitisha usakinishaji ndani ya kifaa cha kichwa cha Steam Frame. Inasubiri Steam ianze usakinishaji..." ;;
        steam_waiting_headset) printf '%s' "Inasubiri uthibitisho kwenye kifaa cha kichwa... %ss" ;;
        steam_install_detected) printf '%s' "Usakinishaji wa Steam umegunduliwa." ;;
        steam_downloading) printf '%s' "Inapakua %s: %s / %s (%s%%)" ;;
        steam_in_progress) printf '%s' "Usakinishaji wa Steam unaendelea..." ;;
        steam_reports_complete) printf '%s' "Steam inaripoti kuwa usakinishaji umekamilika." ;;
        steam_validating) printf '%s' "Inathibitisha %s..." ;;
        steam_timeout) printf '%s' "Usakinishaji wa Steam haukukamilika kabla ya muda kuisha. Hali ya sasa ya mfumo haikubadilishwa." ;;
        steam_files_missing) printf '%s' "Steam inaripoti kuwa imesakinishwa, lakini faili zinazohitajika za %s hazipo." ;;
        steam_ok_file) printf '%s' "%s" ;;
        steam_left_running) printf '%s' "Steam imeendelea kufanya kazi." ;;
        bsm_config_seeded) printf '%s' "Usanidi wa BSManager umeundwa na folda za Proton zilizosakinishwa zimeandikwa: %s" ;;
        ask_flatpak) printf '%s' "Sakinisha Flatpak ya majaribio (%s)? Haijathibitishwa kwenye Steam Frame (v1.6.0 iko kabla ya PR #1136)." ;;
        bsm_native_preserved) printf '%s' "Usakinishaji wa asili wa BSManager ARM64 umehifadhiwa" ;;
        bsm_no_native_asset) printf '%s' "Hakuna toleo halali la asili la BSManager la Steam Frame kwa sasa." ;;
        bsm_latest_release) printf '%s' "Build mpya ya asili ya Steam Frame: %s" ;;
        bsm_kept_unchanged) printf '%s' "Usakinishaji wa sasa wa asili wa BSManager umeachwa bila mabadiliko." ;;
        bsm_no_native_fresh) printf '%s' "Hakuna toleo halali la asili la BSManager la Steam Frame kwa sasa." ;;
        bsm_use_custom) printf '%s' "Tumia build asilia ya ARM64 kwa --bsmanager-url URL au --bsmanager-dir PATH" ;;
        bsm_sf_repo) printf '%s' "Hifadhi ya matoleo ya Steam Frame: %s" ;;
        bsm_sf_query_failed) printf '%s' "Imeshindwa kutambua toleo jipya la BSManager la Steam Frame (%s)." ;;
        bsm_sf_uptodate) printf '%s' "Build asilia ya Steam Frame ya BSManager tayari iko mpya" ;;
        bsm_sf_installed) printf '%s' "Iliyosakinishwa: toleo %s, commit %s" ;;
        bsm_sf_available) printf '%s' "Inayopatikana: toleo %s, commit %s" ;;
        bsm_sf_legacy) printf '%s' "Usakinishaji asilia wa ARM64: upo. Asili ya build: haijulikani / usakinishaji wa zamani" ;;
        bsm_sf_update_available) printf '%s' "Sasisho linapatikana" ;;
        bsm_sf_confirm) printf '%s' "Badilisha BSManager iliyosakinishwa na build ya Steam Frame %s?" ;;
        bsm_sf_downloading) printf '%s' "Inapakua BSManager asilia ya Steam Frame %s" ;;
        bsm_sf_need_yes) printf '%s' "Endesha tena na --yes kusakinisha build hii ya Steam Frame bila maingiliano." ;;
        bsm_sf_bad_build_info) printf '%s' "build-info.json ya Steam Frame imekataliwa: %s" ;;
        bsm_sf_bad_checksum) printf '%s' "Uthibitishaji wa SHA256 umeshindwa kwa %s" ;;
        bsm_sf_bad_archive) printf '%s' "Kumbukumbu ya Steam Frame imekataliwa: %s" ;;
        bsm_sf_source_release) printf '%s' "Chanzo: toleo la Steam Frame" ;;
        bsm_sf_source_url) printf '%s' "Chanzo: URL maalum" ;;
        bsm_sf_source_dir) printf '%s' "Chanzo: folda ya ndani" ;;
        diag_sf_heading) printf '%s' "Build ya Steam Frame iliyosakinishwa" ;;
        diag_sf_latest) printf '%s' "Toleo jipya la Steam Frame" ;;
        diag_sf_unavailable) printf '%s' "haipatikani (%s)" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak ni ya majaribio na haijathibitishwa kwenye Steam Frame. Flatpak rasmi v1.6.0 iko kabla ya marekebisho ya Steam Frame (pamoja na PR #1136) na si mbadala unaoendana. Tumia tu na --allow-flatpak." ;;
        bsm_dup_warn) printf '%s' "BSManager asilia na Flatpak zipo pamoja. Hii inaweza kuunda maingizo maradufu ya BSManager kwenye desktop / SteamVR." ;;
        bsm_prefix_unsupported) printf '%s' "BSManager hii haiungi mkono Proton tofauti kwa modding. Tumia build yenye PR #1136." ;;
        bsm_prefix_unknown) printf '%s' "Haiwezi kubainisha usaidizi wa prefix-proton-folder; funguo hiyo haitaandikwa." ;;
        bsm_running_config) printf '%s' "BSManager inaendeshwa sasa. Funga BSManager kabla ya kubadilisha usanidi." ;;
        bsm_launch_once) printf '%s' "Anzisha BSManager mara moja, kisha endesha tena: bsmanager-frame proton" ;;
        bsm_flatpak_need_flag) printf '%s' "Operesheni za Flatpak zinahitaji --allow-flatpak (imezimwa kwa chaguo-msingi)." ;;
        bsm_flatpak_system_exists) printf '%s' "BSManager Flatpak ya mfumo tayari ipo; hakutakuwa na nakala ya pili ya mtumiaji." ;;
        bsm_flatpak_update_hint) printf '%s' "BSManager Flatpak imesakinishwa. Endesha tena na --allow-flatpak kusasisha Flatpak." ;;
        unknown_command) printf '%s' "Amri haijulikani: %s" ;;
        unknown_option) printf '%s' "Chaguo halijulikani: %s" ;;
        *) return 1 ;;
    esac
}

# Translate key; extra args are printf parameters for the template.
t() {
    local key="$1"
    shift
    local template=""
    case "${UI_LANG:-en}" in
        fr) template="$(_t_fr "$key" || true)" ;;
        es) template="$(_t_es "$key" || true)" ;;
        de) template="$(_t_de "$key" || true)" ;;
        sw) template="$(_t_sw "$key" || true)" ;;
        *) template="" ;;
    esac
    if [[ -z "$template" ]]; then
        template="$(_t_en "$key")"
    fi
    # shellcheck disable=SC2059
    printf "$template" "$@"
}

save_language() {
    local lang="$1"
    mkdir -p "$TOOL_DATA_DIR" 2>/dev/null || true
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] save language=$lang -> $TOOL_LANG_FILE"
        UI_LANG="$lang"
        return 0
    fi
    printf '%s\n' "$lang" >"$TOOL_LANG_FILE"
    UI_LANG="$lang"
    log_action OK "language_set=$lang"
    success "$(t lang_saved "$lang")"
}

prompt_language_selection() {
    local answer=""
    local sys_lang default_num mark_en="" mark_fr="" mark_es="" mark_de="" mark_sw=""
    if ! have_tty; then
        UI_LANG="$(detect_system_lang)"
        return 0
    fi

    sys_lang="$(detect_system_lang)"
    default_num="$(lang_menu_number "$sys_lang")"
    case "$sys_lang" in
        en) mark_en=" *" ;;
        fr) mark_fr=" *" ;;
        es) mark_es=" *" ;;
        de) mark_de=" *" ;;
        sw) mark_sw=" *" ;;
    esac

    # Temporarily use system language for the picker labels when possible
    UI_LANG="$sys_lang"
    tty_open || true

    tty_printf '\n%s\n%s\n\n' "$(t lang_prompt_title)" "$(t lang_system_detected "$sys_lang")"
    tty_printf '1) %s (en)%s\n' "$(t lang_opt_en)" "$mark_en"
    tty_printf '2) %s (fr)%s\n' "$(t lang_opt_fr)" "$mark_fr"
    tty_printf '3) %s (es)%s\n' "$(t lang_opt_es)" "$mark_es"
    tty_printf '4) %s (de)%s\n' "$(t lang_opt_de)" "$mark_de"
    tty_printf '5) %s (sw)%s\n\n' "$(t lang_opt_sw)" "$mark_sw"

    while true; do
        # Capture via stdout — never printf -v into a caller local
        answer="$(prompt_reply "$(t menu_select)" "$default_num")"
        # Keep only the first token (guards against accidental trailing junk)
        answer="${answer%%[[:space:]]*}"
        case "$answer" in
            1|en|EN|En) save_language en; return 0 ;;
            2|fr|FR|Fr) save_language fr; return 0 ;;
            3|es|ES|Es) save_language es; return 0 ;;
            4|de|DE|De) save_language de; return 0 ;;
            5|sw|SW|Sw) save_language sw; return 0 ;;
            *)
                tty_printf '%s (%q)\n' "$(t lang_invalid)" "$answer"
                log_action WARN "lang_invalid_input=$(printf '%q' "$answer")"
                ;;
        esac
    done
}

ensure_language() {
    # Priority: --lang > BSMF_LANG > saved file > prompt (system preselect) > system/en
    local current=""
    local sys_lang
    sys_lang="$(detect_system_lang)"
    if [[ -f "$TOOL_LANG_FILE" ]]; then
        current="$(tr -d '[:space:]' <"$TOOL_LANG_FILE" 2>/dev/null || true)"
    fi

    if [[ -n "$OPT_LANG" ]]; then
        if ! is_supported_lang "$OPT_LANG"; then
            die "Unsupported language: $OPT_LANG (use en|fr|es|de|sw)"
        fi
        if [[ "$current" == "$OPT_LANG" ]]; then
            UI_LANG="$OPT_LANG"
        else
            save_language "$OPT_LANG"
        fi
        return 0
    fi
    if [[ -n "${BSMF_LANG:-}" ]] && is_supported_lang "$BSMF_LANG"; then
        UI_LANG="$BSMF_LANG"
        # Persist quietly if no file yet or different
        if [[ "$current" != "$UI_LANG" && "$FLAG_DRY_RUN" -eq 0 ]]; then
            mkdir -p "$TOOL_DATA_DIR" 2>/dev/null || true
            printf '%s\n' "$UI_LANG" >"$TOOL_LANG_FILE" 2>/dev/null || true
            log_action OK "language_set=$UI_LANG (env)"
        fi
        debug "language from env: $UI_LANG"
        return 0
    fi
    if is_supported_lang "$current"; then
        UI_LANG="$current"
        debug "language from file: $UI_LANG"
        return 0
    fi
    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        UI_LANG="$sys_lang"
        log_action OK "language_default=$UI_LANG (system/non-interactive)"
        return 0
    fi
    prompt_language_selection
}

# =============================================================================
# Cleanup / temp / dry-run execution
# =============================================================================

cleanup() {
    local path
    [[ "$CLEANUP_DONE" -eq 1 ]] && return 0
    CLEANUP_DONE=1
    for path in "${TMP_PATHS[@]:-}"; do
        if [[ -n "$path" && -e "$path" ]]; then
            rm -rf -- "$path" 2>/dev/null || true
        fi
    done
}

_handle_interrupt() {
    warn "$(t err_interrupted 2>/dev/null || printf '%s' "Interrupted")"
    log_action FAIL "interrupted"
    cleanup
    # Exit 130 = classic SIGINT status; avoid nested die/exit races
    exit 130
}

trap cleanup EXIT
trap '_handle_interrupt' INT TERM

register_tmp() {
    TMP_PATHS+=("$1")
}

make_temp_dir() {
    mkdir -p "$TOOL_TMP_DIR"
    local d
    d="$(mktemp -d "$TOOL_TMP_DIR/tmp.XXXXXX")"
    register_tmp "$d"
    printf '%s\n' "$d"
}

make_temp_file() {
    mkdir -p "$TOOL_TMP_DIR"
    local f
    f="$(mktemp "$TOOL_TMP_DIR/file.XXXXXX")"
    register_tmp "$f"
    printf '%s\n' "$f"
}

run_cmd() {
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] $*"
        log_action DRY-RUN "$*"
        return 0
    fi
    debug "exec: $*"
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        log_action EXEC-OK "$*"
    else
        log_action EXEC-FAIL "rc=$rc $*"
    fi
    return "$rc"
}

is_safe_remove_path() {
    local path="${1:-}"
    local resolved
    [[ -z "$path" ]] && return 1
    [[ "$path" == "/" ]] && return 1
    [[ "$path" == "." || "$path" == ".." ]] && return 1
    [[ "$path" == "$HOME" ]] && return 1
    [[ "$path" == "$XDG_DATA_HOME" ]] && return 1
    [[ "$path" == "$XDG_CONFIG_HOME" ]] && return 1
    [[ "$path" == "$XDG_STATE_HOME" ]] && return 1
    [[ "$path" == "$LOCAL_BIN" ]] && return 1
    [[ "$path" == "$HOME/.local" ]] && return 1
    [[ "$path" == "$HOME/.local/opt" ]] && return 1
    [[ "$path" == "$HOME/.local/share" ]] && return 1

    if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath -m "$path" 2>/dev/null || true)"
    else
        resolved="$path"
    fi
    [[ -z "$resolved" || "$resolved" == "/" ]] && return 1
    [[ "$resolved" == "$HOME" ]] && return 1

    case "$resolved" in
        "$TOOL_DATA_DIR"|"$TOOL_DATA_DIR"/*) return 0 ;;
        "$TOOL_STATE_DIR"|"$TOOL_STATE_DIR"/*) return 0 ;;
        "$BSMANAGER_INSTALL_DIR"|"$BSMANAGER_INSTALL_DIR"/*) return 0 ;;
        "$LOCAL_BIN"/bsmanager-frame|"$LOCAL_BIN"/bs-manager|"$LOCAL_BIN"/beat-saber-*) return 0 ;;
        "$APPLICATIONS_DIR"/bs-manager.desktop|"$APPLICATIONS_DIR"/bsmanager-frame.desktop|"$APPLICATIONS_DIR"/beat-saber-*-modded.desktop) return 0 ;;
        "$BSMANAGER_CONFIG_DIR"|"$BSMANAGER_CONFIG_DIR"/*) return 0 ;;
        "$TOOL_TMP_DIR"|"$TOOL_TMP_DIR"/*) return 0 ;;
        "$TOOL_DATA_DIR"/backups|"$TOOL_DATA_DIR"/backups/*) return 0 ;;
        *) return 1 ;;
    esac
}

safe_rm() {
    local path="$1"
    if ! is_safe_remove_path "$path"; then
        die "Refusing to remove unsafe path: $path"
    fi
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] rm -rf -- $path"
        return 0
    fi
    rm -rf -- "$path"
}

# =============================================================================
# UI / prompts (pipe-safe via /dev/tty)
# =============================================================================
#
# IMPORTANT: when the script is run as `curl | bash`, stdin is the pipe — never
# read prompts from stdin. Always use /dev/tty.
# Values are returned on stdout (or via prompt_read → caller var) so we never
# rely on printf -v into a caller's `local` (fragile across bash builds).

BSMF_TTY_FD=""

have_tty() {
    # Permission bits are not enough: in CI /dev/tty exists, but open() fails
    # with ENXIO when the process has no controlling terminal.
    [[ -e /dev/tty ]] || return 1
    { : >/dev/tty; } 2>/dev/null || return 1
}

tty_open() {
    if [[ -n "${BSMF_TTY_FD:-}" ]]; then
        return 0
    fi
    have_tty || return 1
    # Open read+write FD to the controlling terminal
    if exec {BSMF_TTY_FD}<>/dev/tty 2>/dev/null; then
        return 0
    fi
    BSMF_TTY_FD=""
    return 1
}

tty_printf() {
    if [[ -n "${BSMF_TTY_FD:-}" ]]; then
        # shellcheck disable=SC2059
        printf "$@" >&"$BSMF_TTY_FD"
    else
        # shellcheck disable=SC2059
        printf "$@" >/dev/tty
    fi
}

normalize_reply() {
    local s="${1:-}"
    # Strip CR, then trim leading/trailing whitespace
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Prompt on TTY, print the reply to stdout (safe under curl|bash).
prompt_reply() {
    local prompt="$1"
    local default="${2:-}"
    local _bsmf_reply=""

    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        if [[ -n "$default" ]]; then
            printf '%s\n' "$default"
            return 0
        fi
        die "$(t prompt_need_value "$prompt")"
    fi

    if ! tty_open; then
        die "$(t prompt_no_tty)"
    fi

    if [[ -n "$default" ]]; then
        tty_printf '%s [%s]: ' "$prompt" "$default"
    else
        tty_printf '%s: ' "$prompt"
    fi

    if [[ -n "${BSMF_TTY_FD:-}" ]]; then
        IFS= read -r -u "$BSMF_TTY_FD" _bsmf_reply || true
    else
        IFS= read -r _bsmf_reply </dev/tty || true
    fi

    _bsmf_reply="$(normalize_reply "$_bsmf_reply")"
    if [[ -z "$_bsmf_reply" && -n "$default" ]]; then
        _bsmf_reply="$default"
    fi
    printf '%s\n' "$_bsmf_reply"
}

# Compatibility wrapper: set caller variable by name without printf -v.
prompt_read() {
    local prompt="$1"
    local varname="$2"
    local default="${3:-}"
    local _got=""
    _got="$(prompt_reply "$prompt" "$default")"
    # nameref assignment into caller scope (bash 4.3+)
    unset -n _bsmf_out 2>/dev/null || true
    local -n _bsmf_out="$varname"
    _bsmf_out="$_got"
}

prompt_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local answer=""

    if [[ "$FLAG_YES" -eq 1 && "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        return 0
    fi
    if [[ "$FLAG_YES" -eq 1 && "$FLAG_NON_INTERACTIVE" -eq 0 ]]; then
        return 0
    fi
    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        return 1
    fi

    answer="$(prompt_reply "$(t confirm_yn "$prompt")" "$default")"
    case "${answer,,}" in
        y|yes|o|oui|s|si|sí|j|ja|d|ndiyo) return 0 ;;
        *) return 1 ;;
    esac
}

# Destructive data question. Enter keeps the data. --yes does not answer it.
prompt_confirm_keep() {
    local prompt="$1"
    local answer=""
    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        return 1
    fi
    answer="$(prompt_reply "$(t confirm_yn "$prompt")" "n")"
    case "${answer,,}" in
        y|yes|o|oui|s|si|sí|j|ja|d|ndiyo) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_choice() {
    local prompt="$1"
    shift
    local -a options=("$@")
    local i answer=""
    local count="${#options[@]}"

    if [[ "$count" -eq 0 ]]; then
        die "No choices available for: $prompt"
    fi
    if [[ "$count" -eq 1 && "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        printf '%s\n' "${options[0]}"
        return 0
    fi
    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        error "$prompt — multiple options require an explicit selection:"
        for ((i = 0; i < count; i++)); do
            error "  - ${options[$i]}"
        done
        die "Re-run with an explicit option (for example --version / --compatdata)."
    fi

    tty_open || true
    tty_printf '%s\n' "$prompt"
    for ((i = 0; i < count; i++)); do
        tty_printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
    done
    while true; do
        answer="$(prompt_reply "$(t menu_select)" "")"
        if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= count)); then
            printf '%s\n' "${options[$((answer - 1))]}"
            return 0
        fi
        tty_printf '%s\n' "$(t menu_invalid)"
    done
}

# =============================================================================
# Network helpers
# =============================================================================

have_curl() { command -v curl >/dev/null 2>&1; }
have_wget() { command -v wget >/dev/null 2>&1; }

download_file() {
    local url="$1"
    local dest="$2"
    local extra_header="${3:-}"

    case "$url" in
        https://*) ;;
        *) die "Refusing non-HTTPS download URL: $url" ;;
    esac

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] download $url -> $dest"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    if have_curl; then
        local -a args=(-fsSL --retry 3 --retry-delay 2 -A "$USER_AGENT" -o "$dest")
        [[ -n "$extra_header" ]] && args+=(-H "$extra_header")
        if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
            args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        fi
        curl "${args[@]}" "$url"
        return $?
    fi
    if have_wget; then
        local -a wargs=(-q --tries=3 --timeout=30 -U "$USER_AGENT" -O "$dest")
        [[ -n "$extra_header" ]] && wargs+=(--header="$extra_header")
        if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
            wargs+=(--header="Authorization: Bearer ${GITHUB_TOKEN}")
        fi
        wget "${wargs[@]}" "$url"
        return $?
    fi
    die "Neither curl nor wget is available"
}

fetch_url_to_stdout() {
    local url="$1"
    local extra_header="${2:-}"

    case "$url" in
        https://*) ;;
        *) die "Refusing non-HTTPS URL: $url" ;;
    esac

    if have_curl; then
        local -a args=(-fsSL --retry 3 --retry-delay 2 -A "$USER_AGENT")
        [[ -n "$extra_header" ]] && args+=(-H "$extra_header")
        if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
            args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        fi
        curl "${args[@]}" "$url"
        return $?
    fi
    if have_wget; then
        local -a wargs=(-q --tries=3 --timeout=30 -U "$USER_AGENT" -O -)
        [[ -n "$extra_header" ]] && wargs+=(--header="$extra_header")
        if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
            wargs+=(--header="Authorization: Bearer ${GITHUB_TOKEN}")
        fi
        wget "${wargs[@]}" "$url"
        return $?
    fi
    die "Neither curl nor wget is available"
}

# =============================================================================
# Embedded Python helpers
# =============================================================================

require_python3() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required for this operation"
}

py_json_get() {
    # Usage: py_json_get <json-file-or--> <python-expr-on-data>
    require_python3
    local input="$1"
    local expr="$2"
    if [[ "$input" == "-" ]]; then
        python3 -c "
import json,sys
data=json.load(sys.stdin)
val=($expr)
if val is None:
    sys.exit(2)
if isinstance(val,(dict,list)):
    print(json.dumps(val))
else:
    print(val)
"
    else
        python3 -c "
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:
    data=json.load(f)
val=($expr)
if val is None:
    sys.exit(2)
if isinstance(val,(dict,list)):
    print(json.dumps(val))
else:
    print(val)
" "$input"
    fi
}

py_update_bsmanager_config() {
    # Args: config_path proton_folder [prefix_proton_folder]
    require_python3
    python3 - "$@" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
proton = sys.argv[2]
prefix = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

if not os.path.isfile(path):
    print("MISSING")
    sys.exit(3)

with open(path, encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    print("INVALID")
    sys.exit(4)

changed = False
if data.get("proton-folder") != proton:
    data["proton-folder"] = proton
    changed = True
if prefix is not None:
    if data.get("prefix-proton-folder") != prefix:
        data["prefix-proton-folder"] = prefix
        changed = True

if not changed:
    print("UNCHANGED")
    sys.exit(0)

dir_name = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix="bsm-config.", suffix=".json", dir=dir_name)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(data, out, indent=2, ensure_ascii=False)
        out.write("\n")
    # Validate
    with open(tmp, encoding="utf-8") as f:
        json.load(f)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        try:
            os.remove(tmp)
        except OSError:
            pass
print("UPDATED")
PY
}

py_natural_sort() {
    # Must use -c (not a heredoc): callers pipe version names on stdin.
    require_python3
    python3 -c 'import sys, re
items = [ln.rstrip("\n") for ln in sys.stdin if ln.strip()]
def key(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]
for i in sorted(items, key=key):
    print(i)
'
}

# =============================================================================
# Platform detection
# =============================================================================

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        aarch64|arm64) printf '%s\n' "$m" ;;
        *) printf '%s\n' "$m" ;;
    esac
}

is_arm64() {
    case "$(detect_arch)" in
        aarch64|arm64) return 0 ;;
        *) return 1 ;;
    esac
}

read_os_release_field() {
    local key="$1"
    local file="/etc/os-release"
    local line value
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "${key}="*)
                value="${line#*=}"
                value="${value#\"}"
                value="${value%\"}"
                value="${value#\'}"
                value="${value%\'}"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done <"$file"
    return 1
}

detect_steamos() {
    local name variant_id id
    name="$(read_os_release_field NAME 2>/dev/null || true)"
    variant_id="$(read_os_release_field VARIANT_ID 2>/dev/null || true)"
    id="$(read_os_release_field ID 2>/dev/null || true)"
    [[ "${name,,}" == *steamos* || "${id,,}" == steamos ]]
}

detect_steam_frame() {
    # Returns: confirmed | likely | unsupported
    local arch variant_id has_steamvr=0 is_steamos=0

    arch="$(detect_arch)"
    variant_id="$(read_os_release_field VARIANT_ID 2>/dev/null || true)"
    detect_steamos && is_steamos=1
    [[ -d /opt/steamvr ]] && has_steamvr=1

    if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
        printf 'unsupported\n'
        return 0
    fi

    if [[ "$is_steamos" -eq 1 && "$variant_id" == "vr" && "$has_steamvr" -eq 1 ]]; then
        printf 'confirmed\n'
        return 0
    fi
    if [[ "$is_steamos" -eq 1 && "$arch" == "aarch64" ]] || [[ "$is_steamos" -eq 1 && "$arch" == "arm64" ]]; then
        printf 'likely\n'
        return 0
    fi
    if [[ "$has_steamvr" -eq 1 && ( "$arch" == "aarch64" || "$arch" == "arm64" ) ]]; then
        printf 'likely\n'
        return 0
    fi
    printf 'unsupported\n'
}

assert_platform_or_force() {
    local status
    status="$(detect_steam_frame)"
    case "$status" in
        confirmed)
            success "$(t ok_steam_frame)"
            ;;
        likely)
            success "$(t ok_steam_likely)"
            ;;
        *)
            warn "$(t warn_unknown_platform "$(detect_arch)")"
            if [[ "$FLAG_FORCE" -ne 1 ]]; then
                if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
                    die "Unknown platform. Re-run with --force if you know what you are doing."
                fi
                if ! prompt_confirm "$(t ask_continue_platform)"; then
                    die "$(t aborted)"
                fi
            else
                warn "$(t continue_force)"
            fi
            ;;
    esac
}

# =============================================================================
# Steam detection
# =============================================================================

canonical_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$p" 2>/dev/null || printf '%s\n' "$p"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
    else
        printf '%s\n' "$p"
    fi
}

find_steam_root() {
    local -a candidates=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.steam/root"
    )
    local c resolved
    for c in "${candidates[@]}"; do
        if [[ -d "$c" ]]; then
            resolved="$(canonical_path "$c")"
            if [[ -d "$resolved/steamapps" || -f "$resolved/steam.sh" || -d "$resolved/ubuntu12_32" ]]; then
                printf '%s\n' "$resolved"
                return 0
            fi
            if [[ -d "$resolved" ]]; then
                printf '%s\n' "$resolved"
                return 0
            fi
        fi
    done
    return 1
}

steam_is_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x steam >/dev/null 2>&1 && return 0
        pgrep -f '[S]team/ubuntu12_32/steam' >/dev/null 2>&1 && return 0
    fi
    if [[ -S "$XDG_RUNTIME_DIR/steam/steam.pipe" ]] 2>/dev/null; then
        return 0
    fi
    return 1
}

parse_library_folders() {
    local steam_root="$1"
    local vdf="$steam_root/steamapps/libraryfolders.vdf"
    local -A seen=()
    local path

    path="$(canonical_path "$steam_root")"
    seen["$path"]=1
    printf '%s\n' "$path"

    [[ -f "$vdf" ]] || return 0

    # Extract path" "..." entries without inventing a full VDF parser.
    while IFS= read -r line; do
        if [[ "$line" =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
            path="${BASH_REMATCH[1]}"
            path="${path//\\\\/\/}"
            if [[ -d "$path" ]]; then
                path="$(canonical_path "$path")"
                if [[ -z "${seen[$path]:-}" ]]; then
                    seen["$path"]=1
                    printf '%s\n' "$path"
                fi
            fi
        fi
    done <"$vdf"
}

list_steam_libraries() {
    local root
    root="$(find_steam_root)" || return 1
    parse_library_folders "$root"
}

# =============================================================================
# Steam app manifests
# =============================================================================

find_appmanifest() {
    local appid="$1"
    local lib manifest
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        manifest="$lib/steamapps/appmanifest_${appid}.acf"
        if [[ -f "$manifest" ]]; then
            printf '%s\n' "$manifest"
            return 0
        fi
    done < <(list_steam_libraries)
    return 1
}

acf_get() {
    local file="$1"
    local key="$2"
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ \"$key\"[[:space:]]+\"([^\"]*)\" ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$file"
    return 1
}

resolve_app_install_path() {
    local appid="$1"
    local manifest lib installdir
    manifest="$(find_appmanifest "$appid")" || return 1
    lib="$(dirname "$(dirname "$manifest")")"
    installdir="$(acf_get "$manifest" installdir)" || return 1
    [[ -n "$installdir" ]] || return 1
    printf '%s\n' "$lib/steamapps/common/$installdir"
}

# =============================================================================
# Proton management
# =============================================================================

proton_has_binary() {
    local root="$1"
    [[ -f "$root/proton" && -x "$root/proton" ]] || [[ -f "$root/proton" ]]
}

proton_has_arm64_wine() {
    local root="$1"
    [[ -e "$root/files/bin-arm64/wine" ]]
}

proton_wine_layout_summary() {
    local root="$1"
    local -a found=()
    [[ -e "$root/files/bin-arm64/wine" ]] && found+=("files/bin-arm64/wine")
    [[ -e "$root/files/bin/wine64" ]] && found+=("files/bin/wine64")
    [[ -e "$root/files/lib/wine/x86_64-unix/wine64" ]] && found+=("files/lib/wine/x86_64-unix/wine64")
    if [[ "${#found[@]}" -eq 0 ]]; then
        printf 'none\n'
    else
        local IFS=','
        printf '%s\n' "${found[*]}"
    fi
}

validate_proton_install() {
    local root="$1"
    local label="${2:-Proton}"
    if [[ ! -d "$root" ]]; then
        error "$label path missing: $root"
        return 1
    fi
    if ! proton_has_binary "$root"; then
        error "$label missing proton launcher: $root/proton"
        return 1
    fi
    if is_arm64; then
        if ! proton_has_arm64_wine "$root"; then
            error "$label missing ARM64 wine: $root/files/bin-arm64/wine"
            return 1
        fi
    else
        local layout
        layout="$(proton_wine_layout_summary "$root")"
        if [[ "$layout" == "none" ]]; then
            error "$label has no recognized wine binary"
            return 1
        fi
    fi
    return 0
}

# Positive integer in [min, max], or the fallback. Returns 1 when the input was invalid.
steam_bounded_seconds() {
    local raw="$1"
    local fallback="$2"
    local min="$3"
    local max="$4"
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( 10#$raw >= min && 10#$raw <= max )); then
        printf '%s\n' "$((10#$raw))"
        return 0
    fi
    printf '%s\n' "$fallback"
    return 1
}

steam_poll_seconds() {
    steam_bounded_seconds "${BSMF_STEAM_POLL_INTERVAL:-${STEAM_POLL_INTERVAL:-2}}" 2 1 60
}

steam_timeout_seconds() {
    steam_bounded_seconds "${BSMF_STEAM_INSTALL_TIMEOUT:-${STEAM_INSTALL_TIMEOUT:-900}}" 900 1 86400
}

# Human-readable byte size. numfmt is optional.
steam_format_bytes() {
    local n="$1"
    local out=""
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        printf '%s' "?"
        return 0
    fi
    if command -v numfmt >/dev/null 2>&1; then
        if out="$(numfmt --to=iec-i --suffix=B --format='%.2f' "$n" 2>/dev/null)"; then
            printf '%s' "$out"
            return 0
        fi
    fi
    awk -v n="$n" 'BEGIN {
        split("B KiB MiB GiB TiB", units, " ")
        i = 1
        v = n + 0
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        if (i == 1) printf "%d %s", v, units[i]
        else printf "%.2f %s", v, units[i]
    }'
}

# Fully Installed is bit value 4. Steam may OR it with other flags.
steam_state_fully_installed() {
    local state="$1"
    local downloaded="${2:-}"
    local total="${3:-}"
    [[ "$state" =~ ^[0-9]+$ ]] || return 1
    (( (10#$state & 4) != 0 )) || return 1
    if [[ "$downloaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$total" != "0" ]]; then
        awk -v d="$downloaded" -v t="$total" 'BEGIN { exit !((d + 0) >= (t + 0)) }' || return 1
    fi
    return 0
}

# Read StateFlags, BytesDownloaded, BytesToDownload, installdir.
# A missing or half-written manifest is not fatal; the caller retries.
steam_read_manifest_state() {
    local file="$1"
    local state="" downloaded="" total="" installdir=""
    [[ -f "$file" ]] || return 1
    state="$(acf_get "$file" StateFlags 2>/dev/null || true)"
    downloaded="$(acf_get "$file" BytesDownloaded 2>/dev/null || true)"
    total="$(acf_get "$file" BytesToDownload 2>/dev/null || true)"
    installdir="$(acf_get "$file" installdir 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "$state" "$downloaded" "$total" "$installdir"
}

steam_manifest_snapshot() {
    local appid="$1"
    local manifest="" state="" downloaded=""
    manifest="$(find_appmanifest "$appid" 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
        printf 'absent\t\t\n'
        return 0
    fi
    state="$(acf_get "$manifest" StateFlags 2>/dev/null || true)"
    downloaded="$(acf_get "$manifest" BytesDownloaded 2>/dev/null || true)"
    printf 'present\t%s\t%s\n' "$state" "$downloaded"
}

steam_component_files_ok() {
    local appid="$1"
    local path="$2"
    [[ -n "$path" && -d "$path" ]] || return 1
    case "$appid" in
        "$PROTON_STABLE_APPID"|"$PROTON_EXPERIMENTAL_APPID")
            proton_has_binary "$path" || return 1
            if is_arm64; then
                proton_has_arm64_wine "$path"
            else
                [[ "$(proton_wine_layout_summary "$path")" != "none" ]]
            fi
            ;;
        *)
            [[ -d "$path" ]]
            ;;
    esac
}

steam_app_is_ready() {
    local appid="$1"
    local path="" manifest="" row="" state="" downloaded="" total=""
    path="$(resolve_app_install_path "$appid" 2>/dev/null || true)"
    [[ -n "$path" ]] || return 1
    steam_component_files_ok "$appid" "$path" || return 1
    manifest="$(find_appmanifest "$appid" 2>/dev/null || true)"
    [[ -n "$manifest" ]] || return 1
    row="$(steam_read_manifest_state "$manifest" 2>/dev/null || true)"
    IFS=$'\t' read -r state downloaded total _ <<<"${row:-}" || true
    steam_state_fully_installed "$state" "$downloaded" "$total"
}

steam_report_validated_files() {
    local appid="$1"
    local label="$2"
    local path="$3"
    case "$appid" in
        "$PROTON_STABLE_APPID"|"$PROTON_EXPERIMENTAL_APPID")
            success "$(t steam_ok_file "proton")"
            if [[ -e "$path/files/bin-arm64/wine" ]]; then
                success "$(t steam_ok_file "files/bin-arm64/wine")"
            fi
            ;;
        *)
            success "$(t steam_ok_file "$label")"
            ;;
    esac
    log_action OK "steam_component_validated appid=$appid"
}

steam_status_line() {
    local msg="$1"
    have_tty || return 0
    printf '\r\033[K%s' "$msg" >/dev/tty 2>/dev/null || true
}

steam_status_finish() {
    have_tty || return 0
    printf '\r\033[K' >/dev/tty 2>/dev/null || true
}

request_steam_install() {
    local appid="$1"
    local label="$2"
    local uri="steam://install/${appid}"

    # Validated on a real Steam Frame: `steam "steam://install/<appid>"` is
    # forwarded to the headset's already-running Steam client, which shows
    # the confirmation inside VR. AppID 431960 was only that test application,
    # not a dependency of this helper.
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would request Steam installation: $label, AppID $appid"
        return 0
    fi

    info "$(t steam_not_installed "$label")"
    info "$(t steam_requesting)"
    log_action OK "steam_install_requested appid=$appid uri=$uri"
    if command -v steam >/dev/null 2>&1; then
        steam "$uri" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$uri" >/dev/null 2>&1 || true
    else
        warn "Neither steam nor xdg-open found. Open this URI manually: $uri"
    fi
    info "$(t steam_request_sent)"
    info "$(t steam_confirm_headset)"
}

# Wait for VR confirmation, download, and real files. Prints the install path.
# baseline_kind is "absent" or "present" from the snapshot taken before the URI.
monitor_steam_install() {
    local appid="$1"
    local label="$2"
    local baseline_kind="${3:-absent}"
    local baseline_state="${4:-}"
    local baseline_bytes="${5:-}"
    local timeout poll elapsed=0
    local manifest="" row="" state="" downloaded="" total="" installdir=""
    local path="" pct="" bucket="" msg="" changed=0
    local announced_manifest=0 announced_download=0 announced_complete=0
    local last_bucket=-1

    if ! poll="$(steam_poll_seconds)"; then
        warn "Invalid BSMF_STEAM_POLL_INTERVAL; using ${poll}s"
    fi
    if ! timeout="$(steam_timeout_seconds)"; then
        warn "Invalid BSMF_STEAM_INSTALL_TIMEOUT; using ${timeout}s"
    fi
    log_action OK "steam_waiting_activity appid=$appid timeout=${timeout}s poll=${poll}s"

    while (( elapsed < timeout )); do
        manifest="$(find_appmanifest "$appid" 2>/dev/null || true)"
        if [[ -z "$manifest" ]]; then
            steam_status_line "$(t steam_waiting_headset "$elapsed")"
            sleep "$poll" || true
            elapsed=$((elapsed + poll))
            continue
        fi

        row="$(steam_read_manifest_state "$manifest" 2>/dev/null || true)"
        state="" downloaded="" total="" installdir=""
        IFS=$'\t' read -r state downloaded total installdir <<<"${row:-}" || true
        path="$(resolve_app_install_path "$appid" 2>/dev/null || true)"

        changed=0
        if [[ "$baseline_kind" != "present" ]]; then
            changed=1
        elif [[ "$state" != "$baseline_state" || "$downloaded" != "$baseline_bytes" ]]; then
            changed=1
        fi

        if steam_state_fully_installed "$state" "$downloaded" "$total"; then
            if [[ "$announced_complete" -eq 0 ]]; then
                steam_status_finish
                info "$(t steam_reports_complete)"
                info "$(t steam_validating "$label")"
                log_action OK "steam_reports_fully_installed appid=$appid state=${state:-missing}"
                announced_complete=1
            fi
            if [[ -n "$path" ]] && steam_component_files_ok "$appid" "$path"; then
                steam_status_finish
                steam_report_validated_files "$appid" "$label" "$path"
                printf '%s\n' "$path"
                return 0
            fi
        else
            if [[ "$announced_manifest" -eq 0 && "$changed" -eq 1 ]]; then
                steam_status_finish
                info "$(t steam_install_detected)"
                log_action OK "steam_manifest_activity appid=$appid installdir=${installdir:-unknown}"
                announced_manifest=1
            fi
            if [[ "$downloaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$total" != "0" ]]; then
                pct="$(awk -v d="$downloaded" -v t="$total" 'BEGIN { printf "%.1f", (d + 0) * 100 / (t + 0) }')"
                bucket="${pct%%.*}"
                bucket=$((10#$bucket / 10))
                msg="$(t steam_downloading "$label" "$(steam_format_bytes "$downloaded")" "$(steam_format_bytes "$total")" "$pct")"
                steam_status_line "$msg"
                if [[ "$announced_download" -eq 0 && "$changed" -eq 1 ]]; then
                    log_action OK "steam_download_started appid=$appid"
                    announced_download=1
                fi
                if [[ "$changed" -eq 1 && "$bucket" != "$last_bucket" ]]; then
                    log_action OK "steam_download_progress appid=$appid pct=$pct"
                    last_bucket="$bucket"
                    if ! have_tty; then
                        info "$msg"
                    fi
                fi
            else
                steam_status_line "$(t steam_in_progress)"
                if [[ "$announced_download" -eq 0 && "$changed" -eq 1 ]]; then
                    log_action OK "steam_install_in_progress appid=$appid"
                    announced_download=1
                    if ! have_tty; then
                        info "$(t steam_in_progress)"
                    fi
                fi
            fi
        fi

        sleep "$poll" || true
        elapsed=$((elapsed + poll))
    done

    steam_status_finish
    if [[ "$announced_complete" -eq 1 ]]; then
        error "$(t steam_files_missing "$label")"
        log_action FAIL "steam_validation_failed appid=$appid"
        if [[ "$appid" == "$PROTON_STABLE_APPID" || "$appid" == "$PROTON_EXPERIMENTAL_APPID" ]]; then
            if [[ -n "$path" ]]; then
                validate_proton_install "$path" "$label" || true
            fi
        fi
        return 1
    fi
    error "$(t steam_timeout)"
    info "$(t steam_left_running)"
    log_action FAIL "steam_install_timeout appid=$appid"
    return 1
}

ensure_steam_app() {
    local appid="$1"
    local label="$2"
    local path="" snap="" baseline_kind="" baseline_state="" baseline_bytes=""

    if steam_app_is_ready "$appid"; then
        path="$(resolve_app_install_path "$appid")"
        success "$(t steam_already "$label")"
        log_action OK "steam_already_installed appid=$appid"
        printf '%s\n' "$path"
        return 0
    fi

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would request Steam installation: $label, AppID $appid"
        log_action OK "steam_install_dry_run appid=$appid"
        return 2
    fi

    # --yes and --non-interactive authorize this helper to send the URI.
    # They do not bypass Steam's own headset confirmation or file validation.
    if [[ "$FLAG_NON_INTERACTIVE" -eq 0 && "$FLAG_YES" -ne 1 ]]; then
        if ! prompt_confirm "$(t ask_steam_install "$label")"; then
            die "Cannot continue without $label"
        fi
    fi

    if steam_is_running; then
        debug "Steam appears to be running; will not restart it"
    else
        warn "Steam does not appear to be running; install URI may queue until Steam starts"
    fi

    snap="$(steam_manifest_snapshot "$appid")"
    IFS=$'\t' read -r baseline_kind baseline_state baseline_bytes <<<"$snap" || true
    request_steam_install "$appid" "$label"
    monitor_steam_install "$appid" "$label" "$baseline_kind" "$baseline_state" "$baseline_bytes"
}

ensure_required_proton_stack() {
    local runtime_path="" proton_path="" experimental_path=""
    local rc=0

    # One component at a time. After each install, the next check can see a
    # dependency Steam pulled in (Proton often installs the ARM64 runtime).
    rc=0
    proton_path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL")" || rc=$?
    if [[ "$rc" -eq 2 && "$FLAG_DRY_RUN" -eq 1 ]]; then
        proton_path=""
    elif [[ "$rc" -ne 0 ]]; then
        return 1
    else
        validate_proton_install "$proton_path" "$PROTON_STABLE_LABEL" || return 1
    fi

    rc=0
    experimental_path="$(ensure_steam_app "$PROTON_EXPERIMENTAL_APPID" "$PROTON_EXPERIMENTAL_LABEL")" || rc=$?
    if [[ "$rc" -eq 2 && "$FLAG_DRY_RUN" -eq 1 ]]; then
        experimental_path=""
    elif [[ "$rc" -ne 0 ]]; then
        return 1
    else
        validate_proton_install "$experimental_path" "$PROTON_EXPERIMENTAL_LABEL" || return 1
    fi

    rc=0
    runtime_path="$(ensure_steam_app "$STEAM_RUNTIME_ARM64_APPID" "$STEAM_RUNTIME_LABEL")" || rc=$?
    if [[ "$rc" -eq 2 && "$FLAG_DRY_RUN" -eq 1 ]]; then
        runtime_path=""
    elif [[ "$rc" -ne 0 ]]; then
        return 1
    fi

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Steam install URIs were not sent"
    fi
    success "Proton stack validated"
    printf '%s\n%s\n%s\n' "$runtime_path" "$proton_path" "$experimental_path"
}

# =============================================================================
# BSManager management
# =============================================================================

ensure_user_dirs() {
    run_cmd mkdir -p "$LOCAL_BIN" "$TOOL_DATA_DIR" "$TOOL_STATE_DIR" "$TOOL_TMP_DIR" \
        "$BSMANAGER_DATA_DIR" "$APPLICATIONS_DIR" "$HOME/.local/opt"
}

is_bsmanager_native_installed() {
    [[ -x "$BSMANAGER_INSTALL_DIR/bs-manager" ]] || return 1
    is_arm64_elf "$BSMANAGER_INSTALL_DIR/bs-manager"
}

is_bsmanager_flatpak_user_installed() {
    command -v flatpak >/dev/null 2>&1 || return 1
    flatpak info --user "$FLATPAK_APP_ID_EXPECTED" >/dev/null 2>&1
}

is_bsmanager_flatpak_system_installed() {
    command -v flatpak >/dev/null 2>&1 || return 1
    flatpak info --system "$FLATPAK_APP_ID_EXPECTED" >/dev/null 2>&1
}

# Returns: native | flatpak-user | flatpak-system | native+flatpak | none | unknown
detect_bsmanager_installation_type() {
    local native=0 fu=0 fs=0
    is_bsmanager_native_installed && native=1
    is_bsmanager_flatpak_user_installed && fu=1
    is_bsmanager_flatpak_system_installed && fs=1

    if [[ "$native" -eq 1 && ( "$fu" -eq 1 || "$fs" -eq 1 ) ]]; then
        printf 'native+flatpak\n'
        return 0
    fi
    if [[ "$native" -eq 1 ]]; then
        printf 'native\n'
        return 0
    fi
    if [[ "$fu" -eq 1 && "$fs" -eq 1 ]]; then
        # Both Flatpak scopes without native — diagnose expands details
        printf 'unknown\n'
        return 0
    fi
    if [[ "$fu" -eq 1 ]]; then
        printf 'flatpak-user\n'
        return 0
    fi
    if [[ "$fs" -eq 1 ]]; then
        printf 'flatpak-system\n'
        return 0
    fi
    if command -v bs-manager >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi
    printf 'none\n'
}

# Backward-compatible alias used by older call sites
bsmanager_install_type() {
    detect_bsmanager_installation_type
}

warn_bsmanager_duplicate_installations() {
    local itype
    itype="$(detect_bsmanager_installation_type)"
    if [[ "$itype" == "native+flatpak" ]]; then
        warn "$(t bsm_dup_warn)"
        log_action WARN "bsmanager_duplicate native+flatpak"
        return 0
    fi
    if is_bsmanager_flatpak_user_installed && is_bsmanager_flatpak_system_installed; then
        warn "Flatpak user and system BSManager installations both present"
        log_action WARN "bsmanager_duplicate flatpak-user+flatpak-system"
    fi
}

is_bsmanager_running() {
    local pid exe cmdline want
    want="$(canonical_path "$BSMANAGER_INSTALL_DIR/bs-manager" 2>/dev/null || printf '%s' "$BSMANAGER_INSTALL_DIR/bs-manager")"

    if [[ -x "$BSMANAGER_INSTALL_DIR/bs-manager" ]]; then
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
            if [[ -n "$exe" && "$exe" == "$want" ]]; then
                return 0
            fi
            cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
            if [[ "$cmdline" == *"$BSMANAGER_INSTALL_DIR/bs-manager"* ]]; then
                return 0
            fi
        done < <(pgrep -x "bs-manager" 2>/dev/null || true)
    fi

    if command -v flatpak >/dev/null 2>&1; then
        if flatpak ps 2>/dev/null | grep -F "$FLATPAK_APP_ID_EXPECTED" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Returns: supported | unsupported | unknown
bsmanager_supports_prefix_proton() {
    local hit="" asar candidate
    local -a search_roots=()

    if [[ -d "$BSMANAGER_INSTALL_DIR" ]]; then
        search_roots+=("$BSMANAGER_INSTALL_DIR")
    fi

    # Flatpak exported files (user then system), if present
    for candidate in \
        "$HOME/.local/share/flatpak/app/${FLATPAK_APP_ID_EXPECTED}/current/active/files" \
        "/var/lib/flatpak/app/${FLATPAK_APP_ID_EXPECTED}/current/active/files"; do
        [[ -d "$candidate" ]] && search_roots+=("$candidate")
    done

    if [[ "${#search_roots[@]}" -eq 0 ]]; then
        printf 'unknown\n'
        return 0
    fi

    for candidate in "${search_roots[@]}"; do
        asar="$candidate/resources/app.asar"
        if [[ -f "$asar" ]]; then
            if grep -a -F -q 'prefix-proton-folder' "$asar" 2>/dev/null; then
                printf 'supported\n'
                return 0
            fi
            # asar present but token missing → unsupported for this install
            printf 'unsupported\n'
            return 0
        fi
    done

    # Fallback: scan install tree for the token (avoid requiring asar tooling)
    for candidate in "${search_roots[@]}"; do
        hit="$(grep -aRlm 1 -F -- 'prefix-proton-folder' "$candidate" 2>/dev/null || true)"
        if [[ -n "$hit" ]]; then
            printf 'supported\n'
            return 0
        fi
    done

    # Resources exist but no token found
    for candidate in "${search_roots[@]}"; do
        if [[ -d "$candidate/resources" || -f "$candidate/bs-manager" ]]; then
            printf 'unsupported\n'
            return 0
        fi
    done

    printf 'unknown\n'
}

config_has_prefix_proton_key() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 1
    require_python3
    python3 -c '
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    data=json.load(f)
sys.exit(0 if isinstance(data,dict) and "prefix-proton-folder" in data else 1)
' "$cfg" 2>/dev/null
}

file_arch_of() {
    local bin="$1"
    if command -v file >/dev/null 2>&1; then
        file -b "$bin" 2>/dev/null || true
    else
        printf 'unknown\n'
    fi
}

is_arm64_elf() {
    local bin="$1"
    local info
    info="$(file_arch_of "$bin")"
    [[ "$info" == *ARM\ aarch64* || "$info" == *aarch64* || "$info" == *ARM64* || "$info" == *arm64* ]]
}

find_bs_manager_binary() {
    local root="$1"
    local candidate
    if [[ -x "$root/bs-manager" ]]; then
        printf '%s\n' "$root/bs-manager"
        return 0
    fi
    candidate="$(find "$root" -type f -name 'bs-manager' -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

extract_archive() {
    local archive="$1"
    local dest="$2"
    mkdir -p "$dest"
    case "$archive" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *.tar.xz)
            tar -xJf "$archive" -C "$dest"
            ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -q "$archive" -d "$dest"
            else
                die "unzip is required to extract .zip archives"
            fi
            ;;
        *)
            die "Unsupported archive format: $archive"
            ;;
    esac
}

prune_backups() {
    local dir="$1"
    local keep="$2"
    [[ -d "$dir" ]] || return 0
    local -a entries=()
    mapfile -t entries < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    local i
    for ((i = keep; i < ${#entries[@]}; i++)); do
        safe_rm "${entries[$i]}"
    done
}

install_native_bsmanager_from_dir() {
    local src_root="$1"
    local provenance_src="${2:-}"
    local bin backup_dir stamp dest_tmp

    bin="$(find_bs_manager_binary "$src_root")" || die "bs-manager executable not found in $src_root"
    if ! is_arm64_elf "$bin"; then
        die "Refusing to install non-ARM64 bs-manager binary ($(file_arch_of "$bin"))"
    fi

    stamp="$(date +%Y%m%dT%H%M%S)"
    backup_dir="$TOOL_DATA_DIR/backups/bsmanager/$stamp"
    dest_tmp="$(make_temp_dir)/bs-manager-new"

    run_cmd mkdir -p "$dest_tmp"
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] install native BSManager from $src_root"
        return 0
    fi

    # Copy tree preserving structure relative to binary parent if needed
    local copy_root
    copy_root="$(dirname "$bin")"
    # If binary is nested, prefer top-level extracted directory that contains it
    if [[ "$(basename "$copy_root")" != "bs-manager" ]] && [[ -d "$src_root" ]]; then
        # Use directory containing the binary as install payload
        :
    fi
    cp -a "$copy_root"/. "$dest_tmp"/
    chmod +x "$dest_tmp/bs-manager" 2>/dev/null || chmod +x "$(find_bs_manager_binary "$dest_tmp")"

    bin="$(find_bs_manager_binary "$dest_tmp")" || die "Post-copy bs-manager missing"
    if ! is_arm64_elf "$bin"; then
        die "Post-copy architecture validation failed"
    fi
    if [[ -n "$provenance_src" ]]; then
        [[ -f "$provenance_src" ]] || die "Provenance file missing: $provenance_src"
        [[ -f "$dest_tmp/resources/app.asar" ]] || die "Staged BSManager is missing resources/app.asar"
        cp -a "$provenance_src" "$dest_tmp/$BSMANAGER_PROVENANCE_NAME"
    fi

    if [[ -d "$BSMANAGER_INSTALL_DIR" ]]; then
        mkdir -p "$(dirname "$backup_dir")"
        info "Backing up existing BSManager app to $backup_dir"
        cp -a "$BSMANAGER_INSTALL_DIR" "$backup_dir"
    fi

    local swap="$BSMANAGER_INSTALL_DIR.new.$$"
    local old="$BSMANAGER_INSTALL_DIR.old.$$"
    rm -rf "$swap" "$old" 2>/dev/null || true
    mv "$dest_tmp" "$swap"
    if [[ -d "$BSMANAGER_INSTALL_DIR" ]]; then
        mv "$BSMANAGER_INSTALL_DIR" "$old"
    fi
    if ! mv "$swap" "$BSMANAGER_INSTALL_DIR"; then
        error "Failed to replace BSManager install dir; restoring"
        [[ -d "$old" ]] && mv "$old" "$BSMANAGER_INSTALL_DIR"
        die "BSManager install failed"
    fi
    rm -rf "$old" 2>/dev/null || true

    mkdir -p "$LOCAL_BIN"
    ln -sfn "$BSMANAGER_INSTALL_DIR/bs-manager" "$BSMANAGER_BIN"
    chmod +x "$BSMANAGER_INSTALL_DIR/bs-manager" || true
    mkdir -p "$BSMANAGER_DATA_DIR"
    prune_backups "$TOOL_DATA_DIR/backups/bsmanager" "$BACKUP_KEEP_COUNT"
    success "BSManager native ARM64: installed ($BSMANAGER_INSTALL_DIR)"
}

fetch_bsmanager_frame_releases_json() {
    local out="$1"
    local saved_dry="$FLAG_DRY_RUN"
    local rc=0
    # Metadata fetch is read-only; do it even during --dry-run.
    FLAG_DRY_RUN=0
    download_file \
        "https://api.github.com/repos/${BSMANAGER_FRAME_RELEASE_REPO}/releases?per_page=30" \
        "$out" \
        "Accept: application/vnd.github+json" || rc=$?
    FLAG_DRY_RUN="$saved_dry"
    return "$rc"
}

download_bsmanager_frame_asset() {
    local url="$1"
    local dest="$2"
    local saved_dry="$FLAG_DRY_RUN"
    local rc=0
    FLAG_DRY_RUN=0
    download_file "$url" "$dest" || rc=$?
    FLAG_DRY_RUN="$saved_dry"
    return "$rc"
}

select_latest_bsmanager_frame_release() {
    local json_path="$1"
    require_python3
    python3 - "$json_path" \
        "$BSMANAGER_FRAME_RELEASE_TAG_PREFIX" \
        "$BSMANAGER_FRAME_ARCHIVE" \
        "$BSMANAGER_FRAME_CHECKSUMS" \
        "$BSMANAGER_FRAME_BUILD_INFO" <<'PY'
import json, sys

path, prefix, archive_name, sums_name, info_name = sys.argv[1:6]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(json.dumps({"ok": False, "error": "malformed", "detail": str(exc)}))
    sys.exit(0)

if isinstance(data, dict):
    print(json.dumps({
        "ok": False,
        "error": "api_error",
        "detail": str(data.get("message") or "unexpected object"),
    }))
    sys.exit(0)
if not isinstance(data, list):
    print(json.dumps({"ok": False, "error": "malformed", "detail": "releases payload is not a list"}))
    sys.exit(0)

def asset_url(rel, name):
    for asset in rel.get("assets") or []:
        if asset.get("name") == name and asset.get("browser_download_url"):
            return asset["browser_download_url"]
    return ""

candidates = []
for rel in data:
    if not isinstance(rel, dict) or rel.get("draft"):
        continue
    tag = rel.get("tag_name") or ""
    if not tag.startswith(prefix):
        continue
    archive = asset_url(rel, archive_name)
    checksums = asset_url(rel, sums_name)
    info = asset_url(rel, info_name)
    if not (archive and checksums and info):
        continue
    candidates.append(rel)

candidates.sort(key=lambda rel: rel.get("published_at") or "", reverse=True)
if not candidates:
    print(json.dumps({"ok": False, "error": "no_valid_release"}))
    sys.exit(0)

rel = candidates[0]
print(json.dumps({
    "ok": True,
    "tag_name": rel.get("tag_name") or "",
    "release_name": rel.get("name") or "",
    "published_at": rel.get("published_at") or "",
    "archive_url": asset_url(rel, archive_name),
    "checksums_url": asset_url(rel, sums_name),
    "build_info_url": asset_url(rel, info_name),
}))
PY
}

_bsm_json_field() {
    local file="$1"
    local key="$2"
    python3 -c 'import json,sys
data=json.load(open(sys.argv[1], encoding="utf-8"))
val=data.get(sys.argv[2], "")
if val is None:
    val=""
if isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
' "$file" "$key"
}

validate_bsmanager_frame_build_info() {
    local path="$1"
    local reason=""
    require_python3
    if ! reason="$(python3 - "$path" \
        "$BSMANAGER_FRAME_RELEASE_REPO" \
        "$BSMANAGER_FRAME_SOURCE_BRANCH" \
        "$BSMANAGER_FRAME_ARCHIVE" <<'PY'
import json, re, sys
path, repo, branch, artifact = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print("malformed:%s" % exc)
    sys.exit(1)
if not isinstance(data, dict):
    print("not-an-object")
    sys.exit(1)
errors = []
if data.get("source_repository") != repo:
    errors.append("source_repository")
if data.get("source_branch") != branch:
    errors.append("source_branch")
arch = str(data.get("architecture") or "").lower()
if arch not in ("aarch64", "arm64"):
    errors.append("architecture")
if data.get("artifact") != artifact:
    errors.append("artifact")
commit = str(data.get("source_commit") or "")
if not re.fullmatch(r"[0-9a-fA-F]{7,64}", commit):
    errors.append("source_commit")
if "project" in data and data.get("project") != "BSManager":
    errors.append("project")
if "distribution" in data and "steam frame" not in str(data.get("distribution") or "").lower():
    errors.append("distribution")
if errors:
    print(",".join(errors))
    sys.exit(1)
print(commit)
PY
)"; then
        error "$(t bsm_sf_bad_build_info "${reason:-invalid}")"
        return 1
    fi
    printf '%s\n' "$reason"
}

validate_bsmanager_frame_checksum() {
    local archive="$1"
    local sums="$2"
    local reason=""
    require_python3
    if ! reason="$(python3 - "$BSMANAGER_FRAME_ARCHIVE" "$sums" "$archive" <<'PY'
import hashlib, sys
wanted, sums_path, archive = sys.argv[1:4]
expected = ""
with open(sums_path, encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        digest, name = parts[0], parts[-1].lstrip("*")
        base = name.replace("\\", "/").split("/")[-1]
        if base == wanted:
            expected = digest.lower()
            break
if not expected or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
    print("missing-or-invalid-entry")
    sys.exit(1)
hasher = hashlib.sha256()
with open(archive, "rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        hasher.update(chunk)
actual = hasher.hexdigest()
if actual != expected:
    print("mismatch")
    sys.exit(1)
print("ok")
PY
)"; then
        error "$(t bsm_sf_bad_checksum "$BSMANAGER_FRAME_ARCHIVE")"
        return 1
    fi
    return 0
}

validate_bsmanager_frame_archive() {
    local archive="$1"
    local reason=""
    require_python3
    # Names alone miss symlink and hardlink escapes such as
    # bs-manager/foo -> ../../outside. Link targets must stay under bs-manager/.
    if ! reason="$(python3 - "$archive" <<'PY'
import sys, tarfile

archive = sys.argv[1]

def split_rel(path):
    path = (path or "").replace("\\", "/")
    if path.startswith("/") or (len(path) > 2 and path[1] == ":"):
        return None
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return parts

def under_bundle(parts):
    return bool(parts) and parts[0] == "bs-manager"

def resolve_symlink(member_parts, linkname):
    linkname = (linkname or "").replace("\\", "/")
    if not linkname or linkname.startswith("/") or (len(linkname) > 2 and linkname[1] == ":"):
        return None
    base = list(member_parts[:-1])
    for part in linkname.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not base:
                return None
            base.pop()
        else:
            base.append(part)
    return base

try:
    tf = tarfile.open(archive, "r:*")
except Exception:
    print("unreadable")
    sys.exit(1)

found_exe = False
with tf:
    members = tf.getmembers()
    if not members:
        print("empty")
        sys.exit(1)
    for member in members:
        parts = split_rel(member.name)
        if not under_bundle(parts):
            print("path-escape" if parts is None else "not-rooted")
            sys.exit(1)
        if "/".join(parts) == "bs-manager/bs-manager":
            found_exe = True
        if member.issym():
            if not under_bundle(resolve_symlink(parts, member.linkname)):
                print("link-escape")
                sys.exit(1)
        elif member.islnk():
            if not under_bundle(split_rel(member.linkname or "")):
                print("link-escape")
                sys.exit(1)

if not found_exe:
    print("missing-executable")
    sys.exit(1)
print("ok")
PY
)"; then
        error "$(t bsm_sf_bad_archive "${reason:-unsafe}")"
        return 1
    fi
    return 0
}

write_steam_frame_provenance() {
    local build_info="$1"
    local dest="$2"
    local tag="$3"
    local published="$4"
    python3 - "$build_info" "$dest" "$tag" "$published" <<'PY'
import json, sys
src, dest, tag, published = sys.argv[1:5]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
data["source_kind"] = "steam-frame-release"
data["release_tag"] = tag
data["release_published_at"] = published
with open(dest, "w", encoding="utf-8") as out:
    json.dump(data, out, indent=2, ensure_ascii=False)
    out.write("\n")
PY
}

write_custom_bsmanager_source_marker() {
    local kind="$1"
    local detail="$2"
    [[ "$FLAG_DRY_RUN" -eq 1 ]] && return 0
    [[ -d "$BSMANAGER_INSTALL_DIR" ]] || return 0
    python3 - "$BSMANAGER_INSTALL_DIR/$BSMANAGER_PROVENANCE_NAME" "$kind" "$detail" <<'PY'
import json, sys
path, kind, detail = sys.argv[1:4]
data = {"source_kind": kind}
if kind == "custom-url":
    data["source_url"] = detail
elif kind == "local-directory":
    data["source_path"] = detail
with open(path, "w", encoding="utf-8") as out:
    json.dump(data, out, indent=2, ensure_ascii=False)
    out.write("\n")
PY
}

installed_steam_frame_commit() {
    local f="$BSMANAGER_INSTALL_DIR/$BSMANAGER_PROVENANCE_NAME"
    [[ -f "$f" ]] || return 1
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
if d.get("source_kind") not in (None, "", "steam-frame-release"):
    sys.exit(1)
print(d.get("source_commit") or "")
' "$f" 2>/dev/null
}

handle_no_steam_frame_release() {
    if is_bsmanager_native_installed; then
        info "$(t bsm_no_native_asset)"
        success "$(t bsm_native_preserved)"
        info "$(t bsm_kept_unchanged)"
        return 0
    fi
    error "$(t bsm_no_native_fresh)"
    info "$(t bsm_use_custom)"
    info "$(t bsm_flatpak_advanced)"
    return 1
}

install_bsmanager_from_steam_frame_release() {
    local json meta rc=0
    local tag published archive_url sums_url info_url remote_commit installed_commit
    info "$(t bsm_sf_repo "$BSMANAGER_FRAME_RELEASE_REPO")"
    json="$(make_temp_file)"
    if ! fetch_bsmanager_frame_releases_json "$json"; then
        error "$(t bsm_sf_query_failed "network")"
        if is_bsmanager_native_installed; then
            info "$(t bsm_kept_unchanged)"
            return 0
        fi
        return 1
    fi
    meta="$(make_temp_file)"
    if ! select_latest_bsmanager_frame_release "$json" >"$meta"; then
        error "$(t bsm_sf_query_failed "malformed")"
        if is_bsmanager_native_installed; then
            info "$(t bsm_kept_unchanged)"
            return 0
        fi
        return 1
    fi
    if [[ "$(_bsm_json_field "$meta" ok)" != "true" ]]; then
        local err
        err="$(_bsm_json_field "$meta" error)"
        if [[ "$err" == "no_valid_release" ]]; then
            handle_no_steam_frame_release
            return $?
        fi
        error "$(t bsm_sf_query_failed "${err:-unknown}")"
        if is_bsmanager_native_installed; then
            info "$(t bsm_kept_unchanged)"
            return 0
        fi
        return 1
    fi

    tag="$(_bsm_json_field "$meta" tag_name)"
    published="$(_bsm_json_field "$meta" published_at)"
    archive_url="$(_bsm_json_field "$meta" archive_url)"
    sums_url="$(_bsm_json_field "$meta" checksums_url)"
    info_url="$(_bsm_json_field "$meta" build_info_url)"
    info "$(t bsm_latest_release "$tag")"

    local work info_path
    work="$(make_temp_dir)"
    info_path="$work/$BSMANAGER_FRAME_BUILD_INFO"
    if ! download_bsmanager_frame_asset "$info_url" "$info_path"; then
        error "$(t bsm_sf_query_failed "build-info")"
        if is_bsmanager_native_installed; then
            info "$(t bsm_kept_unchanged)"
            return 0
        fi
        return 1
    fi
    remote_commit="$(validate_bsmanager_frame_build_info "$info_path")" || {
        if is_bsmanager_native_installed; then
            info "$(t bsm_kept_unchanged)"
        fi
        return 1
    }

    installed_commit=""
    if is_bsmanager_native_installed; then
        installed_commit="$(installed_steam_frame_commit 2>/dev/null || true)"
        if [[ -n "$installed_commit" && "$installed_commit" == "$remote_commit" && "$FLAG_FORCE" -ne 1 ]]; then
            local inst_tag
            inst_tag="$(_bsm_json_field "$BSMANAGER_INSTALL_DIR/$BSMANAGER_PROVENANCE_NAME" release_tag)"
            [[ -n "$inst_tag" ]] || inst_tag="$tag"
            success "$(t bsm_sf_uptodate)"
            info "$(t bsm_sf_installed "$inst_tag" "$installed_commit")"
            return 0
        fi
        if [[ "$FLAG_FORCE" -ne 1 ]]; then
            if [[ -z "$installed_commit" ]]; then
                info "$(t bsm_sf_legacy)"
            else
                local inst_tag
                inst_tag="$(_bsm_json_field "$BSMANAGER_INSTALL_DIR/$BSMANAGER_PROVENANCE_NAME" release_tag)"
                [[ -n "$inst_tag" ]] || inst_tag="?"
                info "$(t bsm_sf_installed "$inst_tag" "$installed_commit")"
            fi
            info "$(t bsm_sf_available "$tag" "$remote_commit")"
            info "$(t bsm_sf_update_available)"
            if ! prompt_confirm "$(t bsm_sf_confirm "$tag")"; then
                if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
                    error "$(t bsm_sf_need_yes)"
                fi
                info "$(t bsm_kept_unchanged)"
                return 1
            fi
        fi
    elif is_bsmanager_flatpak_user_installed || is_bsmanager_flatpak_system_installed; then
        warn "$(t bsm_dup_warn)"
        if ! prompt_confirm "Install native BSManager alongside existing Flatpak?"; then
            return 1
        fi
    fi

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] verify ${BSMANAGER_FRAME_CHECKSUMS}, archive layout, ARM64 ELF, then install $tag"
        return 0
    fi

    local sums_path archive_path prov_path stage
    sums_path="$work/$BSMANAGER_FRAME_CHECKSUMS"
    archive_path="$work/$BSMANAGER_FRAME_ARCHIVE"
    if ! download_bsmanager_frame_asset "$sums_url" "$sums_path"; then
        error "$(t bsm_sf_query_failed "SHA256SUMS")"
        is_bsmanager_native_installed && info "$(t bsm_kept_unchanged)"
        return 1
    fi
    if ! download_bsmanager_frame_asset "$archive_url" "$archive_path"; then
        error "$(t bsm_sf_query_failed "archive")"
        is_bsmanager_native_installed && info "$(t bsm_kept_unchanged)"
        return 1
    fi
    validate_bsmanager_frame_checksum "$archive_path" "$sums_path" || {
        is_bsmanager_native_installed && info "$(t bsm_kept_unchanged)"
        return 1
    }
    validate_bsmanager_frame_archive "$archive_path" || {
        is_bsmanager_native_installed && info "$(t bsm_kept_unchanged)"
        return 1
    }
    mkdir -p "$work/extract"
    extract_archive "$archive_path" "$work/extract"
    stage="$work/extract/bs-manager"
    if [[ ! -f "$stage/bs-manager" ]]; then
        die "Extracted archive is missing bs-manager/bs-manager" || return 1
    fi
    if [[ ! -d "$stage/resources" ]]; then
        die "Extracted archive is missing bs-manager/resources" || return 1
    fi
    if [[ ! -f "$stage/resources/app.asar" ]]; then
        die "Extracted archive is missing bs-manager/resources/app.asar" || return 1
    fi
    chmod +x "$stage/bs-manager" || true
    if ! is_arm64_elf "$stage/bs-manager"; then
        die "Refusing non-ARM64 bs-manager ($(file_arch_of "$stage/bs-manager"))" || return 1
    fi
    prov_path="$work/$BSMANAGER_PROVENANCE_NAME"
    write_steam_frame_provenance "$info_path" "$prov_path" "$tag" "$published"
    cp -a "$prov_path" "$stage/$BSMANAGER_PROVENANCE_NAME"
    info "$(t bsm_sf_downloading "$tag")"
    install_native_bsmanager_from_dir "$work/extract" "$prov_path"
}

install_bsmanager_flatpak_bundle() {
    local url="$1"
    local name="$2"
    local tmp bundle

    if [[ "$FLAG_ALLOW_FLATPAK" -ne 1 ]]; then
        die "$(t bsm_flatpak_need_flag)"
    fi
    command -v flatpak >/dev/null 2>&1 || die "flatpak is not available"

    if is_bsmanager_flatpak_system_installed && ! is_bsmanager_flatpak_user_installed; then
        error "$(t bsm_flatpak_system_exists)"
        return 1
    fi
    if is_bsmanager_flatpak_system_installed && is_bsmanager_flatpak_user_installed; then
        warn "Flatpak user and system BSManager both present"
    fi

    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 && "$FLAG_YES" -ne 1 ]]; then
        die "Flatpak install requires --yes in non-interactive mode"
    fi
    if [[ "$FLAG_NON_INTERACTIVE" -eq 0 ]]; then
        if ! prompt_confirm "$(t ask_flatpak "$name")"; then
            info "Flatpak installation skipped"
            return 1
        fi
    fi

    tmp="$(make_temp_dir)"
    bundle="$tmp/$name"
    download_file "$url" "$bundle"
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] flatpak install --user $bundle"
        return 0
    fi
    flatpak install --user -y "$bundle"
    if flatpak info --user "$FLATPAK_APP_ID_EXPECTED" >/dev/null 2>&1; then
        success "BSManager Flatpak installed (user): $FLATPAK_APP_ID_EXPECTED"
    else
        warn "Flatpak install finished but $FLATPAK_APP_ID_EXPECTED not confirmed via flatpak info --user"
    fi
}

cmd_install_bsmanager() {
    ensure_user_dirs
    warn_bsmanager_duplicate_installations || true

    if [[ -n "$OPT_BSMANAGER_DIR" ]]; then
        [[ -d "$OPT_BSMANAGER_DIR" ]] || die "BSManager dir not found: $OPT_BSMANAGER_DIR"
        if is_bsmanager_flatpak_user_installed || is_bsmanager_flatpak_system_installed; then
            if [[ "$FLAG_NON_INTERACTIVE" -eq 1 && "$FLAG_YES" -ne 1 ]]; then
                die "Native install would coexist with Flatpak. Re-run with --yes to confirm, or remove Flatpak first."
            fi
            if [[ "$FLAG_NON_INTERACTIVE" -eq 0 ]]; then
                warn "$(t bsm_dup_warn)"
                if ! prompt_confirm "Install/replace native BSManager while Flatpak is also present?"; then
                    return 1
                fi
            fi
        fi
        install_native_bsmanager_from_dir "$OPT_BSMANAGER_DIR"
        write_custom_bsmanager_source_marker "local-directory" "$OPT_BSMANAGER_DIR"
        info "$(t bsm_sf_source_dir)"
        return 0
    fi

    if [[ -n "$OPT_BSMANAGER_URL" ]]; then
        local tmp archive
        tmp="$(make_temp_dir)"
        archive="$tmp/asset"
        download_file "$OPT_BSMANAGER_URL" "$archive"
        case "$OPT_BSMANAGER_URL" in
            *.flatpak)
                install_bsmanager_flatpak_bundle "$OPT_BSMANAGER_URL" "custom.flatpak" || return 1
                ;;
            *)
                mkdir -p "$tmp/extract"
                local named="$tmp/download.bin"
                mv "$archive" "$named"
                case "$OPT_BSMANAGER_URL" in
                    *.zip) mv "$named" "$tmp/a.zip"; extract_archive "$tmp/a.zip" "$tmp/extract" ;;
                    *.tar.xz) mv "$named" "$tmp/a.tar.xz"; extract_archive "$tmp/a.tar.xz" "$tmp/extract" ;;
                    *) mv "$named" "$tmp/a.tar.gz"; extract_archive "$tmp/a.tar.gz" "$tmp/extract" ;;
                esac
                install_native_bsmanager_from_dir "$tmp/extract"
                write_custom_bsmanager_source_marker "custom-url" "$OPT_BSMANAGER_URL"
                info "$(t bsm_sf_source_url)"
                ;;
        esac
        return 0
    fi

    install_bsmanager_from_steam_frame_release
}

# =============================================================================
# BSManager configuration
# =============================================================================

bsmanager_config_candidates() {
    printf '%s\n' "$BSMANAGER_CONFIG_DIR/config.json"
    printf '%s\n' "$HOME/.var/app/${FLATPAK_APP_ID_EXPECTED}/config/bs-manager/config.json"
}

find_bsmanager_config() {
    local c
    while IFS= read -r c; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done < <(bsmanager_config_candidates)
    return 1
}

configure_bsmanager_proton() {
    local proton_path experimental_path config_path support write_prefix=0
    proton_path="$(resolve_app_install_path "$PROTON_STABLE_APPID" 2>/dev/null || true)"
    experimental_path="$(resolve_app_install_path "$PROTON_EXPERIMENTAL_APPID" 2>/dev/null || true)"

    if [[ -z "$proton_path" ]]; then
        warn "Main Proton path not available; skipping automatic config write"
        show_manual_proton_instructions "$proton_path" "$experimental_path"
        return 1
    fi

    if is_bsmanager_running; then
        error "$(t bsm_running_config)"
        log_action FAIL "config_aborted bsmanager_running"
        return 1
    fi

    local seeded=0
    if ! config_path="$(find_bsmanager_config)"; then
        # Fresh install: electron-store has not created config.json yet.
        # Write the Proton folders we just installed instead of asking for a first launch.
        config_path="$BSMANAGER_CONFIG_DIR/config.json"
        seeded=1
        if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
            info "[dry-run] would create $config_path"
        else
            mkdir -p "$BSMANAGER_CONFIG_DIR"
            printf '%s\n' '{}' >"$config_path"
            log_action OK "bsmanager_config_created path=$config_path"
        fi
    fi

    support="$(bsmanager_supports_prefix_proton)"
    case "$support" in
        supported)
            if [[ -n "$experimental_path" ]]; then
                write_prefix=1
            else
                warn "Modding Proton path missing; configuring main Proton only"
            fi
            ;;
        unsupported)
            info "$(t bsm_prefix_unsupported)"
            ;;
        *)
            if [[ "$seeded" -eq 1 && -n "$experimental_path" ]]; then
                write_prefix=1
            else
                info "$(t bsm_prefix_unknown)"
                show_manual_proton_instructions "$proton_path" "$experimental_path"
            fi
            ;;
    esac

    info "Updating BSManager config: $config_path"
    local backup_dir stamp result
    stamp="$(date +%Y%m%dT%H%M%S)"
    backup_dir="$TOOL_DATA_DIR/backups/config/$stamp"
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] set proton-folder=$proton_path"
        if [[ "$write_prefix" -eq 1 ]]; then
            info "[dry-run] set prefix-proton-folder=$experimental_path"
        else
            info "[dry-run] skip prefix-proton-folder (support=$support)"
        fi
        return 0
    fi
    mkdir -p "$backup_dir"
    cp -a "$config_path" "$backup_dir/"

    if [[ "$write_prefix" -eq 1 ]]; then
        result="$(py_update_bsmanager_config "$config_path" "$proton_path" "$experimental_path" || true)"
    else
        # Pass empty prefix so Python only updates proton-folder
        result="$(py_update_bsmanager_config "$config_path" "$proton_path" "" || true)"
    fi
    case "$result" in
        UPDATED|UNCHANGED)
            success "Main Proton configured"
            if [[ "$write_prefix" -eq 1 ]]; then
                success "Modding Proton configured (prefix-proton-folder)"
            fi
            if [[ "$seeded" -eq 1 ]]; then
                success "$(t bsm_config_seeded "$config_path")"
            fi
            ;;
        *)
            warn "Could not update config automatically ($result)"
            show_manual_proton_instructions "$proton_path" "$experimental_path"
            return 1
            ;;
    esac
}

show_manual_proton_instructions() {
    local proton_path="${1:-}"
    local experimental_path="${2:-}"
    info "Set these values inside BSManager settings:"
    info "  Main Proton (proton-folder): ${proton_path:-<install Proton 11.0 ARM64>}"
    info "  Modding Proton (prefix-proton-folder): ${experimental_path:-<install Proton Experimental ARM64>}"
    info "  (prefix-proton-folder requires BSManager with PR #1136 or newer)"
}

# =============================================================================
# Beat Saber discovery / compatdata / wrappers
# =============================================================================

beat_saber_instances_root() {
    local cfg parent p
    local -a roots=()
    local -A seen=()

    roots+=("$BSMANAGER_DATA_DIR/BSInstances")
    roots+=("$HOME/BSManager/BSInstances")
    roots+=("$HOME/Documents/BSManager/BSInstances")

    if cfg="$(find_bsmanager_config 2>/dev/null)"; then
        parent="$(python3 -c '
import json,sys
try:
    data=json.load(open(sys.argv[1],encoding="utf-8"))
    v=data.get("installation-folder") or ""
    print(v)
except Exception:
    print("")
' "$cfg" 2>/dev/null || true)"
        if [[ -n "$parent" ]]; then
            roots+=("$parent/BSManager/BSInstances")
            roots+=("$parent/BSInstances")
        fi
    fi

    for p in "${roots[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -n "${seen[$p]:-}" ]] && continue
        seen["$p"]=1
        printf '%s\n' "$p"
    done
    return 0
}

# Folder that actually contains the Windows executable.
beat_saber_exe_dir() {
    local dir="$1"
    if [[ -f "$dir/Beat Saber.exe" || -f "$dir/BeatSaber.exe" ]]; then
        printf '%s\n' "$dir"
        return 0
    fi
    if [[ -f "$dir/Beat Saber/Beat Saber.exe" || -f "$dir/Beat Saber/BeatSaber.exe" ]]; then
        printf '%s\n' "$dir/Beat Saber"
        return 0
    fi
    return 1
}

_sort_bs_instances() {
    local -a packed=("$@")
    local half=$(( ${#packed[@]} / 2 ))
    local -a only_names=("${packed[@]:0:half}")
    local -a only_paths=("${packed[@]:half}")
    local -a recs=() lines=() next_names=() next_paths=()
    local i line name path
    [[ "$half" -gt 0 ]] || return 1
    for i in "${!only_names[@]}"; do
        recs+=("${only_names[$i]}"$'\t'"${only_paths[$i]}")
    done
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    mapfile -t lines < <(python3 -c 'import sys, re
pairs=[]
for rec in sys.argv[1:]:
    name, path = rec.split("\t", 1)
    pairs.append((name, path))
def key(p):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", p[0])]
for name, path in sorted(pairs, key=key):
    sys.stdout.write(name + "\t" + path + "\n")
' "${recs[@]}") || return 1
    for line in "${lines[@]}"; do
        [[ -n "$line" ]] || continue
        name="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        [[ -n "$name" && -n "$path" ]] || continue
        next_names+=("$name")
        next_paths+=("$path")
    done
    [[ "${#next_names[@]}" -eq "$half" ]] || return 1
    BSMF_BS_NAMES=("${next_names[@]}")
    BSMF_BS_PATHS=("${next_paths[@]}")
    return 0
}

# Fills BSMF_BS_NAMES / BSMF_BS_PATHS in the current shell.
# Globs only: no pipe, no while-read, so `set -e` cannot drop matches.
refresh_beat_saber_instances() {
    local root dir exe_dir name path
    local -a roots=()
    local -A seen_path=()
    local had_nullglob=0
    BSMF_BS_NAMES=()
    BSMF_BS_PATHS=()

    mapfile -t roots < <(beat_saber_instances_root) || true
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for root in "${roots[@]}"; do
        [[ -n "$root" && -d "$root" ]] || continue
        for dir in "$root"/*/; do
            dir="${dir%/}"
            exe_dir="$(beat_saber_exe_dir "$dir" 2>/dev/null || true)"
            [[ -n "$exe_dir" && -d "$exe_dir" ]] || continue
            path="$(canonical_path "$exe_dir")"
            if [[ -n "${seen_path[$path]:-}" ]]; then
                continue
            fi
            seen_path["$path"]=1
            name="$(basename -- "$dir")"
            [[ -n "$name" && "$name" != "*" ]] || continue
            BSMF_BS_NAMES+=("$name")
            BSMF_BS_PATHS+=("$path")
        done
    done
    if [[ "$had_nullglob" -eq 0 ]]; then
        shopt -u nullglob
    fi

    if [[ "${#BSMF_BS_NAMES[@]}" -gt 1 ]]; then
        _sort_bs_instances "${BSMF_BS_NAMES[@]}" "${BSMF_BS_PATHS[@]}" || true
    fi
    return 0
}

list_beat_saber_instances() {
    local name
    refresh_beat_saber_instances || true
    for name in "${BSMF_BS_NAMES[@]}"; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$name"
    done
    return 0
}

_select_bs_index() {
    local idx="$1"
    BSMF_SELECTED_BS_NAME="${BSMF_BS_NAMES[$idx]}"
    BSMF_SELECTED_BS_DIR="${BSMF_BS_PATHS[$idx]}"
    info "$(t bs_version_using "$BSMF_SELECTED_BS_NAME")"
    debug "Beat Saber dir: $BSMF_SELECTED_BS_DIR"
    return 0
}

_report_empty_bs_instances() {
    local root_hint="$BSMANAGER_DATA_DIR/BSInstances"
    local -a roots=()
    local r mark
    error "$(t bs_version_none_die "$root_hint")"
    mapfile -t roots < <(beat_saber_instances_root) || true
    for r in "${roots[@]}"; do
        [[ -n "$r" ]] || continue
        if [[ -d "$r" ]]; then
            mark="[dir ok, no Beat Saber.exe]"
        else
            mark="[missing]"
        fi
        error "  searched: $r $mark"
    done
}

select_beat_saber_version() {
    local i answer="" count=0 default_num=""
    refresh_beat_saber_instances || true
    count="${#BSMF_BS_NAMES[@]}"

    if [[ "$count" -eq 0 ]]; then
        _report_empty_bs_instances
        return 1
    fi
    if [[ -n "$OPT_BS_VERSION" ]]; then
        for ((i = 0; i < count; i++)); do
            if [[ "${BSMF_BS_NAMES[$i]}" == "$OPT_BS_VERSION" ]]; then
                _select_bs_index "$i"
                return 0
            fi
        done
        error "Beat Saber version not found: $OPT_BS_VERSION"
        return 1
    fi

    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        if [[ "$count" -eq 1 ]]; then
            _select_bs_index 0
            return 0
        fi
        error "$(t bs_version_prompt)"
        for ((i = 0; i < count; i++)); do
            error "  - ${BSMF_BS_NAMES[$i]}"
        done
        error "Re-run with --version <Beat Saber version>"
        return 1
    fi

    tty_open || true
    tty_printf '\n%s\n' "$(t bs_version_prompt)"
    tty_printf '%s\n' "$(t bs_versions_detected)"
    for ((i = 0; i < count; i++)); do
        tty_printf '  %d) Beat Saber %s\n' "$((i + 1))" "${BSMF_BS_NAMES[$i]}"
        tty_printf '      %s\n' "${BSMF_BS_PATHS[$i]}"
    done
    tty_printf '\n'
    default_num="1"
    while true; do
        answer="$(prompt_reply "$(t bs_version_pick_number)" "$default_num")"
        answer="${answer%%[[:space:]]*}"
        if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= count)); then
            _select_bs_index "$((answer - 1))"
            return 0
        fi
        tty_printf '%s (%q)\n' "$(t menu_invalid)" "$answer"
    done
}

discover_compatdata() {
    if [[ -n "$OPT_COMPATDATA" ]]; then
        [[ -d "$OPT_COMPATDATA" ]] || die "compatdata path not found: $OPT_COMPATDATA"
        printf '%s\n' "$(canonical_path "$OPT_COMPATDATA")"
        return 0
    fi

    local shared="$BSMANAGER_DATA_DIR/SharedContent"
    local preferred="$shared/compatdata"
    local -a dirs=() valid=()
    local d canon

    if [[ -d "$shared" ]]; then
        mapfile -t dirs < <(find "$shared" -mindepth 1 -maxdepth 1 -type d -name 'compatdata*' 2>/dev/null | sort) || true
    fi
    for d in "${dirs[@]}"; do
        [[ -n "$d" && -d "$d/pfx" ]] || continue
        valid+=("$d")
    done

    if [[ "${#valid[@]}" -eq 0 ]]; then
        error "$(t compat_missing "$shared")"
        return 1
    fi
    if [[ "${#valid[@]}" -eq 1 ]]; then
        printf '%s\n' "$(canonical_path "${valid[0]}")"
        return 0
    fi
    for d in "${valid[@]}"; do
        canon="$(canonical_path "$d")"
        if [[ "$canon" == "$(canonical_path "$preferred")" ]]; then
            printf '%s\n' "$canon"
            return 0
        fi
    done
    prompt_choice "Select compatdata directory" "${valid[@]}"
}

sanitize_version_slug() {
    local v="$1"
    v="${v//\//-}"
    v="${v// /-}"
    v="$(printf '%s' "$v" | tr -cd 'A-Za-z0-9._-')"
    printf '%s\n' "$v"
}

launcher_wrapper_path() {
    printf '%s\n' "$LOCAL_BIN/beat-saber-$(sanitize_version_slug "$1")-modded"
}

launcher_desktop_path() {
    printf '%s\n' "$APPLICATIONS_DIR/beat-saber-$(sanitize_version_slug "$1")-modded.desktop"
}

_launcher_record() {
    local slug="$1" label="$2" dir="$3" orphan="$4"
    local wrapper desktop has_wrapper=0 has_desktop=0 i
    wrapper="$(launcher_wrapper_path "$slug")"
    desktop="$(launcher_desktop_path "$slug")"
    [[ -e "$wrapper" ]] && has_wrapper=1
    [[ -e "$desktop" ]] && has_desktop=1
    for ((i = 0; i < ${#BSMF_LAUNCHER_SLUGS[@]}; i++)); do
        if [[ "${BSMF_LAUNCHER_SLUGS[$i]}" == "$slug" ]]; then
            return 0
        fi
    done
    BSMF_LAUNCHER_SLUGS+=("$slug")
    BSMF_LAUNCHER_LABELS+=("$label")
    BSMF_LAUNCHER_DIRS+=("$dir")
    BSMF_LAUNCHER_HAS_WRAPPER+=("$has_wrapper")
    BSMF_LAUNCHER_HAS_DESKTOP+=("$has_desktop")
    BSMF_LAUNCHER_ORPHAN+=("$orphan")
}

refresh_managed_launchers() {
    local i slug wrapper desktop base had_nullglob=0
    local -A seen=()
    BSMF_LAUNCHER_SLUGS=()
    BSMF_LAUNCHER_LABELS=()
    BSMF_LAUNCHER_DIRS=()
    BSMF_LAUNCHER_HAS_WRAPPER=()
    BSMF_LAUNCHER_HAS_DESKTOP=()
    BSMF_LAUNCHER_ORPHAN=()
    refresh_beat_saber_instances || true
    for ((i = 0; i < ${#BSMF_BS_NAMES[@]}; i++)); do
        slug="$(sanitize_version_slug "${BSMF_BS_NAMES[$i]}")"
        [[ -n "$slug" ]] || continue
        seen["$slug"]=1
        _launcher_record "$slug" "${BSMF_BS_NAMES[$i]}" "${BSMF_BS_PATHS[$i]}" 0
    done
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for wrapper in "$LOCAL_BIN"/beat-saber-*-modded; do
        base="$(basename -- "$wrapper")"
        slug="${base#beat-saber-}"
        slug="${slug%-modded}"
        [[ -n "$slug" && -z "${seen[$slug]:-}" ]] || continue
        seen["$slug"]=1
        _launcher_record "$slug" "$slug" "" 1
    done
    for desktop in "$APPLICATIONS_DIR"/beat-saber-*-modded.desktop; do
        base="$(basename -- "$desktop" .desktop)"
        slug="${base#beat-saber-}"
        slug="${slug%-modded}"
        [[ -n "$slug" && -z "${seen[$slug]:-}" ]] || continue
        seen["$slug"]=1
        _launcher_record "$slug" "$slug" "" 1
    done
    if [[ "$had_nullglob" -eq 0 ]]; then
        shopt -u nullglob
    fi
    return 0
}

create_beat_saber_wrapper() {
    local version="$1"
    local bs_dir="${2:-}"
    local slug compat steam_root proton_path wrapper exe_name
    slug="$(sanitize_version_slug "$version")"
    if [[ -z "$bs_dir" ]]; then
        bs_dir="${BSMF_SELECTED_BS_DIR:-}"
    fi
    if [[ -z "$bs_dir" ]]; then
        refresh_beat_saber_instances || true
        local i
        for ((i = 0; i < ${#BSMF_BS_NAMES[@]}; i++)); do
            if [[ "${BSMF_BS_NAMES[$i]}" == "$version" ]]; then
                bs_dir="${BSMF_BS_PATHS[$i]}"
                break
            fi
        done
    fi
    if [[ -z "$bs_dir" && -f "$BSMANAGER_DATA_DIR/BSInstances/$version/Beat Saber.exe" ]]; then
        bs_dir="$BSMANAGER_DATA_DIR/BSInstances/$version"
    fi
    [[ -n "$bs_dir" && -d "$bs_dir" ]] || die "Beat Saber folder missing for $version"
    if [[ -f "$bs_dir/Beat Saber.exe" ]]; then
        exe_name="Beat Saber.exe"
    elif [[ -f "$bs_dir/BeatSaber.exe" ]]; then
        exe_name="BeatSaber.exe"
    else
        die "Beat Saber.exe missing in $bs_dir"
    fi

    steam_root="$(find_steam_root)" || die "Steam root not found"
    proton_path="$(resolve_app_install_path "$PROTON_STABLE_APPID")" || die "Proton stable not installed"
    validate_proton_install "$proton_path" "$PROTON_STABLE_LABEL" || return 1
    compat="$(discover_compatdata)" || die "$(t compat_missing "$BSMANAGER_DATA_DIR/SharedContent")"

    wrapper="$LOCAL_BIN/beat-saber-${slug}-modded"
    info "Writing wrapper: $wrapper"

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] write wrapper for $version ($bs_dir)"
        printf '%s\n' "$wrapper"
        return 0
    fi

    mkdir -p "$LOCAL_BIN"
    cat >"$wrapper" <<EOF
#!/usr/bin/env bash
# Generated by bsmanager-frame ${VERSION} — Steam Frame oriented Beat Saber launcher
set -Eeuo pipefail

PROTON=$(printf '%q' "$proton_path")
BS=$(printf '%q' "$bs_dir")
COMPAT=$(printf '%q' "$compat")
STEAM=$(printf '%q' "$steam_root")

if [[ ! -x "\$PROTON/proton" && ! -f "\$PROTON/proton" ]]; then
    echo "Proton missing: \$PROTON/proton" >&2
    exit 1
fi
if [[ ! -f "\$BS/${exe_name}" ]]; then
    echo "Beat Saber missing: \$BS/${exe_name}" >&2
    exit 1
fi
if [[ ! -d "\$COMPAT" ]]; then
    echo "compatdata missing: \$COMPAT" >&2
    exit 1
fi
if [[ ! -d "\$STEAM" ]]; then
    echo "Steam root missing: \$STEAM" >&2
    exit 1
fi

export STEAM_COMPAT_DATA_PATH="\$COMPAT"
export STEAM_COMPAT_INSTALL_PATH="\$BS"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="\$STEAM"

export STEAM_COMPAT_APP_ID=${BEAT_SABER_APPID}
export SteamAppId=${BEAT_SABER_APPID}
export SteamGameId=${BEAT_SABER_APPID}
export SteamOverlayGameId=${BEAT_SABER_APPID}
export SteamEnv=1

export VR_OVERRIDE=/opt/steamvr
export DISABLE_VULKAN_FDM_INJECTION_LAYER=1
export OXR_NO_TEXTURE_SOURCE_ALPHA=1
export WINEDLLOVERRIDES="winhttp=n,b"

unset XR_RUNTIME_JSON || true
unset VK_INSTANCE_LAYERS || true
unset FDM_DEBUG || true

cd "\$BS"
exec "\$PROTON/proton" run "\$BS/${exe_name}" "\$@"
EOF
    chmod +x "$wrapper"
    success "Beat Saber $version wrapper valid"
    printf '%s\n' "$wrapper"
}

# =============================================================================
# Desktop shortcuts
# =============================================================================

desktop_escape_exec() {
    # Escape for Exec= keys: \, ", `
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

find_bsmanager_icon() {
    local -a candidates=(
        "$BSMANAGER_INSTALL_DIR/bs-manager.png"
        "$BSMANAGER_INSTALL_DIR/resources/icon.png"
        "$BSMANAGER_INSTALL_DIR/icon.png"
        "$XDG_DATA_HOME/icons/hicolor/256x256/apps/bs-manager.png"
        "$XDG_DATA_HOME/icons/hicolor/128x128/apps/io.bsmanager.bsmanager.png"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

write_desktop_entry() {
    local path="$1"
    local name="$2"
    local exec_line="$3"
    local icon="${4:-}"
    local comment="${5:-}"

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] write desktop entry $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    {
        printf '%s\n' "[Desktop Entry]"
        printf '%s\n' "Type=Application"
        printf '%s\n' "Version=1.0"
        printf '%s\n' "Name=$name"
        [[ -n "$comment" ]] && printf '%s\n' "Comment=$comment"
        printf '%s\n' "Exec=$exec_line"
        [[ -n "$icon" ]] && printf '%s\n' "Icon=$icon"
        printf '%s\n' "Terminal=false"
        printf '%s\n' "Categories=Game;"
        printf '%s\n' "StartupNotify=true"
    } >"$path"
    chmod +x "$path" || true
}

create_desktop_shortcuts() {
    local version="${1:-}"
    local bs_dir="${2:-}"
    local icon="" exec_bs wrapper slug
    icon="$(find_bsmanager_icon 2>/dev/null || true)"

    if [[ -x "$BSMANAGER_BIN" || -x "$BSMANAGER_INSTALL_DIR/bs-manager" ]]; then
        exec_bs="$(desktop_escape_exec "$BSMANAGER_BIN") %U"
        write_desktop_entry \
            "$APPLICATIONS_DIR/bs-manager.desktop" \
            "BSManager" \
            "$exec_bs" \
            "$icon" \
            "Manage Beat Saber versions and mods"
        success "Desktop entry: bs-manager.desktop"
    fi

    if [[ -z "$version" ]]; then
        select_beat_saber_version || return 1
        version="$BSMF_SELECTED_BS_NAME"
        bs_dir="$BSMF_SELECTED_BS_DIR"
    fi
    [[ -n "$version" ]] || return 1

    wrapper="$(create_beat_saber_wrapper "$version" "$bs_dir")" || return 1
    slug="$(sanitize_version_slug "$version")"
    write_desktop_entry \
        "$APPLICATIONS_DIR/beat-saber-${slug}-modded.desktop" \
        "Beat Saber ${version} Modded" \
        "$(desktop_escape_exec "$wrapper")" \
        "$icon" \
        "Steam Frame modded Beat Saber launcher"
    success "Desktop entry: beat-saber-${slug}-modded.desktop"

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_cmd update-desktop-database "$APPLICATIONS_DIR" || true
    fi
}

install_beat_saber_launcher() {
    local version="$1"
    local bs_dir="$2"
    local wrapper slug icon=""
    wrapper="$(create_beat_saber_wrapper "$version" "$bs_dir")" || return 1
    slug="$(sanitize_version_slug "$version")"
    icon="$(find_bsmanager_icon 2>/dev/null || true)"
    write_desktop_entry \
        "$(launcher_desktop_path "$slug")" \
        "Beat Saber ${version} Modded" \
        "$(desktop_escape_exec "$wrapper")" \
        "$icon" \
        "Steam Frame modded Beat Saber launcher"
    success "Desktop entry: beat-saber-${slug}-modded.desktop"
    if command -v update-desktop-database >/dev/null 2>&1; then
        run_cmd update-desktop-database "$APPLICATIONS_DIR" || true
    fi
    if steam_shortcuts_cdp "$version" "$bs_dir"; then
        :
    else
        warn "$(t launcher_steam_left)"
    fi
    success "$(t launcher_added "$version")"
}

# =============================================================================
# Steam shortcuts via CDP (feature-detect only)
# =============================================================================

ensure_cdp_venv() {
    local venv="$TOOL_DATA_DIR/tools/cdp-venv"
    if [[ -x "$venv/bin/python" ]]; then
        printf '%s\n' "$venv"
        return 0
    fi
    require_python3
    if ! python3 -c 'import venv' 2>/dev/null; then
        die "python3 venv module unavailable; Steam shortcut CDP support cannot be bootstrapped"
    fi
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] create CDP venv at $venv"
        printf '%s\n' "$venv"
        return 0
    fi
    mkdir -p "$(dirname "$venv")"
    python3 -m venv "$venv"
    # shellcheck disable=SC1091
    "$venv/bin/pip" install --disable-pip-version-check -q 'websocket-client>=1.8,<2'
    printf '%s\n' "$venv"
}

detect_steam_cdp_port() {
    local port
    for port in $CDP_PORT_CANDIDATES; do
        if have_curl; then
            if curl -fsS --max-time 1 "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
                printf '%s\n' "$port"
                return 0
            fi
        elif have_wget; then
            if wget -q --timeout=1 -O - "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
                printf '%s\n' "$port"
                return 0
            fi
        fi
    done
    return 1
}

steam_shortcuts_cdp() {
    local version="$1"
    local bs_dir="${2:-${BSMF_SELECTED_BS_DIR:-}}"
    local wrapper slug port venv
    slug="$(sanitize_version_slug "$version")"
    wrapper="$LOCAL_BIN/beat-saber-${slug}-modded"
    if [[ -z "$bs_dir" ]]; then
        refresh_beat_saber_instances || true
        local i
        for ((i = 0; i < ${#BSMF_BS_NAMES[@]}; i++)); do
            if [[ "${BSMF_BS_NAMES[$i]}" == "$version" ]]; then
                bs_dir="${BSMF_BS_PATHS[$i]}"
                break
            fi
        done
    fi
    [[ -n "$bs_dir" ]] || return 1
    if [[ ! -x "$wrapper" ]]; then
        wrapper="$(create_beat_saber_wrapper "$version" "$bs_dir")" || return 1
    fi

    if ! port="$(detect_steam_cdp_port)"; then
        warn "Steam CDP endpoint not detected on ports: $CDP_PORT_CANDIDATES"
        warn "Cannot safely create/repair Steam shortcuts without the live CEF interface."
        warn "Add the Beat Saber shortcut once via Steam/BSManager, then re-run to repair."
        return 1
    fi

    venv="$(ensure_cdp_venv)" || return 1
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] CDP inspect/repair shortcut via 127.0.0.1:$port"
        return 0
    fi

    info "Using Steam CDP on 127.0.0.1:$port (feature-detecting SteamClient.Apps APIs)"
    "$venv/bin/python" - "$port" "$wrapper" "$bs_dir" <<'PY'
import json, sys, urllib.request

try:
    import websocket
except ImportError:
    print("websocket-client missing in venv", file=sys.stderr)
    sys.exit(2)

port, wrapper, start_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)

version = get(f"http://127.0.0.1:{port}/json/version")
targets = get(f"http://127.0.0.1:{port}/json/list")
shared = None
for t in targets:
    title = (t.get("title") or "") + " " + (t.get("url") or "")
    if "SharedJSContext" in title or t.get("title") == "SharedJSContext":
        shared = t
        break
if shared is None:
    for t in targets:
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
            # fallback: first page with ws
            shared = t
            break
if shared is None or not shared.get("webSocketDebuggerUrl"):
    print("SharedJSContext target not found", file=sys.stderr)
    sys.exit(3)

ws_url = shared["webSocketDebuggerUrl"]
msg_id = 0

def rpc(ws, method, params=None):
    global msg_id
    msg_id += 1
    payload = {"id": msg_id, "method": method}
    if params is not None:
        payload["params"] = params
    ws.send(json.dumps(payload))
    while True:
        raw = ws.recv()
        data = json.loads(raw)
        if data.get("id") == msg_id:
            return data

ws = websocket.create_connection(ws_url, timeout=10)
try:
    # Feature-detect SteamClient.Apps functions — never invent signatures.
    detect = rpc(ws, "Runtime.evaluate", {
        "expression": """
(() => {
  const apps = (window.SteamClient && window.SteamClient.Apps) ? window.SteamClient.Apps : null;
  if (!apps) return {ok:false, error:'SteamClient.Apps missing'};
  const names = Object.getOwnPropertyNames(apps).concat(Object.keys(apps));
  const uniq = Array.from(new Set(names)).sort();
  return {
    ok: true,
    methods: uniq,
    hasSetShortcutExe: typeof apps.SetShortcutExe === 'function',
    hasSetShortcutStartDir: typeof apps.SetShortcutStartDir === 'function',
    hasSetShortcutLaunchOptions: typeof apps.SetShortcutLaunchOptions === 'function',
    hasSpecifyCompatTool: typeof apps.SpecifyCompatTool === 'function',
    hasAddShortcut: typeof apps.AddShortcut === 'function',
    hasGetShortcuts: typeof apps.GetShortcuts === 'function' || typeof apps.GetAllShortcuts === 'function',
  };
})()
""",
        "returnByValue": True,
        "awaitPromise": False,
    })
    det = (detect.get("result") or {}).get("result") or {}
    val = det.get("value") if isinstance(det, dict) else None
    if not val or not val.get("ok"):
        print("SteamClient.Apps unavailable", file=sys.stderr)
        sys.exit(4)

    print(json.dumps({"detected": {k: val.get(k) for k in val if k != "methods"}, "method_count": len(val.get("methods") or [])}))

    if not (val.get("hasSetShortcutExe") and val.get("hasSetShortcutStartDir")):
        print("Required SetShortcut* APIs not present; refusing unsafe shortcut mutation", file=sys.stderr)
        sys.exit(5)

    # Attempt to list shortcuts if an API exists; otherwise instruct user.
    list_expr = None
    if "GetShortcuts" in (val.get("methods") or []) or val.get("hasGetShortcuts"):
        list_expr = """
(() => {
  const apps = window.SteamClient.Apps;
  if (typeof apps.GetShortcuts === 'function') return apps.GetShortcuts();
  if (typeof apps.GetAllShortcuts === 'function') return apps.GetAllShortcuts();
  return null;
})()
"""
    shortcuts = []
    if list_expr:
        res = rpc(ws, "Runtime.evaluate", {"expression": list_expr, "returnByValue": True, "awaitPromise": True})
        value = ((res.get("result") or {}).get("result") or {}).get("value")
        if isinstance(value, list):
            shortcuts = value
        elif isinstance(value, dict):
            shortcuts = value.get("shortcuts") or value.get("all_shortcuts") or []

    # Match existing shortcut by exe path or app name containing Beat Saber
    target_app_id = None
    for sc in shortcuts or []:
        if not isinstance(sc, dict):
            continue
        exe = str(sc.get("exe") or sc.get("Exes") or sc.get("ShortcutPath") or "")
        name = str(sc.get("appname") or sc.get("AppName") or sc.get("name") or "")
        appid = sc.get("appid") or sc.get("AppID") or sc.get("appId")
        if wrapper in exe or "Beat Saber" in name:
            target_app_id = appid
            break

    if target_app_id is None:
        # Do NOT call AddShortcut unless signature is verified; we only feature-flag presence.
        if val.get("hasAddShortcut"):
            print(json.dumps({
                "status": "needs_manual_create",
                "reason": "AddShortcut is present but signature is not verified by this tool; create the shortcut once in Steam/BSManager, then re-run repair.",
                "wrapper": wrapper,
                "startDir": start_dir,
            }))
            sys.exit(0)
        print(json.dumps({
            "status": "needs_manual_create",
            "reason": "No existing matching shortcut and no verified creation API.",
            "wrapper": wrapper,
            "startDir": start_dir,
        }))
        sys.exit(0)

    # Repair existing shortcut
    repairs = []
    def call(fn, args_js):
        r = rpc(ws, "Runtime.evaluate", {
            "expression": f"window.SteamClient.Apps.{fn}({args_js})",
            "returnByValue": True,
            "awaitPromise": True,
        })
        repairs.append({fn: ((r.get("result") or {}).get("result") or {})})

    app_js = json.dumps(target_app_id)
    call("SetShortcutExe", f"{app_js}, {json.dumps(wrapper)}")
    call("SetShortcutStartDir", f"{app_js}, {json.dumps(start_dir)}")
    if val.get("hasSetShortcutLaunchOptions"):
        call("SetShortcutLaunchOptions", f"{app_js}, {json.dumps('')}")
    if val.get("hasSpecifyCompatTool"):
        call("SpecifyCompatTool", f"{app_js}, {json.dumps('')}")

    print(json.dumps({"status": "repaired", "appId": target_app_id, "repairs": repairs}))
finally:
    ws.close()
PY
}

# Remove only a shortcut whose exe is this helper's wrapper. Never edit shortcuts.vdf.
steam_shortcut_remove() {
    local slug="$1"
    local wrapper port venv status=""
    wrapper="$(launcher_wrapper_path "$slug")"
    if ! port="$(detect_steam_cdp_port)"; then
        warn "$(t launcher_steam_left)"
        return 0
    fi
    venv="$(ensure_cdp_venv)" || {
        warn "$(t launcher_steam_left)"
        return 0
    }
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] CDP remove Steam shortcut for $wrapper"
        return 0
    fi
    status="$("$venv/bin/python" - "$port" "$wrapper" <<'PY'
import json, sys, urllib.request

try:
    import websocket
except ImportError:
    print("left", file=sys.stderr)
    sys.exit(2)

port, wrapper = sys.argv[1], sys.argv[2]

def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)

def rpc(ws, method, params=None):
    global msg_id
    msg_id += 1
    payload = {"id": msg_id, "method": method}
    if params is not None:
        payload["params"] = params
    ws.send(json.dumps(payload))
    while True:
        raw = ws.recv()
        data = json.loads(raw)
        if data.get("id") == msg_id:
            return data

targets = get(f"http://127.0.0.1:{port}/json/list")
shared = None
for t in targets:
    title = (t.get("title") or "") + " " + (t.get("url") or "")
    if "SharedJSContext" in title:
        shared = t
        break
if shared is None or not shared.get("webSocketDebuggerUrl"):
    print("left")
    sys.exit(0)

msg_id = 0
ws = websocket.create_connection(shared["webSocketDebuggerUrl"], timeout=10)
try:
    detect = rpc(ws, "Runtime.evaluate", {
        "expression": """
(() => {
  const apps = (window.SteamClient && window.SteamClient.Apps) ? window.SteamClient.Apps : null;
  if (!apps) return {ok:false};
  const names = Object.getOwnPropertyNames(apps).concat(Object.keys(apps));
  return {
    ok: true,
    hasRemove: typeof apps.RemoveShortcut === 'function',
    hasGet: typeof apps.GetShortcuts === 'function' || typeof apps.GetAllShortcuts === 'function',
  };
})()
""",
        "returnByValue": True,
    })
    val = ((detect.get("result") or {}).get("result") or {}).get("value") or {}
    if not val.get("ok") or not val.get("hasRemove") or not val.get("hasGet"):
        print("left")
        sys.exit(0)
    listed = rpc(ws, "Runtime.evaluate", {
        "expression": """
(() => {
  const apps = window.SteamClient.Apps;
  if (typeof apps.GetShortcuts === 'function') return apps.GetShortcuts();
  if (typeof apps.GetAllShortcuts === 'function') return apps.GetAllShortcuts();
  return [];
})()
""",
        "returnByValue": True,
        "awaitPromise": True,
    })
    value = ((listed.get("result") or {}).get("result") or {}).get("value")
    shortcuts = value if isinstance(value, list) else []
    if isinstance(value, dict):
        shortcuts = value.get("shortcuts") or value.get("all_shortcuts") or []
    removed = 0
    for sc in shortcuts:
        if not isinstance(sc, dict):
            continue
        exe = str(sc.get("exe") or sc.get("ShortcutPath") or "")
        appid = sc.get("appid") or sc.get("AppID") or sc.get("appId")
        if wrapper not in exe or appid is None:
            continue
        rpc(ws, "Runtime.evaluate", {
            "expression": f"window.SteamClient.Apps.RemoveShortcut({json.dumps(appid)})",
            "returnByValue": True,
            "awaitPromise": True,
        })
        removed += 1
    print("removed" if removed else "left")
finally:
    ws.close()
PY
)" || true
    case "$status" in
        *removed*) success "$(t launcher_steam_removed)" ;;
        *) warn "$(t launcher_steam_left)" ;;
    esac
}

# =============================================================================
# Diagnostics / backup / self-update / uninstall
# =============================================================================

report_line() {
    local label="$1"
    local value="$2"
    printf '%-36s %s\n' "$label:" "$value"
}

report_steam_frame_bsmanager() {
    local prov="$BSMANAGER_INSTALL_DIR/$BSMANAGER_PROVENANCE_NAME"
    local kind="" json="" meta="" err="" info_path="" remote_commit="" installed_commit=""
    echo "---- $(t diag_sf_heading) ----"
    printf '%s\n' "$(t bsm_sf_repo "$BSMANAGER_FRAME_RELEASE_REPO")"
    report_line "BSManager upstream" "$UPSTREAM_BSMANAGER_REPO"
    if [[ -e "$BSMANAGER_INSTALL_DIR/bs-manager" ]]; then
        report_line "path" "$BSMANAGER_INSTALL_DIR"
        report_line "architecture" "$(file_arch_of "$BSMANAGER_INSTALL_DIR/bs-manager")"
        report_line "status" "installed"
    else
        report_line "status" "not installed"
    fi
    if [[ -f "$prov" ]]; then
        kind="$(_bsm_json_field "$prov" source_kind)"
        case "$kind" in
            steam-frame-release|"")
                printf '%s\n' "$(t bsm_sf_source_release)"
                report_line "source" "$(_bsm_json_field "$prov" source_repository)"
                report_line "branch" "$(_bsm_json_field "$prov" source_branch)"
                report_line "release" "$(_bsm_json_field "$prov" release_tag)"
                report_line "commit" "$(_bsm_json_field "$prov" source_commit)"
                report_line "BSManager version" "$(_bsm_json_field "$prov" bsmanager_version)"
                ;;
            custom-url)
                printf '%s\n' "$(t bsm_sf_source_url)"
                report_line "url" "$(_bsm_json_field "$prov" source_url)"
                ;;
            local-directory)
                printf '%s\n' "$(t bsm_sf_source_dir)"
                report_line "path" "$(_bsm_json_field "$prov" source_path)"
                ;;
            *)
                printf '%s\n' "$(t bsm_sf_legacy)"
                ;;
        esac
    elif [[ -e "$BSMANAGER_INSTALL_DIR/bs-manager" ]]; then
        printf '%s\n' "$(t bsm_sf_legacy)"
    fi

    echo "---- $(t diag_sf_latest) ----"
    json="$(make_temp_file)"
    if ! fetch_bsmanager_frame_releases_json "$json"; then
        printf '%s\n' "$(t diag_sf_unavailable "network")"
        return 0
    fi
    meta="$(make_temp_file)"
    if ! select_latest_bsmanager_frame_release "$json" >"$meta"; then
        printf '%s\n' "$(t diag_sf_unavailable "malformed")"
        return 0
    fi
    if [[ "$(_bsm_json_field "$meta" ok)" != "true" ]]; then
        err="$(_bsm_json_field "$meta" error)"
        printf '%s\n' "$(t diag_sf_unavailable "${err:-unknown}")"
        return 0
    fi
    report_line "tag" "$(_bsm_json_field "$meta" tag_name)"
    report_line "published" "$(_bsm_json_field "$meta" published_at)"
    info_path="$(make_temp_file)"
    if ! download_bsmanager_frame_asset "$(_bsm_json_field "$meta" build_info_url)" "$info_path"; then
        printf '%s\n' "$(t diag_sf_unavailable "build-info")"
        return 0
    fi
    if ! remote_commit="$(validate_bsmanager_frame_build_info "$info_path")"; then
        printf '%s\n' "$(t diag_sf_unavailable "build-info")"
        return 0
    fi
    report_line "commit" "$remote_commit"
    if [[ -e "$BSMANAGER_INSTALL_DIR/bs-manager" ]]; then
        installed_commit="$(installed_steam_frame_commit 2>/dev/null || true)"
        if [[ -n "$installed_commit" && "$installed_commit" == "$remote_commit" ]]; then
            report_line "update available" "no"
        else
            report_line "update available" "yes"
        fi
    else
        report_line "update available" "n/a"
    fi
    return 0
}

cmd_diagnose() {
    local steam_root="" status arch
    arch="$(detect_arch)"
    status="$(detect_steam_frame)"
    steam_root="$(find_steam_root 2>/dev/null || true)"

    echo "BSManager Frame diagnostics v${VERSION}"
    echo "Generated: $(date -Iseconds 2>/dev/null || date)"
    echo "========================================"
    report_line "Architecture" "$arch"
    report_line "SteamOS" "$(detect_steamos && echo yes || echo no)"
    report_line "Steam Frame detection" "$status"
    report_line "Steam root" "${steam_root:-not found}"
    report_line "Steam running" "$(steam_is_running && echo yes || echo no)"

    echo "---- Steam libraries ----"
    if [[ -n "$steam_root" ]]; then
        list_steam_libraries || true
    else
        echo "(none)"
    fi

    local path
    echo "---- Proton / Runtime ----"
    if path="$(resolve_app_install_path "$PROTON_STABLE_APPID" 2>/dev/null)"; then
        report_line "Proton stable manifest" "AppID $PROTON_STABLE_APPID found"
        report_line "Proton stable path" "$path"
        report_line "Proton stable /proton" "$([[ -e $path/proton ]] && echo yes || echo no)"
        report_line "Proton stable ARM64 wine" "$([[ -e $path/files/bin-arm64/wine ]] && echo yes || echo no)"
        report_line "Proton stable wine layout" "$(proton_wine_layout_summary "$path")"
    else
        report_line "Proton stable ($PROTON_STABLE_APPID)" "missing"
    fi
    if path="$(resolve_app_install_path "$PROTON_EXPERIMENTAL_APPID" 2>/dev/null)"; then
        report_line "Proton experimental path" "$path"
        report_line "Proton experimental /proton" "$([[ -e $path/proton ]] && echo yes || echo no)"
        report_line "Proton experimental ARM64 wine" "$([[ -e $path/files/bin-arm64/wine ]] && echo yes || echo no)"
    else
        report_line "Proton experimental ($PROTON_EXPERIMENTAL_APPID)" "missing"
    fi
    if path="$(resolve_app_install_path "$STEAM_RUNTIME_ARM64_APPID" 2>/dev/null)"; then
        report_line "Steam Linux Runtime ARM64" "$path"
    else
        report_line "Steam Linux Runtime ARM64" "missing"
    fi

    echo "---- BSManager ----"
    local itype support cfg
    itype="$(detect_bsmanager_installation_type)"
    report_line "BSManager installation mode" "$itype"
    report_line "BSManager native" "$(is_bsmanager_native_installed && echo installed || echo "not installed")"
    if [[ -e "$BSMANAGER_INSTALL_DIR/bs-manager" ]]; then
        report_line "Native executable" "$BSMANAGER_INSTALL_DIR/bs-manager"
        report_line "Native architecture" "$(file_arch_of "$BSMANAGER_INSTALL_DIR/bs-manager")"
    else
        report_line "Native executable" "not installed"
    fi
    report_line "Flatpak user" "$(is_bsmanager_flatpak_user_installed && echo installed || echo "not installed")"
    report_line "Flatpak system" "$(is_bsmanager_flatpak_system_installed && echo installed || echo "not installed")"
    if [[ "$itype" == "native+flatpak" ]] || { is_bsmanager_flatpak_user_installed && is_bsmanager_flatpak_system_installed; }; then
        echo "WARNING: multiple BSManager installations detected"
        warn_bsmanager_duplicate_installations || true
    fi
    report_line "BSManager command link" "$([[ -e $BSMANAGER_BIN ]] && readlink -f "$BSMANAGER_BIN" 2>/dev/null || echo "$BSMANAGER_BIN (missing)")"
    report_line "BSManager running" "$(is_bsmanager_running && echo yes || echo no)"
    support="$(bsmanager_supports_prefix_proton)"
    report_line "Separate modding Proton support" "$support"
    report_line "BSManager data directory" "$BSMANAGER_DATA_DIR ($([[ -d $BSMANAGER_DATA_DIR ]] && echo present || echo missing))"
    report_line "BSManager config directory" "$BSMANAGER_CONFIG_DIR"
    if cfg="$(find_bsmanager_config 2>/dev/null)"; then
        report_line "BSManager config file" "$cfg"
        if config_has_prefix_proton_key "$cfg"; then
            report_line "prefix-proton-folder in config" "yes"
        else
            report_line "prefix-proton-folder in config" "no"
        fi
    else
        report_line "BSManager config file" "not found"
        report_line "prefix-proton-folder in config" "n/a"
    fi

    report_steam_frame_bsmanager || true

    echo "---- Beat Saber instances ----"
    refresh_beat_saber_instances || true
    local -a roots=()
    local r i
    mapfile -t roots < <(beat_saber_instances_root) || true
    printf 'Search roots:\n'
    for r in "${roots[@]}"; do
        if [[ -d "$r" ]]; then
            printf '  %s [dir ok]\n' "$r"
        else
            printf '  %s [missing]\n' "$r"
        fi
    done
    if [[ "${#BSMF_BS_NAMES[@]}" -eq 0 ]]; then
        echo "(none)"
    else
        for ((i = 0; i < ${#BSMF_BS_NAMES[@]}; i++)); do
            printf '%s\t%s\n' "${BSMF_BS_NAMES[$i]}" "${BSMF_BS_PATHS[$i]}"
        done
    fi

    echo "---- compatdata candidates ----"
    if [[ -d "$BSMANAGER_DATA_DIR/SharedContent" ]]; then
        find "$BSMANAGER_DATA_DIR/SharedContent" -mindepth 1 -maxdepth 1 -type d -name 'compatdata*' 2>/dev/null || true
    else
        echo "(SharedContent missing)"
    fi

    echo "---- OpenXR / SteamVR ----"
    report_line "/opt/steamvr" "$([[ -d /opt/steamvr ]] && echo present || echo missing)"
    report_line "XR_RUNTIME_JSON" "${XR_RUNTIME_JSON:-<unset>}"

    echo "---- Generated wrappers / desktop ----"
    ls -1 "$LOCAL_BIN"/beat-saber-*-modded 2>/dev/null || echo "(no wrappers)"
    ls -1 "$APPLICATIONS_DIR"/beat-saber-*-modded.desktop \
        "$APPLICATIONS_DIR"/bs-manager.desktop \
        "$APPLICATIONS_DIR"/bsmanager-frame.desktop 2>/dev/null || echo "(no desktop entries)"

    echo "---- Steam CDP ----"
    local port
    if port="$(detect_steam_cdp_port 2>/dev/null)"; then
        report_line "Steam CDP" "127.0.0.1:$port available"
    else
        report_line "Steam CDP" "not detected"
    fi

    echo "========================================"
    success "$(t diag_complete)"
    log_action OK "diagnose"
}

cmd_backup() {
    action_begin backup
    ensure_user_dirs
    local stamp dest
    stamp="$(date +%Y%m%dT%H%M%S)"
    dest="$TOOL_DATA_DIR/backups/manual/$stamp"
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] backup to $dest"
        action_end backup 0 dry-run
        return 0
    fi
    mkdir -p "$dest/wrappers" "$dest/desktop" "$dest/config" "$dest/meta"
    local cfg
    if cfg="$(find_bsmanager_config 2>/dev/null)"; then
        cp -a "$cfg" "$dest/config/" || true
    fi
    cp -a "$LOCAL_BIN"/beat-saber-*-modded "$dest/wrappers/" 2>/dev/null || true
    cp -a "$APPLICATIONS_DIR"/bs-manager.desktop "$dest/desktop/" 2>/dev/null || true
    cp -a "$APPLICATIONS_DIR"/bsmanager-frame.desktop "$dest/desktop/" 2>/dev/null || true
    cp -a "$APPLICATIONS_DIR"/beat-saber-*-modded.desktop "$dest/desktop/" 2>/dev/null || true
    {
        echo "version=$VERSION"
        echo "date=$stamp"
        echo "lang=${UI_LANG:-en}"
        echo "steam_root=$(find_steam_root 2>/dev/null || true)"
    } >"$dest/meta/info.txt"
    success "$(t backup_written "$dest")"
    action_end backup 0 "$dest"
}

create_self_desktop_shortcut() {
    local desktop_path exec_line
    desktop_path="$APPLICATIONS_DIR/bsmanager-frame.desktop"
    exec_line="$(desktop_escape_exec "$SELF_INSTALL_PATH")"

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] write desktop entry $desktop_path"
        success "$(t ok_self_desktop "$desktop_path")"
        return 0
    fi

    mkdir -p "$APPLICATIONS_DIR"
    {
        printf '%s\n' "[Desktop Entry]"
        printf '%s\n' "Type=Application"
        printf '%s\n' "Version=1.0"
        printf '%s\n' "Name=BSManager Frame Script"
        printf '%s\n' "Comment=Unofficial Steam Frame helper for BSManager / modded Beat Saber"
        printf '%s\n' "Exec=$exec_line"
        printf '%s\n' "Terminal=true"
        printf '%s\n' "Categories=Utility;Game;"
        printf '%s\n' "StartupNotify=true"
        printf '%s\n' "Keywords=BeatSaber;BSManager;SteamFrame;"
    } >"$desktop_path"
    chmod +x "$desktop_path" || true

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_cmd update-desktop-database "$APPLICATIONS_DIR" || true
    fi
    success "$(t ok_self_desktop "$desktop_path")"
    log_action OK "self-desktop $desktop_path"
}

maybe_offer_self_desktop_shortcut() {
    local desktop_path="$APPLICATIONS_DIR/bsmanager-frame.desktop"

    if [[ -f "$desktop_path" ]]; then
        debug "self desktop shortcut already present"
        return 0
    fi

    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        # Opt-in only — never create silently in non-interactive mode
        info "$(t skip_self_desktop)"
        log_action SKIP "self-desktop (non-interactive)"
        return 0
    fi

    if prompt_confirm "$(t ask_self_desktop)"; then
        create_self_desktop_shortcut || warn "Could not create desktop shortcut"
    else
        info "$(t skip_self_desktop)"
        log_action SKIP "self-desktop (user declined)"
    fi
}

install_self() {
    ensure_user_dirs
    local src
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        src="$(canonical_path "${BASH_SOURCE[0]}")"
    else
        # Running from pipe — download
        src="$(make_temp_file)"
        download_file \
            "https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/bsmanager-frame.sh" \
            "$src"
    fi
    bash -n "$src" || die "Self-install aborted: bash -n failed"
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] install self to $SELF_INSTALL_PATH"
        maybe_offer_self_desktop_shortcut || true
        return 0
    fi
    mkdir -p "$LOCAL_BIN" "$TOOL_DATA_DIR/backups/self"
    local tmp="$SELF_INSTALL_PATH.new.$$"
    cp -a "$src" "$tmp"
    chmod +x "$tmp"
    if [[ -f "$SELF_INSTALL_PATH" ]]; then
        cp -a "$SELF_INSTALL_PATH" "$TOOL_DATA_DIR/backups/self/bsmanager-frame.prev"
    fi
    mv -f "$tmp" "$SELF_INSTALL_PATH"
    success "$(t self_installed "$SELF_INSTALL_PATH")"
    log_action OK "install-self path=$SELF_INSTALL_PATH"
    case ":$PATH:" in
        *":$LOCAL_BIN:"*) ;;
        *) warn "Add $LOCAL_BIN to PATH to run: bsmanager-frame" ;;
    esac
    maybe_offer_self_desktop_shortcut || true
}

cmd_self_update() {
    ensure_user_dirs
    local tmp
    tmp="$(make_temp_file)"
    download_file \
        "https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/bsmanager-frame.sh" \
        "$tmp"
    bash -n "$tmp" || die "Downloaded script failed bash -n"
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck "$tmp" || warn "ShellCheck reported issues on downloaded script"
    fi
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] replace $SELF_INSTALL_PATH"
        return 0
    fi
    if [[ ! -f "$SELF_INSTALL_PATH" ]]; then
        info "Not installed yet; installing"
        mkdir -p "$LOCAL_BIN" "$TOOL_DATA_DIR/backups/self"
        cp -a "$tmp" "$SELF_INSTALL_PATH"
        chmod +x "$SELF_INSTALL_PATH"
        success "$(t self_installed "$SELF_INSTALL_PATH")"
        maybe_offer_self_desktop_shortcut || true
        return 0
    fi
    mkdir -p "$TOOL_DATA_DIR/backups/self"
    cp -a "$SELF_INSTALL_PATH" "$TOOL_DATA_DIR/backups/self/bsmanager-frame.prev"
    local newf="$SELF_INSTALL_PATH.new.$$"
    cp -a "$tmp" "$newf"
    chmod +x "$newf"
    mv -f "$newf" "$SELF_INSTALL_PATH"
    success "$(t self_updated "$SELF_INSTALL_PATH")"
    log_action OK "self-update path=$SELF_INSTALL_PATH"
}

cmd_uninstall() {
    info "$(t uninstall_frame_about)"
    if ! prompt_confirm "$(t ask_remove_frame)"; then
        return 0
    fi
    if [[ -e "$APPLICATIONS_DIR/bsmanager-frame.desktop" ]]; then
        safe_rm "$APPLICATIONS_DIR/bsmanager-frame.desktop"
    fi
    [[ -e "$SELF_INSTALL_PATH" ]] && safe_rm "$SELF_INSTALL_PATH"
    [[ -d "$TOOL_DATA_DIR" ]] && safe_rm "$TOOL_DATA_DIR"
    [[ -d "$TOOL_STATE_DIR" ]] && safe_rm "$TOOL_STATE_DIR"
    success "$(t uninstall_done)"
    log_action OK "uninstall_frame"
}

cmd_uninstall_bsmanager() {
    local have_app=0
    info "$(t uninstall_bsm_about)"
    if [[ -e "$BSMANAGER_INSTALL_DIR/bs-manager" || -L "$BSMANAGER_BIN" || -e "$BSMANAGER_BIN" || -e "$APPLICATIONS_DIR/bs-manager.desktop" ]]; then
        have_app=1
    fi
    if [[ "$have_app" -eq 0 && ! -d "$BSMANAGER_CONFIG_DIR" ]]; then
        info "$(t uninstall_bsm_missing)"
        if is_bsmanager_flatpak_user_installed || is_bsmanager_flatpak_system_installed; then
            info "$(t bsm_flatpak_left)"
        fi
        return 0
    fi
    if [[ "$FLAG_REMOVE_DATA" -eq 1 ]]; then
        info "$(t launcher_instance_kept)"
    fi
    if is_bsmanager_running; then
        error "$(t bsm_running_uninstall)"
        return 1
    fi
    if [[ "$have_app" -eq 1 ]]; then
        if ! prompt_confirm "$(t ask_remove_bsm_app)"; then
            return 0
        fi
        [[ -e "$BSMANAGER_BIN" || -L "$BSMANAGER_BIN" ]] && safe_rm "$BSMANAGER_BIN"
        [[ -e "$APPLICATIONS_DIR/bs-manager.desktop" ]] && safe_rm "$APPLICATIONS_DIR/bs-manager.desktop"
        [[ -d "$BSMANAGER_INSTALL_DIR" ]] && safe_rm "$BSMANAGER_INSTALL_DIR"
        success "$(t bsm_app_removed)"
        log_action OK "uninstall_bsmanager_app"
    else
        info "$(t uninstall_bsm_missing)"
    fi
    if [[ -d "$BSMANAGER_CONFIG_DIR" ]]; then
        if prompt_confirm_keep "$(t ask_remove_bsm_config "$BSMANAGER_CONFIG_DIR")"; then
            safe_rm "$BSMANAGER_CONFIG_DIR"
            success "$(t bsm_config_removed)"
            log_action OK "uninstall_bsmanager_config"
        else
            info "$(t bsm_config_kept)"
        fi
    fi
    if is_bsmanager_flatpak_user_installed || is_bsmanager_flatpak_system_installed; then
        info "$(t bsm_flatpak_left)"
    fi
}

# =============================================================================
# High-level workflows
# =============================================================================

cmd_proton() {
    assert_platform_or_force
    ensure_required_proton_stack >/dev/null
    configure_bsmanager_proton || true
}

cmd_shortcuts() {
    assert_platform_or_force
    select_beat_saber_version || return 1
    create_desktop_shortcuts "$BSMF_SELECTED_BS_NAME" "$BSMF_SELECTED_BS_DIR" || return 1
    if steam_shortcuts_cdp "$BSMF_SELECTED_BS_NAME" "$BSMF_SELECTED_BS_DIR"; then
        success "Steam shortcut operation finished"
    else
        warn "Steam shortcut repair incomplete — see messages above"
    fi
}

cmd_install() {
    assert_platform_or_force
    ensure_user_dirs
    local steam_root
    steam_root="$(find_steam_root)" || die "Steam not found under ~/.local/share/Steam or ~/.steam/steam"
    success "Steam found: $steam_root"
    list_steam_libraries >/dev/null
    ensure_required_proton_stack >/dev/null

    local itype
    itype="$(detect_bsmanager_installation_type)"
    warn_bsmanager_duplicate_installations || true
    if [[ "$itype" == "none" || "$FLAG_FORCE" -eq 1 ]]; then
        if ! cmd_install_bsmanager; then
            warn "BSManager install incomplete — see messages above (native custom source or --allow-flatpak)"
        fi
    else
        success "BSManager already present ($itype); use 'update' to refresh"
        if is_bsmanager_native_installed; then
            mkdir -p "$LOCAL_BIN"
            ln -sfn "$BSMANAGER_INSTALL_DIR/bs-manager" "$BSMANAGER_BIN" 2>/dev/null || true
        fi
    fi
    mkdir -p "$BSMANAGER_DATA_DIR"
    configure_bsmanager_proton || true
    install_self
    local -a versions=()
    mapfile -t versions < <(list_beat_saber_instances)
    if [[ "${#versions[@]}" -gt 0 ]]; then
        if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
            info "Beat Saber instances found; run: bsmanager-frame shortcuts"
        elif prompt_confirm "$(t ask_shortcuts_now)"; then
            cmd_shortcuts || true
        fi
    fi
    info "Final diagnostics summary:"
    cmd_diagnose
}

cmd_update() {
    assert_platform_or_force
    ensure_user_dirs
    warn_bsmanager_duplicate_installations || true
    info "Checking Steam Frame native BSManager builds..."
    # Preserves install type: native stays native; Flatpak only updates with --allow-flatpak
    local rc=0
    cmd_install_bsmanager || rc=$?
    if is_bsmanager_native_installed; then
        ln -sfn "$BSMANAGER_INSTALL_DIR/bs-manager" "$BSMANAGER_BIN"
        success "BSManager command link repaired"
        # Preserving native when upstream has no native asset is success (rc may be 0)
    fi
    info "Note: bsmanager-frame itself is not auto-updated; run: bsmanager-frame self-update"
    return "$rc"
}

cmd_setup() {
    cmd_install
}

# =============================================================================
# Interactive menu / CLI
# =============================================================================

remove_managed_launcher() {
    local slug="$1"
    local label="$2"
    local wrapper desktop
    wrapper="$(launcher_wrapper_path "$slug")"
    desktop="$(launcher_desktop_path "$slug")"
    steam_shortcut_remove "$slug" || true
    [[ -e "$wrapper" ]] && safe_rm "$wrapper"
    [[ -e "$desktop" ]] && safe_rm "$desktop"
    if command -v update-desktop-database >/dev/null 2>&1; then
        run_cmd update-desktop-database "$APPLICATIONS_DIR" || true
    fi
    success "$(t launcher_deleted "$label")"
    info "$(t launcher_instance_kept)"
    log_action OK "launcher_removed slug=$slug"
}

menu_launchers() {
    local choice="" i=0 count=0 answer=""
    local wrap_s="" desk_s="" orphan_s=""
    tty_open || true
    while true; do
        refresh_managed_launchers || true
        count="${#BSMF_LAUNCHER_SLUGS[@]}"
        tty_printf '\n%s\n' "$(t launcher_title)"
        if [[ "$count" -eq 0 ]]; then
            tty_printf '%s\n' "$(t bs_versions_none)"
        fi
        for ((i = 0; i < count; i++)); do
            if [[ "${BSMF_LAUNCHER_HAS_WRAPPER[$i]}" -eq 1 ]]; then
                wrap_s="$(t launcher_present)"
            else
                wrap_s="$(t launcher_absent)"
            fi
            if [[ "${BSMF_LAUNCHER_HAS_DESKTOP[$i]}" -eq 1 ]]; then
                desk_s="$(t launcher_present)"
            else
                desk_s="$(t launcher_absent)"
            fi
            orphan_s=""
            if [[ "${BSMF_LAUNCHER_ORPHAN[$i]}" -eq 1 ]]; then
                orphan_s="$(t launcher_orphan)"
            fi
            tty_printf '  %d) %s\n' "$((i + 1))" \
                "$(t launcher_line "${BSMF_LAUNCHER_LABELS[$i]}" "$wrap_s" "$desk_s" "$orphan_s")"
            if [[ -n "${BSMF_LAUNCHER_DIRS[$i]}" ]]; then
                tty_printf '     %s\n' "${BSMF_LAUNCHER_DIRS[$i]}"
            fi
        done
        tty_printf '\na) %s\n' "$(t launcher_add)"
        tty_printf 'd) %s\n' "$(t launcher_delete)"
        tty_printf '0) %s\n\n' "$(t launcher_back)"
        choice="$(prompt_reply "$(t menu_select)" "")"
        choice="${choice%%[[:space:]]*}"
        case "$choice" in
            a|A)
                if select_beat_saber_version; then
                    install_beat_saber_launcher "$BSMF_SELECTED_BS_NAME" "$BSMF_SELECTED_BS_DIR" || true
                fi
                ;;
            d|D)
                if [[ "$count" -eq 0 ]]; then
                    info "$(t launcher_none_delete)"
                    continue
                fi
                answer="$(prompt_reply "$(t launcher_pick)" "")"
                if [[ ! "$answer" =~ ^[0-9]+$ ]] || ((answer < 1 || answer > count)); then
                    tty_printf '%s\n' "$(t menu_invalid)"
                    continue
                fi
                i=$((answer - 1))
                if [[ "${BSMF_LAUNCHER_HAS_WRAPPER[$i]}" -eq 0 && "${BSMF_LAUNCHER_HAS_DESKTOP[$i]}" -eq 0 ]]; then
                    info "$(t launcher_none_delete)"
                    continue
                fi
                if prompt_confirm "$(t launcher_confirm_delete "${BSMF_LAUNCHER_LABELS[$i]}")"; then
                    remove_managed_launcher "${BSMF_LAUNCHER_SLUGS[$i]}" "${BSMF_LAUNCHER_LABELS[$i]}" || true
                fi
                ;;
            0|q|Q) return 0 ;;
            *) tty_printf '%s\n' "$(t menu_invalid)" ;;
        esac
    done
}

show_menu() {
    if ! have_tty && [[ "$FLAG_NON_INTERACTIVE" -ne 1 ]]; then
        die "$(t menu_needs_tty)"
    fi
    local choice=""
    local n_bs=0
    local i=0
    local -a _roots=()
    local _r=""
    tty_open || true
    while true; do
        refresh_beat_saber_instances || true
        n_bs="${#BSMF_BS_NAMES[@]}"

        tty_printf '\n%s\n\n' "$(t menu_banner "$VERSION")"
        if [[ "$n_bs" -gt 0 ]]; then
            tty_printf '%s\n' "$(t bs_versions_detected)"
            for ((i = 0; i < n_bs; i++)); do
                tty_printf '  - %s\n' "${BSMF_BS_NAMES[$i]}"
                tty_printf '    %s\n' "${BSMF_BS_PATHS[$i]}"
            done
            tty_printf '\n'
        else
            tty_printf '%s\n' "$(t bs_versions_none)"
            _roots=()
            mapfile -t _roots < <(beat_saber_instances_root) || true
            for _r in "${_roots[@]}"; do
                [[ -n "$_r" ]] || continue
                if [[ -d "$_r" ]]; then
                    tty_printf '  %s [dir ok]\n' "$_r"
                else
                    tty_printf '  %s [missing]\n' "$_r"
                fi
            done
            tty_printf '\n'
        fi
        tty_printf '1) %s\n' "$(t menu_1)"
        tty_printf '2) %s\n' "$(t menu_2)"
        tty_printf '3) %s\n' "$(t menu_3)"
        tty_printf '4) %s\n' "$(t menu_4)"
        tty_printf '5) %s\n' "$(t menu_6)"
        tty_printf '6) %s\n' "$(t menu_7)"
        tty_printf '7) %s\n' "$(t menu_8)"
        tty_printf '8) %s\n' "$(t menu_uninstall_frame)"
        tty_printf '9) %s\n' "$(t menu_uninstall_bsmanager)"
        tty_printf '10) %s\n' "$(t menu_10)"
        tty_printf '0) %s\n\n' "$(t menu_0)"
        choice="$(prompt_reply "$(t menu_select)" "")"
        choice="${choice%%[[:space:]]*}"
        case "$choice" in
            1) run_menu_action install cmd_install ;;
            2) run_menu_action update cmd_update ;;
            3) run_menu_action proton cmd_proton ;;
            4) run_menu_action launchers menu_launchers ;;
            5) run_menu_action diagnose cmd_diagnose ;;
            6) run_menu_action backup cmd_backup ;;
            7) run_menu_action self-update cmd_self_update ;;
            8) run_menu_action uninstall cmd_uninstall ;;
            9) run_menu_action uninstall-bsmanager cmd_uninstall_bsmanager ;;
            10|l|L)
                prompt_language_selection || true
                ;;
            0|q|Q)
                log_action OK "menu_quit"
                return 0
                ;;
            *) tty_printf '%s (%q)\n' "$(t menu_invalid)" "$choice" ;;
        esac
    done
}
usage() {
    cat <<EOF
BSManager Frame v${VERSION}

Unofficial Steam Frame ARM64 helper for BSManager and modded Beat Saber.

Usage:
  bsmanager-frame [global options] [command] [command options]

Commands:
  install          Detect platform, Proton, install/repair BSManager
                   (native build: Steam Frame releases from sannier3/bs-manager)
  update           Update BSManager from the latest valid steam-frame-* release
  setup            Alias for install
  proton           Ensure Proton stack and configure BSManager paths
  shortcuts        Add or repair the Beat Saber launcher, desktop entry, and Steam shortcut
  diagnose         Print diagnostics report
  backup           Backup small integration/config files
  self-update      Update this tool from GitHub
  install-self     Install this script to ~/.local/bin/bsmanager-frame
  uninstall        Remove bsmanager-frame only
  uninstall-bsmanager
                   Remove the BSManager application. Settings are kept unless
                   you explicitly confirm their removal. Instances, maps, and
                   saves are not removed.
  help             Show this help
  version          Show version

Global options:
  --yes                Assume yes for safe confirmations
  --non-interactive    Fail instead of prompting
  --dry-run            Print actions without mutating
  --verbose            Debug logging to stderr
  --force              Continue on unknown platform / force reinstall
  --allow-flatpak      Experimental opt-in only. The official Flatpak v1.6.0
                       predates the Steam Frame fixes (including PR #1136)
                       and is not a validated Frame-compatible alternative.
  --lang <code>        UI language: en, fr, es, de, sw
  --help               Show help
  --version            Show version

Command options:
  --version <ver>      Beat Saber instance version
  --compatdata <path>  Explicit compatdata path
  --bsmanager-url URL  Custom BSManager asset URL
  --bsmanager-dir PATH Local unpacked native BSManager build
  --remove-data        Accepted for compatibility. It does not delete Beat Saber
                       instances, maps, or saves. BSManager settings are removed
                       only by an explicit answer when uninstalling BSManager.

Environment:
  BSMF_LANG, BSMF_ALLOW_FLATPAK, BSMF_PROTON_STABLE_APPID,
  BSMF_PROTON_EXPERIMENTAL_APPID, BSMF_STEAM_RUNTIME_ARM64_APPID,
  BSMF_STEAM_INSTALL_TIMEOUT, BSMF_STEAM_POLL_INTERVAL,
  BSMANAGER_ASSET_URL, GITHUB_TOKEN, NO_COLOR
  BSMF_BSMANAGER_RELEASE_REPO       Advanced: Steam Frame release repo
                                    (default sannier3/bs-manager)
  BSMF_BSMANAGER_RELEASE_TAG_PREFIX Advanced: release tag prefix
                                    (default steam-frame-)

Logs:
  ${XDG_STATE_HOME:-~/.local/state}/bsmanager-frame/bsmanager-frame.log
  ${XDG_STATE_HOME:-~/.local/state}/bsmanager-frame/actions.log

EOF
}

parse_args() {
    local -a positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) FLAG_YES=1; shift ;;
            --non-interactive) FLAG_NON_INTERACTIVE=1; shift ;;
            --dry-run) FLAG_DRY_RUN=1; shift ;;
            --verbose|-v) FLAG_VERBOSE=1; shift ;;
            --force) FLAG_FORCE=1; shift ;;
            --allow-flatpak) FLAG_ALLOW_FLATPAK=1; shift ;;
            --remove-data) FLAG_REMOVE_DATA=1; shift ;;
            --lang)
                OPT_LANG="${2:-}"
                [[ -n "$OPT_LANG" ]] || die "--lang requires a code (en|fr|es|de|sw)"
                shift 2
                ;;
            --help|-h) COMMAND="help"; shift ;;
            --version)
                # Ambiguous: global version vs beat saber version flag after command.
                # If COMMAND empty and next looks like option/end -> show tool version.
                if [[ -z "$COMMAND" && $# -eq 1 ]]; then
                    COMMAND="version"
                    shift
                elif [[ -n "${2:-}" && "$2" != -* ]]; then
                    OPT_BS_VERSION="$2"
                    shift 2
                else
                    COMMAND="version"
                    shift
                fi
                ;;
            --compatdata)
                OPT_COMPATDATA="${2:-}"
                [[ -n "$OPT_COMPATDATA" ]] || die "--compatdata requires a path"
                shift 2
                ;;
            --bsmanager-url)
                OPT_BSMANAGER_URL="${2:-}"
                [[ -n "$OPT_BSMANAGER_URL" ]] || die "--bsmanager-url requires a URL"
                shift 2
                ;;
            --bsmanager-dir)
                OPT_BSMANAGER_DIR="${2:-}"
                [[ -n "$OPT_BSMANAGER_DIR" ]] || die "--bsmanager-dir requires a path"
                shift 2
                ;;
            --)
                shift
                positional+=("$@")
                break
                ;;
            -*)
                die "$(t unknown_option "$1")"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -gt 0 ]]; then
        COMMAND="${positional[0]}"
        if [[ ${#positional[@]} -gt 1 ]]; then
            # Allow: shortcuts --version already handled; leftover unused
            local i
            for ((i = 1; i < ${#positional[@]}; i++)); do
                warn "Ignoring extra argument: ${positional[$i]}"
            done
        fi
    fi
}

run_cli_command() {
    local name="$1"
    shift
    local rc=0
    action_begin "$name"
    "$@" || rc=$?
    action_end "$name" "$rc"
    return "$rc"
}

main() {
    local rc=0
    _init_color
    parse_args "$@"

    # help/version do not require language setup beyond optional env
    case "${COMMAND}" in
        help|version) ;;
        *)
            ensure_language || true
            UI_LANG="${UI_LANG:-en}"
            ;;
    esac

    case "${COMMAND}" in
        "" )
            # If piped with no command, offer install-oriented flow
            if ! have_tty; then
                UI_LANG="${UI_LANG:-en}"
                info "$(t pipe_installing)"
                FLAG_NON_INTERACTIVE=1
                FLAG_YES=1
                run_cli_command install-self install_self || true
                info "$(t pipe_installed)"
                return 0
            fi
            show_menu || rc=$?
            ;;
        install) run_cli_command install cmd_install || rc=$? ;;
        update) run_cli_command update cmd_update || rc=$? ;;
        setup) run_cli_command setup cmd_setup || rc=$? ;;
        proton) run_cli_command proton cmd_proton || rc=$? ;;
        shortcuts) run_cli_command shortcuts cmd_shortcuts || rc=$? ;;
        diagnose) run_cli_command diagnose cmd_diagnose || rc=$? ;;
        backup) run_cli_command backup cmd_backup || rc=$? ;;
        self-update) run_cli_command self-update cmd_self_update || rc=$? ;;
        install-self) run_cli_command install-self install_self || rc=$? ;;
        uninstall) run_cli_command uninstall cmd_uninstall || rc=$? ;;
        uninstall-bsmanager) run_cli_command uninstall-bsmanager cmd_uninstall_bsmanager || rc=$? ;;
        help) usage ;;
        version) printf '%s\n' "$VERSION" ;;
        *)
            error "$(t unknown_command "$COMMAND")"
            usage
            return 1
            ;;
    esac
    return "$rc"
}

if [[ "${BSMF_LIB_ONLY:-0}" == "1" ]]; then
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    fi
    exit 0
fi

main "$@" || exit $?
