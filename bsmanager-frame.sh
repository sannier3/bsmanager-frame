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

VERSION="0.1.0"
GITHUB_OWNER="sannier3"
GITHUB_REPO="bsmanager-frame"
UPSTREAM_BSMANAGER_REPO="Zagrios/bs-manager"

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
    printf '%s %s\n' "$(_c 34 '[INFO]')" "$*"
}

success() {
    _log_to_file OK "$*"
    printf '%s %s\n' "$(_c 32 '[OK]')" "$*"
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
        confirm_yn) printf '%s' "%s [y/N]" ;;
        prompt_no_tty) printf '%s' "No /dev/tty available for interactive prompt. Re-run with --non-interactive and required options, or from a terminal." ;;
        prompt_need_value) printf '%s' "Non-interactive mode requires an explicit value for: %s" ;;
        err_action_failed) printf '%s' "Action failed: %s (exit %s). Returning to menu." ;;
        err_see_logs) printf '%s' "Details: %s | actions: %s" ;;
        err_interrupted) printf '%s' "Interrupted — cleaning up temporary files." ;;
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
        ask_flatpak) printf '%s' "Install Flatpak fallback (%s)? (advanced, explicit opt-in)" ;;
        bsm_native_preserved) printf '%s' "Current native ARM64 BSManager installation preserved" ;;
        bsm_no_native_asset) printf '%s' "Compatible native ARM64 release asset: not available" ;;
        bsm_latest_release) printf '%s' "Latest upstream BSManager release: %s" ;;
        bsm_kept_unchanged) printf '%s' "Current native ARM64 installation kept unchanged" ;;
        bsm_no_native_fresh) printf '%s' "No native ARM64 BSManager release asset is currently available upstream." ;;
        bsm_use_custom) printf '%s' "Use a custom native ARM64 build with --bsmanager-url URL or --bsmanager-dir PATH" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak is available only as an explicit advanced fallback (--allow-flatpak)." ;;
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
        confirm_yn) printf '%s' "%s [o/N]" ;;
        prompt_no_tty) printf '%s' "Pas de /dev/tty pour les invites. Relancez avec --non-interactive et les options requises, ou depuis un terminal." ;;
        prompt_need_value) printf '%s' "Le mode non interactif exige une valeur explicite pour : %s" ;;
        err_action_failed) printf '%s' "Action échouée : %s (code %s). Retour au menu." ;;
        err_see_logs) printf '%s' "Détails : %s | actions : %s" ;;
        err_interrupted) printf '%s' "Interrompu — nettoyage des fichiers temporaires." ;;
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
        ask_flatpak) printf '%s' "Installer le fallback Flatpak (%s) ? (avancé, opt-in explicite)" ;;
        bsm_native_preserved) printf '%s' "Installation native ARM64 BSManager actuelle conservée" ;;
        bsm_no_native_asset) printf '%s' "Artefact natif ARM64 compatible : indisponible" ;;
        bsm_latest_release) printf '%s' "Dernière release BSManager upstream : %s" ;;
        bsm_kept_unchanged) printf '%s' "Installation native ARM64 actuelle inchangée" ;;
        bsm_no_native_fresh) printf '%s' "Aucun artefact BSManager natif ARM64 n'est disponible upstream pour le moment." ;;
        bsm_use_custom) printf '%s' "Utilisez un build natif ARM64 custom avec --bsmanager-url URL ou --bsmanager-dir PATH" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak n'est disponible qu'en fallback avancé explicite (--allow-flatpak)." ;;
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
        confirm_yn) printf '%s' "%s [s/N]" ;;
        prompt_no_tty) printf '%s' "No hay /dev/tty para prompts. Use --non-interactive y las opciones necesarias, o un terminal." ;;
        prompt_need_value) printf '%s' "El modo no interactivo requiere un valor explícito para: %s" ;;
        err_action_failed) printf '%s' "Acción fallida: %s (código %s). Volviendo al menú." ;;
        err_see_logs) printf '%s' "Detalles: %s | acciones: %s" ;;
        err_interrupted) printf '%s' "Interrumpido — limpiando archivos temporales." ;;
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
        ask_flatpak) printf '%s' "¿Instalar el fallback Flatpak (%s)? (avanzado, opt-in explícito)" ;;
        bsm_native_preserved) printf '%s' "Instalación nativa ARM64 de BSManager conservada" ;;
        bsm_no_native_asset) printf '%s' "Artefacto nativo ARM64 compatible: no disponible" ;;
        bsm_latest_release) printf '%s' "Última versión upstream de BSManager: %s" ;;
        bsm_kept_unchanged) printf '%s' "Instalación nativa ARM64 actual sin cambios" ;;
        bsm_no_native_fresh) printf '%s' "No hay artefacto nativo ARM64 de BSManager disponible upstream por ahora." ;;
        bsm_use_custom) printf '%s' "Use un build nativo ARM64 personalizado con --bsmanager-url URL o --bsmanager-dir PATH" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak solo está disponible como fallback avanzado explícito (--allow-flatpak)." ;;
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
        confirm_yn) printf '%s' "%s [j/N]" ;;
        prompt_no_tty) printf '%s' "Kein /dev/tty für Eingaben. Mit --non-interactive und Optionen oder im Terminal erneut ausführen." ;;
        prompt_need_value) printf '%s' "Nicht-interaktiver Modus benötigt einen expliziten Wert für: %s" ;;
        err_action_failed) printf '%s' "Aktion fehlgeschlagen: %s (Code %s). Zurück zum Menü." ;;
        err_see_logs) printf '%s' "Details: %s | Aktionen: %s" ;;
        err_interrupted) printf '%s' "Abgebrochen — temporäre Dateien werden bereinigt." ;;
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
        ask_flatpak) printf '%s' "Flatpak-Fallback (%s) installieren? (erweitert, explizites Opt-in)" ;;
        bsm_native_preserved) printf '%s' "Aktuelle native ARM64-BSManager-Installation beibehalten" ;;
        bsm_no_native_asset) printf '%s' "Kompatibles natives ARM64-Release-Asset: nicht verfügbar" ;;
        bsm_latest_release) printf '%s' "Neueste Upstream-BSManager-Version: %s" ;;
        bsm_kept_unchanged) printf '%s' "Aktuelle native ARM64-Installation unverändert" ;;
        bsm_no_native_fresh) printf '%s' "Derzeit ist kein natives ARM64-BSManager-Asset upstream verfügbar." ;;
        bsm_use_custom) printf '%s' "Nutzen Sie einen eigenen nativen ARM64-Build mit --bsmanager-url URL oder --bsmanager-dir PATH" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak ist nur als expliziter erweiterter Fallback verfügbar (--allow-flatpak)." ;;
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
        confirm_yn) printf '%s' "%s [d/H]" ;;
        prompt_no_tty) printf '%s' "Hakuna /dev/tty. Tumia --non-interactive na chaguo zinazohitajika, au terminal." ;;
        prompt_need_value) printf '%s' "Hali isiyo ya maingiliano inahitaji thamani wazi kwa: %s" ;;
        err_action_failed) printf '%s' "Kitendo kimeshindwa: %s (kodi %s). Kurudi kwenye menyu." ;;
        err_see_logs) printf '%s' "Maelezo: %s | vitendo: %s" ;;
        err_interrupted) printf '%s' "Imekatizwa — kusafisha faili za muda." ;;
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
        ask_flatpak) printf '%s' "Sakinisha fallback ya Flatpak (%s)? (ya juu, opt-in wazi)" ;;
        bsm_native_preserved) printf '%s' "Usakinishaji wa asili wa BSManager ARM64 umehifadhiwa" ;;
        bsm_no_native_asset) printf '%s' "Faili asilia ya ARM64 inayooana: haipatikani" ;;
        bsm_latest_release) printf '%s' "Toleo jipya la BSManager upstream: %s" ;;
        bsm_kept_unchanged) printf '%s' "Usakinishaji wa asili wa ARM64 haujabadilishwa" ;;
        bsm_no_native_fresh) printf '%s' "Hakuna faili asilia ya BSManager ARM64 inayopatikana upstream kwa sasa." ;;
        bsm_use_custom) printf '%s' "Tumia build asilia ya ARM64 kwa --bsmanager-url URL au --bsmanager-dir PATH" ;;
        bsm_flatpak_advanced) printf '%s' "Flatpak inapatikana tu kama fallback ya juu (--allow-flatpak)." ;;
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
    [[ -r /dev/tty && -w /dev/tty ]]
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

py_select_bsmanager_asset() {
    require_python3
    python3 - "$@" <<'PY'
import json, sys, re

path = sys.argv[1]
prefer = sys.argv[2]  # native|flatpak|any
with open(path, encoding="utf-8") as f:
    release = json.load(f)

assets = release.get("assets") or []
tag = release.get("tag_name") or release.get("name") or ""

native_re = re.compile(r"(arm64|aarch64|linux-arm64|linux-aarch64)", re.I)
flatpak_re = re.compile(r"\.flatpak$", re.I)
archive_re = re.compile(r"\.(tar\.gz|tgz|tar\.xz|zip)$", re.I)
linux_re = re.compile(r"linux", re.I)
x86_re = re.compile(r"(x86_64|amd64|x64(?!.*arm)|win|windows|darwin|mac)", re.I)

def score_native(name: str) -> int:
    if not native_re.search(name):
        return -1
    if x86_re.search(name) and not native_re.search(name):
        return -1
    if not archive_re.search(name):
        return -1
    s = 10
    if linux_re.search(name):
        s += 5
    if name.lower().endswith((".tar.gz", ".tgz", ".tar.xz")):
        s += 2
    return s

def score_flatpak(name: str) -> int:
    if not flatpak_re.search(name):
        return -1
    if not native_re.search(name):
        return -1
    return 10

best = None
best_score = -1
kind = None
for a in assets:
    name = a.get("name") or ""
    url = a.get("browser_download_url") or ""
    if not url:
        continue
    if prefer in ("native", "any"):
        sc = score_native(name)
        if sc > best_score:
            best, best_score, kind = a, sc, "native"
    if prefer in ("flatpak", "any") and (prefer == "flatpak" or best is None or kind != "native"):
        sc = score_flatpak(name)
        # Only choose flatpak if no native found when prefer=any
        pass

# Prefer native over flatpak when prefer=any
native_best = None
native_score = -1
flatpak_best = None
flatpak_score = -1
for a in assets:
    name = a.get("name") or ""
    url = a.get("browser_download_url") or ""
    if not url:
        continue
    sc = score_native(name)
    if sc > native_score:
        native_best, native_score = a, sc
    sc = score_flatpak(name)
    if sc > flatpak_score:
        flatpak_best, flatpak_score = a, sc

chosen = None
chosen_kind = ""
if prefer == "native":
    chosen, chosen_kind = native_best, "native"
elif prefer == "flatpak":
    chosen, chosen_kind = flatpak_best, "flatpak"
else:
    if native_best is not None:
        chosen, chosen_kind = native_best, "native"
    else:
        chosen, chosen_kind = flatpak_best, "flatpak"

if chosen is None:
    print(json.dumps({"ok": False, "tag": tag, "error": "no matching asset"}))
    sys.exit(0)

print(json.dumps({
    "ok": True,
    "tag": tag,
    "kind": chosen_kind,
    "name": chosen.get("name"),
    "url": chosen.get("browser_download_url"),
    "native_available": native_best is not None,
    "flatpak_available": flatpak_best is not None,
    "flatpak_name": (flatpak_best or {}).get("name"),
    "flatpak_url": (flatpak_best or {}).get("browser_download_url"),
}))
PY
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
    require_python3
    python3 - <<'PY'
import sys, re
items = [ln.rstrip("\n") for ln in sys.stdin if ln.strip()]
def key(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]
for i in sorted(items, key=key):
    print(i)
PY
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

request_steam_install() {
    local appid="$1"
    local label="$2"
    local uri="steam://install/${appid}"

    info "Requesting Steam install for $label (AppID $appid)"
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] open $uri"
        return 0
    fi

    if command -v steam >/dev/null 2>&1; then
        steam "$uri" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$uri" >/dev/null 2>&1 || true
    else
        warn "Neither steam nor xdg-open found. Open this URI manually: $uri"
        return 0
    fi
    success "Triggered $uri"
}

wait_for_app_manifest() {
    local appid="$1"
    local label="$2"
    local timeout="${3:-$STEAM_INSTALL_TIMEOUT}"
    local elapsed=0
    local step=5
    local path=""

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] wait for appmanifest_${appid}.acf"
        return 0
    fi

    info "Waiting for $label (timeout ${timeout}s)..."
    while ((elapsed < timeout)); do
        if path="$(resolve_app_install_path "$appid" 2>/dev/null)"; then
            success "$label appeared: $path"
            return 0
        fi
        if [[ "$FLAG_NON_INTERACTIVE" -eq 0 ]] && have_tty; then
            printf '\r  ... %ss elapsed' "$elapsed" >/dev/tty
        fi
        sleep "$step"
        elapsed=$((elapsed + step))
    done
    if [[ "$FLAG_NON_INTERACTIVE" -eq 0 ]] && have_tty; then
        printf '\n' >/dev/tty
    fi
    error "Timed out waiting for $label (AppID $appid)"
    return 1
}

ensure_steam_app() {
    local appid="$1"
    local label="$2"
    local path=""

    if path="$(resolve_app_install_path "$appid" 2>/dev/null)"; then
        success "$label: installed ($path)"
        printf '%s\n' "$path"
        return 0
    fi

    warn "$label: not installed"
    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 && "$FLAG_YES" -ne 1 ]]; then
        die "Missing $label (AppID $appid). Install via Steam or re-run interactively / with --yes."
    fi
    if [[ "$FLAG_NON_INTERACTIVE" -eq 0 ]]; then
        if ! prompt_confirm "$(t ask_steam_install "$label")"; then
            die "Cannot continue without $label"
        fi
    fi
    if steam_is_running; then
        debug "Steam appears to be running; will not restart it"
    else
        warn "Steam does not appear to be running; install URI may queue until Steam starts"
    fi
    request_steam_install "$appid" "$label"
    wait_for_app_manifest "$appid" "$label" || return 1
    path="$(resolve_app_install_path "$appid")" || return 1
    printf '%s\n' "$path"
}

ensure_required_proton_stack() {
    local runtime_path="" proton_path experimental_path

    # 1–2: install/validate Proton titles first (Steam may pull the runtime as a dependency)
    proton_path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL")" || return 1
    validate_proton_install "$proton_path" "$PROTON_STABLE_LABEL" || return 1

    experimental_path="$(ensure_steam_app "$PROTON_EXPERIMENTAL_APPID" "$PROTON_EXPERIMENTAL_LABEL")" || return 1
    validate_proton_install "$experimental_path" "$PROTON_EXPERIMENTAL_LABEL" || return 1

    # 3–4: verify runtime afterward; only request install if still missing
    if runtime_path="$(resolve_app_install_path "$STEAM_RUNTIME_ARM64_APPID" 2>/dev/null)"; then
        success "$STEAM_RUNTIME_LABEL: installed ($runtime_path)"
    else
        info "$STEAM_RUNTIME_LABEL not found after Proton installs; requesting explicitly"
        runtime_path="$(ensure_steam_app "$STEAM_RUNTIME_ARM64_APPID" "$STEAM_RUNTIME_LABEL")" || return 1
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
        if hit="$(grep -aRl -F -- 'prefix-proton-folder' "$candidate" 2>/dev/null | head -n1)"; then
            if [[ -n "$hit" ]]; then
                printf 'supported\n'
                return 0
            fi
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
    candidate="$(find "$root" -type f -name 'bs-manager' 2>/dev/null | head -n1 || true)"
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

fetch_latest_bsmanager_release_json() {
    local out="$1"
    download_file \
        "https://api.github.com/repos/${UPSTREAM_BSMANAGER_REPO}/releases/latest" \
        "$out" \
        "Accept: application/vnd.github+json"
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

handle_no_native_upstream_asset() {
    local tag="$1"
    local flatpak_name="${2:-}"
    local flatpak_url="${3:-}"
    local itype
    itype="$(detect_bsmanager_installation_type)"

    info "$(t bsm_latest_release "${tag:-unknown}")"
    info "$(t bsm_no_native_asset)"

    if is_bsmanager_native_installed; then
        success "$(t bsm_native_preserved)"
        info "$(t bsm_kept_unchanged)"
        info "Advanced options: --bsmanager-url URL | --bsmanager-dir PATH | --allow-flatpak"
        return 0
    fi

    case "$itype" in
        flatpak-user|flatpak-system|unknown)
            if [[ "$FLAG_ALLOW_FLATPAK" -eq 1 && -n "$flatpak_url" ]]; then
                install_bsmanager_flatpak_bundle "$flatpak_url" "${flatpak_name:-bsmanager.flatpak}" || return 1
                return 0
            fi
            info "$(t bsm_flatpak_update_hint)"
            info "$(t bsm_use_custom)"
            return 0
            ;;
    esac

    # Fresh install, no native asset
    error "$(t bsm_no_native_fresh)"
    info "$(t bsm_use_custom)"
    info "$(t bsm_flatpak_advanced)"
    if [[ "$FLAG_ALLOW_FLATPAK" -eq 1 && -n "$flatpak_url" ]]; then
        install_bsmanager_flatpak_bundle "$flatpak_url" "${flatpak_name:-bsmanager.flatpak}" || return 1
        return 0
    fi
    return 1
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
                ;;
        esac
        return 0
    fi

    local json meta native_ok=0 tag="" url="" name="" flatpak_url="" flatpak_name=""
    json="$(make_temp_file)"
    fetch_latest_bsmanager_release_json "$json"

    # Prefer native-only selection for the normal path
    meta="$(py_select_bsmanager_asset "$json" native)"
    debug "native asset meta: $meta"
    if printf '%s' "$meta" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("ok") else 1)'; then
        native_ok=1
        tag="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag",""))')"
        url="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
        name="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
    else
        # Gather flatpak metadata for messaging / explicit opt-in only
        meta="$(py_select_bsmanager_asset "$json" flatpak)"
        if printf '%s' "$meta" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("ok") else 1)'; then
            tag="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag",""))')"
            flatpak_url="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')"
            flatpak_name="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')"
        else
            # Try to read tag from release json even without assets
            tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("tag_name",""))' "$json" 2>/dev/null || true)"
        fi
    fi

    if [[ "$native_ok" -eq 1 ]]; then
        # Do not side-install native over an existing Flatpak-only setup without confirmation
        local itype
        itype="$(detect_bsmanager_installation_type)"
        if [[ "$itype" == "flatpak-user" || "$itype" == "flatpak-system" || "$itype" == "unknown" ]]; then
            if is_bsmanager_flatpak_user_installed || is_bsmanager_flatpak_system_installed; then
                if ! is_bsmanager_native_installed; then
                    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 && "$FLAG_YES" -ne 1 ]]; then
                        die "Flatpak BSManager present. Confirm native side-install with --yes, or manage Flatpak with --allow-flatpak."
                    fi
                    if [[ "$FLAG_NON_INTERACTIVE" -eq 0 ]]; then
                        warn "$(t bsm_dup_warn)"
                        if ! prompt_confirm "Install native BSManager alongside existing Flatpak?"; then
                            return 1
                        fi
                    fi
                fi
            fi
        fi
        info "Downloading native BSManager $tag ($name)"
        local tmp archive
        tmp="$(make_temp_dir)"
        archive="$tmp/$name"
        download_file "$url" "$archive"
        mkdir -p "$tmp/extract"
        extract_archive "$archive" "$tmp/extract"
        install_native_bsmanager_from_dir "$tmp/extract"
        return 0
    fi

    handle_no_native_upstream_asset "$tag" "$flatpak_name" "$flatpak_url"
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

    if ! config_path="$(find_bsmanager_config)"; then
        warn "BSManager config.json not found yet (electron-store under ~/.config/bs-manager)."
        info "$(t bsm_launch_once)"
        show_manual_proton_instructions "$proton_path" "$experimental_path"
        return 1
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
            info "$(t bsm_prefix_unknown)"
            show_manual_proton_instructions "$proton_path" "$experimental_path"
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

list_beat_saber_instances() {
    local root="$BSMANAGER_DATA_DIR/BSInstances"
    [[ -d "$root" ]] || return 0
    local dir
    find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
        if [[ -f "$dir/Beat Saber.exe" ]]; then
            basename "$dir"
        fi
    done | py_natural_sort
}

select_beat_saber_version() {
    local -a versions=()
    local i answer="" count default_num=""
    mapfile -t versions < <(list_beat_saber_instances | grep -v '^$' || true)
    count="${#versions[@]}"

    if [[ "$count" -eq 0 ]]; then
        die "$(t bs_version_none_die "$BSMANAGER_DATA_DIR/BSInstances")"
    fi
    if [[ -n "$OPT_BS_VERSION" ]]; then
        local v
        for v in "${versions[@]}"; do
            if [[ "$v" == "$OPT_BS_VERSION" ]]; then
                info "$(t bs_version_using "$v")"
                printf '%s\n' "$v"
                return 0
            fi
        done
        die "Beat Saber version not found: $OPT_BS_VERSION"
    fi

    # Non-interactive: single version auto-select; multiple require --version
    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        if [[ "$count" -eq 1 ]]; then
            info "$(t bs_version_using "${versions[0]}")"
            printf '%s\n' "${versions[0]}"
            return 0
        fi
        error "$(t bs_version_prompt)"
        for ((i = 0; i < count; i++)); do
            error "  - ${versions[$i]}"
        done
        die "Re-run with --version <Beat Saber version>"
    fi

    # Interactive: always propose detected versions as a numbered list (never type the version string)
    tty_open || true
    tty_printf '\n%s\n' "$(t bs_version_prompt)"
    tty_printf '%s\n' "$(t bs_versions_detected)"
    for ((i = 0; i < count; i++)); do
        tty_printf '  %d) Beat Saber %s\n' "$((i + 1))" "${versions[$i]}"
    done
    tty_printf '\n'
    default_num="1"
    while true; do
        answer="$(prompt_reply "$(t bs_version_pick_number)" "$default_num")"
        answer="${answer%%[[:space:]]*}"
        # Accept only a list index — not a free-typed version string
        if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= count)); then
            info "$(t bs_version_using "${versions[$((answer - 1))]}")"
            printf '%s\n' "${versions[$((answer - 1))]}"
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
    local -a candidates=()
    local d

    if [[ -d "$preferred" ]]; then
        if [[ -d "$preferred/pfx" || -e "$preferred" ]]; then
            candidates+=("$preferred")
        fi
    fi

    if [[ -d "$shared" ]]; then
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            [[ "$d" == "$preferred" ]] && continue
            candidates+=("$d")
        done < <(find "$shared" -mindepth 1 -maxdepth 1 -type d -name 'compatdata*' 2>/dev/null | sort)
    fi

    local -a valid=()
    for d in "${candidates[@]}"; do
        if [[ -d "$d/pfx" || -d "$d" ]]; then
            # Prefer those with pfx
            if [[ -d "$d/pfx" ]]; then
                valid+=("$d")
            fi
        fi
    done
    if [[ "${#valid[@]}" -eq 0 ]]; then
        for d in "${candidates[@]}"; do
            valid+=("$d")
        done
    fi

    if [[ "${#valid[@]}" -eq 0 ]]; then
        # Create preferred path location guidance; do not invent wineprefix content
        warn "No compatdata found under $shared"
        if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
            die "Provide --compatdata PATH"
        fi
        mkdir -p "$preferred"
        printf '%s\n' "$preferred"
        return 0
    fi
    if [[ "${#valid[@]}" -eq 1 ]]; then
        printf '%s\n' "$(canonical_path "${valid[0]}")"
        return 0
    fi
    # Prefer exact SharedContent/compatdata if listed
    for d in "${valid[@]}"; do
        if [[ "$(canonical_path "$d")" == "$(canonical_path "$preferred")" ]]; then
            printf '%s\n' "$(canonical_path "$d")"
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

create_beat_saber_wrapper() {
    local version="$1"
    local slug compat steam_root proton_path bs_dir wrapper
    slug="$(sanitize_version_slug "$version")"
    bs_dir="$BSMANAGER_DATA_DIR/BSInstances/$version"
    [[ -f "$bs_dir/Beat Saber.exe" ]] || die "Beat Saber.exe missing in $bs_dir"

    steam_root="$(find_steam_root)" || die "Steam root not found"
    proton_path="$(resolve_app_install_path "$PROTON_STABLE_APPID")" || die "Proton stable not installed"
    validate_proton_install "$proton_path" "$PROTON_STABLE_LABEL" || return 1
    compat="$(discover_compatdata)"

    wrapper="$LOCAL_BIN/beat-saber-${slug}-modded"
    info "Writing wrapper: $wrapper"

    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        info "[dry-run] write wrapper for $version"
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
if [[ ! -f "\$BS/Beat Saber.exe" ]]; then
    echo "Beat Saber missing: \$BS/Beat Saber.exe" >&2
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
exec "\$PROTON/proton" run "\$BS/Beat Saber.exe" "\$@"
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
        if mapfile -t _vs < <(list_beat_saber_instances); then
            if [[ "${#_vs[@]}" -gt 0 ]]; then
                version="$(select_beat_saber_version)"
            fi
        fi
    fi

    if [[ -n "$version" ]]; then
        wrapper="$(create_beat_saber_wrapper "$version")"
        slug="$(sanitize_version_slug "$version")"
        write_desktop_entry \
            "$APPLICATIONS_DIR/beat-saber-${slug}-modded.desktop" \
            "Beat Saber ${version} Modded" \
            "$(desktop_escape_exec "$wrapper")" \
            "$icon" \
            "Steam Frame modded Beat Saber launcher"
        success "Desktop entry: beat-saber-${slug}-modded.desktop"
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_cmd update-desktop-database "$APPLICATIONS_DIR" || true
    fi
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
    local wrapper slug bs_dir port venv
    slug="$(sanitize_version_slug "$version")"
    wrapper="$LOCAL_BIN/beat-saber-${slug}-modded"
    bs_dir="$BSMANAGER_DATA_DIR/BSInstances/$version"
    [[ -x "$wrapper" ]] || wrapper="$(create_beat_saber_wrapper "$version")"

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

# =============================================================================
# Diagnostics / backup / self-update / uninstall
# =============================================================================

report_line() {
    local label="$1"
    local value="$2"
    printf '%-36s %s\n' "$label:" "$value"
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

    echo "---- Beat Saber instances ----"
    local -a versions=()
    mapfile -t versions < <(list_beat_saber_instances)
    if [[ "${#versions[@]}" -eq 0 ]]; then
        echo "(none)"
    else
        printf '%s\n' "${versions[@]}"
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
    info "Uninstall removes the management tool by default."
    info "BSManager user data and Proton installs are preserved."

    local remove_wrappers=0 remove_desktop=0 remove_bsmanager=0

    if [[ "$FLAG_NON_INTERACTIVE" -eq 1 ]]; then
        :
    else
        if prompt_confirm "$(t ask_remove_wrappers)"; then
            remove_wrappers=1
        fi
        if prompt_confirm "$(t ask_remove_desktop)"; then
            remove_desktop=1
        fi
        if prompt_confirm "$(t ask_remove_bsmanager)"; then
            remove_bsmanager=1
        fi
        if [[ "$FLAG_REMOVE_DATA" -eq 1 ]]; then
            warn "REQUESTED: remove BSManager user data ($BSMANAGER_DATA_DIR)"
            if prompt_confirm "Type-confirm destructive data removal?"; then
                if prompt_confirm "Really delete Beat Saber instances and BSManager data?"; then
                    if is_safe_remove_path "$BSMANAGER_DATA_DIR" || [[ "$BSMANAGER_DATA_DIR" == "$XDG_DATA_HOME/BSManager" ]]; then
                        # Extra check: only allow exact data dir
                        if [[ "$BSMANAGER_DATA_DIR" == "$XDG_DATA_HOME/BSManager" && -n "$BSMANAGER_DATA_DIR" ]]; then
                            if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
                                info "[dry-run] rm -rf $BSMANAGER_DATA_DIR"
                            else
                                rm -rf -- "$BSMANAGER_DATA_DIR"
                            fi
                            warn "Removed BSManager user data"
                        fi
                    fi
                fi
            fi
        fi
    fi

    if [[ "$remove_wrappers" -eq 1 ]]; then
        local w
        for w in "$LOCAL_BIN"/beat-saber-*-modded; do
            [[ -e "$w" ]] || continue
            safe_rm "$w"
        done
    fi
    if [[ "$remove_desktop" -eq 1 ]]; then
        local d
        for d in "$APPLICATIONS_DIR"/beat-saber-*-modded.desktop \
            "$APPLICATIONS_DIR"/bs-manager.desktop \
            "$APPLICATIONS_DIR"/bsmanager-frame.desktop; do
            [[ -e "$d" ]] || continue
            safe_rm "$d"
        done
    fi
    if [[ "$remove_bsmanager" -eq 1 ]]; then
        [[ -e "$BSMANAGER_BIN" ]] && safe_rm "$BSMANAGER_BIN"
        [[ -d "$BSMANAGER_INSTALL_DIR" ]] && safe_rm "$BSMANAGER_INSTALL_DIR"
    fi

    # Always remove this tool's own desktop entry with the tool itself
    if [[ -e "$APPLICATIONS_DIR/bsmanager-frame.desktop" ]]; then
        safe_rm "$APPLICATIONS_DIR/bsmanager-frame.desktop"
    fi
    [[ -e "$SELF_INSTALL_PATH" ]] && safe_rm "$SELF_INSTALL_PATH"
    [[ -d "$TOOL_DATA_DIR" ]] && safe_rm "$TOOL_DATA_DIR"
    [[ -d "$TOOL_STATE_DIR" ]] && safe_rm "$TOOL_STATE_DIR"
    success "$(t uninstall_done)"
    log_action OK "uninstall"
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
    local version
    version="$(select_beat_saber_version)"
    create_desktop_shortcuts "$version"
    if steam_shortcuts_cdp "$version"; then
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
    info "Checking latest BSManager release..."
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

menu_launchers() {
    local v
    v="$(select_beat_saber_version)" || return 1
    create_beat_saber_wrapper "$v" >/dev/null || return 1
}

show_menu() {
    if ! have_tty && [[ "$FLAG_NON_INTERACTIVE" -ne 1 ]]; then
        die "$(t menu_needs_tty)"
    fi
    local choice=""
    local -a bs_versions=()
    local v n_bs=0
    tty_open || true
    while true; do
        mapfile -t bs_versions < <(list_beat_saber_instances | grep -v '^$' || true)
        n_bs="${#bs_versions[@]}"

        tty_printf '\n%s\n\n' "$(t menu_banner "$VERSION")"
        if [[ "$n_bs" -gt 0 ]]; then
            tty_printf '%s\n' "$(t bs_versions_detected)"
            for v in "${bs_versions[@]}"; do
                tty_printf '  - %s\n' "$v"
            done
            tty_printf '\n'
        else
            tty_printf '%s\n\n' "$(t bs_versions_none)"
        fi
        tty_printf '1) %s\n' "$(t menu_1)"
        tty_printf '2) %s\n' "$(t menu_2)"
        tty_printf '3) %s\n' "$(t menu_3)"
        if [[ "$n_bs" -gt 0 ]]; then
            tty_printf '4) %s (%s)\n' "$(t menu_4)" "$n_bs"
            tty_printf '5) %s (%s)\n' "$(t menu_5)" "$n_bs"
        else
            tty_printf '4) %s\n' "$(t menu_4)"
            tty_printf '5) %s\n' "$(t menu_5)"
        fi
        tty_printf '6) %s\n' "$(t menu_6)"
        tty_printf '7) %s\n' "$(t menu_7)"
        tty_printf '8) %s\n' "$(t menu_8)"
        tty_printf '9) %s\n' "$(t menu_9)"
        tty_printf '10) %s\n' "$(t menu_10)"
        tty_printf '0) %s\n\n' "$(t menu_0)"
        choice="$(prompt_reply "$(t menu_select)" "")"
        choice="${choice%%[[:space:]]*}"
        case "$choice" in
            1) run_menu_action install cmd_install ;;
            2) run_menu_action update cmd_update ;;
            3) run_menu_action proton cmd_proton ;;
            4) run_menu_action launchers menu_launchers ;;
            5) run_menu_action shortcuts cmd_shortcuts ;;
            6) run_menu_action diagnose cmd_diagnose ;;
            7) run_menu_action backup cmd_backup ;;
            8) run_menu_action self-update cmd_self_update ;;
            9) run_menu_action uninstall cmd_uninstall ;;
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
  update           Update BSManager application (preserves user data)
  setup            Alias for install
  proton           Ensure Proton stack and configure BSManager paths
  shortcuts        Create/repair wrappers, desktop entries, Steam shortcuts
  diagnose         Print diagnostics report
  backup           Backup small integration/config files
  self-update      Update this tool from GitHub
  install-self     Install this script to ~/.local/bin/bsmanager-frame
  uninstall        Remove this tool (optional extras with prompts)
  help             Show this help
  version          Show version

Global options:
  --yes                Assume yes for safe confirmations
  --non-interactive    Fail instead of prompting
  --dry-run            Print actions without mutating
  --verbose            Debug logging to stderr
  --force              Continue on unknown platform / force reinstall
  --allow-flatpak      Allow explicit Flatpak fallback when no native ARM64
                       build is available. Disabled by default (not recommended
                       as the normal Steam Frame path).
  --lang <code>        UI language: en, fr, es, de, sw
  --help               Show help
  --version            Show version

Command options:
  --version <ver>      Beat Saber instance version
  --compatdata <path>  Explicit compatdata path
  --bsmanager-url URL  Custom BSManager asset URL
  --bsmanager-dir PATH Local unpacked native BSManager build
  --remove-data        With uninstall: allow deleting BSManager user data
                       (still requires interactive confirmation; --yes alone
                       does NOT delete game data)

Environment:
  BSMF_LANG, BSMF_ALLOW_FLATPAK, BSMF_PROTON_STABLE_APPID,
  BSMF_PROTON_EXPERIMENTAL_APPID, BSMF_STEAM_RUNTIME_ARM64_APPID,
  BSMF_STEAM_INSTALL_TIMEOUT, BSMANAGER_ASSET_URL, GITHUB_TOKEN, NO_COLOR

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

main "$@" || exit $?
