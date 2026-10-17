#!/usr/bin/env bash
# Mocked Steam-install and archive checks. Does not launch a real Steam client.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export HOME="$WORKDIR/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$WORKDIR/runtime"
export LC_ALL=C
export LANG=C
unset BSMF_LANG || true
unset BSMF_PROTON_STABLE_APPID || true
unset BSMF_PROTON_EXPERIMENTAL_APPID || true
unset BSMF_STEAM_RUNTIME_ARM64_APPID || true

mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$WORKDIR/bin"
export BSMF_STEAM_LOG="$WORKDIR/steam.log"
: >"$BSMF_STEAM_LOG"
export BSMF_STEAM_HOOK=""

cat >"$WORKDIR/bin/steam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BSMF_STEAM_LOG:?}"
if [[ -n "${BSMF_STEAM_HOOK:-}" && -f "${BSMF_STEAM_HOOK}" ]]; then
    bash "$BSMF_STEAM_HOOK" "$@"
fi
exit 0
EOF
cat >"$WORKDIR/bin/xdg-open" <<'EOF'
#!/usr/bin/env bash
printf 'xdg %s\n' "$*" >>"${BSMF_STEAM_LOG:?}"
exit 0
EOF
chmod +x "$WORKDIR/bin/steam" "$WORKDIR/bin/xdg-open"

export PATH="$WORKDIR/bin:$PATH"
export BSMF_LIB_ONLY=1
export BSMF_STEAM_POLL_INTERVAL=1
export BSMF_STEAM_INSTALL_TIMEOUT=4
# shellcheck disable=SC1091
source "$ROOT/bsmanager-frame.sh"
trap 'rm -rf "$WORKDIR"' EXIT
UI_LANG=en
FLAG_FORCE=1

pass() { printf 'OK %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

assert_ok() {
    if ! "$@"; then
        fail "expected success: $*"
    fi
}
assert_fail() {
    if "$@"; then
        fail "expected failure: $*"
    fi
}

reset_steam() {
    FLAG_YES=0
    FLAG_NON_INTERACTIVE=0
    FLAG_DRY_RUN=0
    BSMF_STEAM_HOOK=""
    rm -rf "$HOME/.local/share/Steam" "$XDG_CONFIG_HOME/bs-manager"
    mkdir -p "$HOME/.local/share/Steam/steamapps/common"
    : >"$BSMF_STEAM_LOG"
}

write_manifest() {
    local appid="$1" flags="$2" downloaded="$3" total="$4" installdir="$5"
    local omit_bytes="${6:-0}"
    local file="$HOME/.local/share/Steam/steamapps/appmanifest_${appid}.acf"
    {
        printf '%s\n' '"AppState"' '{'
        printf '  "appid" "%s"\n' "$appid"
        if [[ -n "$flags" ]]; then
            printf '  "StateFlags" "%s"\n' "$flags"
        fi
        if [[ "$omit_bytes" -eq 0 ]]; then
            printf '  "BytesDownloaded" "%s"\n' "$downloaded"
            printf '  "BytesToDownload" "%s"\n' "$total"
        fi
        printf '  "installdir" "%s"\n' "$installdir"
        printf '%s\n' '}'
    } >"$file"
}

proton_tree() {
    local name="$1"
    local root="$HOME/.local/share/Steam/steamapps/common/$name"
    mkdir -p "$root/files/bin-arm64"
    printf '%s\n' '#!/bin/sh' >"$root/proton"
    printf '%s\n' 'wine' >"$root/files/bin-arm64/wine"
    chmod +x "$root/proton" "$root/files/bin-arm64/wine" || true
}

runtime_tree() {
    mkdir -p "$HOME/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4"
}

install_ready_proton() {
    local appid="$1" name="$2"
    write_manifest "$appid" 4 100 100 "$name"
    proton_tree "$name"
}

uri_count() {
    local needle="$1"
    if [[ ! -s "$BSMF_STEAM_LOG" ]]; then
        printf '0\n'
        return 0
    fi
    grep -c -F "$needle" "$BSMF_STEAM_LOG" || true
}

# --- pure helpers ---
assert_ok steam_state_fully_installed 4 100 100
assert_ok steam_state_fully_installed 6 100 100
assert_ok steam_state_fully_installed 4 "" ""
assert_fail steam_state_fully_installed 2 100 100
assert_fail steam_state_fully_installed 4 10 100
assert_fail steam_state_fully_installed "nope" 10 10
assert_fail steam_state_fully_installed "" 10 10
formatted="$(steam_format_bytes 1536)"
case "$formatted" in
    *KiB*|*K*) ;;
    *) fail "format_bytes: $formatted" ;;
esac
BSMF_STEAM_POLL_INTERVAL=0
got="$(steam_poll_seconds || true)"
[[ "$got" == "2" ]] || fail "poll 0 -> $got"
BSMF_STEAM_POLL_INTERVAL=abc
got="$(steam_poll_seconds || true)"
[[ "$got" == "2" ]] || fail "poll abc -> $got"
BSMF_STEAM_POLL_INTERVAL=5
got="$(steam_poll_seconds)"
[[ "$got" == "5" ]] || fail "poll 5 -> $got"
BSMF_STEAM_POLL_INTERVAL=1
pass "state flags, bytes, poll interval"

# --- archive links ---
python3 - <<PY
import io, tarfile, os
base = r"$WORKDIR"

def add_file(tf, name, data=b"#!/bin/sh\n"):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o755
    tf.addfile(info, io.BytesIO(data))

def add_link(tf, name, target, kind):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.linkname = target
    tf.addfile(info)

def pack(path, build):
    with tarfile.open(path, "w:gz") as tf:
        build(tf)

def safe(tf):
    add_file(tf, "bs-manager/bs-manager")
    add_link(tf, "bs-manager/files/wine-link", "../bs-manager", tarfile.SYMTYPE)

def sym_escape(tf):
    add_file(tf, "bs-manager/bs-manager")
    add_link(tf, "bs-manager/foo", "../../outside", tarfile.SYMTYPE)

def hard_escape(tf):
    add_file(tf, "bs-manager/bs-manager")
    add_link(tf, "bs-manager/foo", "../../outside", tarfile.LNKTYPE)

def dotdot(tf):
    add_file(tf, "bs-manager/../../outside")

def absolute(tf):
    add_file(tf, "/tmp/outside")

pack(os.path.join(base, "safe.tar.gz"), safe)
pack(os.path.join(base, "sym.tar.gz"), sym_escape)
pack(os.path.join(base, "hard.tar.gz"), hard_escape)
pack(os.path.join(base, "dotdot.tar.gz"), dotdot)
pack(os.path.join(base, "abs.tar.gz"), absolute)
PY

assert_ok validate_bsmanager_frame_archive "$WORKDIR/safe.tar.gz"
assert_fail validate_bsmanager_frame_archive "$WORKDIR/sym.tar.gz"
assert_fail validate_bsmanager_frame_archive "$WORKDIR/hard.tar.gz"
assert_fail validate_bsmanager_frame_archive "$WORKDIR/dotdot.tar.gz"
assert_fail validate_bsmanager_frame_archive "$WORKDIR/abs.tar.gz"
pass "archive symlink and hardlink checks"

# --- already installed: no URI ---
reset_steam
install_ready_proton "$PROTON_STABLE_APPID" "Proton 11.0 (ARM64)"
FLAG_YES=1
path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL")"
[[ "$path" == *"/Proton 11.0 (ARM64)" ]] || fail "ready path: $path"
[[ "$(uri_count "steam://install/${PROTON_STABLE_APPID}")" == "0" ]] || fail "URI sent for installed app"
pass "already installed"

# --- StateFlags 4 and 4|2, no byte counters ---
reset_steam
install_ready_proton "$PROTON_EXPERIMENTAL_APPID" "Proton Experimental (ARM64)"
write_manifest "$PROTON_EXPERIMENTAL_APPID" 6 50 50 "Proton Experimental (ARM64)"
assert_ok steam_app_is_ready "$PROTON_EXPERIMENTAL_APPID"
write_manifest "$PROTON_EXPERIMENTAL_APPID" 4 "" "" "Proton Experimental (ARM64)" 1
assert_ok steam_app_is_ready "$PROTON_EXPERIMENTAL_APPID"
FLAG_NON_INTERACTIVE=1
path="$(ensure_steam_app "$PROTON_EXPERIMENTAL_APPID" "$PROTON_EXPERIMENTAL_LABEL")"
[[ "$(uri_count "steam://install/${PROTON_EXPERIMENTAL_APPID}")" == "0" ]] || fail "URI sent without byte counters"
pass "StateFlags bitmask and absent byte counters"

# --- dry-run does not send or poll ---
reset_steam
FLAG_DRY_RUN=1
started=$SECONDS
ensure_required_proton_stack >/dev/null
elapsed=$((SECONDS - started))
[[ "$elapsed" -lt 3 ]] || fail "dry-run took ${elapsed}s"
[[ ! -s "$BSMF_STEAM_LOG" ]] || fail "dry-run sent a URI"
pass "dry-run"

# --- timeout while the headset has not confirmed ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=2
FLAG_NON_INTERACTIVE=1
set +e
ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL" >"$WORKDIR/timeout.out" 2>"$WORKDIR/timeout.err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "timeout returned 0"
grep -F "did not complete before timeout" "$WORKDIR/timeout.err" >/dev/null || fail "missing timeout message"
grep -F "left unchanged" "$WORKDIR/timeout.err" >/dev/null || fail "missing unchanged message"
[[ "$(uri_count "steam://install/${PROTON_STABLE_APPID}")" == "1" ]] || fail "timeout did not request install"
[[ ! -e "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" ]] || fail "timeout created a manifest"
pass "timeout"

# --- manifest appears after polling starts ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=8
cat >"$WORKDIR/hook-appear.sh" <<EOF
#!/usr/bin/env bash
(
  sleep 2
  cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "100"
  "BytesToDownload" "100"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
  mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
  printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
  printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
) &
EOF
chmod +x "$WORKDIR/hook-appear.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-appear.sh"
FLAG_NON_INTERACTIVE=1
path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL" 2>"$WORKDIR/appear.err")"
[[ "$path" == *"/Proton 11.0 (ARM64)" ]] || fail "appear path: $path"
grep -F "Waiting for confirmation" "$WORKDIR/appear.err" >/dev/null || grep -F "Steam installation detected" "$WORKDIR/appear.err" >/dev/null || grep -F "installation complete" "$WORKDIR/appear.err" >/dev/null || fail "appear produced no steam status"
pass "manifest appears during polling"

# --- active download, then complete ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=8
write_manifest "$PROTON_STABLE_APPID" 2 100 1000 "Proton 11.0 (ARM64)"
cat >"$WORKDIR/hook-download.sh" <<EOF
#!/usr/bin/env bash
cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "2"
  "BytesDownloaded" "500"
  "BytesToDownload" "1000"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
(
  sleep 2
  cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "1000"
  "BytesToDownload" "1000"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
  mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
  printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
  printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
) &
EOF
chmod +x "$WORKDIR/hook-download.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-download.sh"
FLAG_YES=1
path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL")"
[[ "$path" == *"/Proton 11.0 (ARM64)" ]] || fail "download path: $path"
grep -F "steam_download_progress" "$TOOL_ACTION_LOG" >/dev/null || fail "no download progress log"
progress_lines="$(grep -c -F "steam_download_progress" "$TOOL_ACTION_LOG" || true)"
[[ "$progress_lines" -lt 20 ]] || fail "progress log spam: $progress_lines"
pass "active download"

# --- malformed manifest, then a valid one ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=8
write_manifest "$PROTON_STABLE_APPID" "not-a-number" "" "" "Proton 11.0 (ARM64)" 1
cat >"$WORKDIR/hook-malformed.sh" <<EOF
#!/usr/bin/env bash
(
  sleep 2
  cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
  mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
  printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
  printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
) &
EOF
chmod +x "$WORKDIR/hook-malformed.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-malformed.sh"
FLAG_NON_INTERACTIVE=1
path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL")"
[[ -n "$path" ]] || fail "malformed manifest aborted the monitor"
pass "malformed temporary manifest"

# --- complete manifest, missing proton files ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=2
write_manifest "$PROTON_STABLE_APPID" 4 100 100 "Proton 11.0 (ARM64)"
FLAG_NON_INTERACTIVE=1
set +e
ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL" >"$WORKDIR/missing.out" 2>"$WORKDIR/missing.err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing files returned 0"
grep -F "required files are missing" "$WORKDIR/missing.err" >/dev/null || fail "missing-files message"
grep -F "[OK] proton" "$WORKDIR/missing.err" >/dev/null && fail "claimed proton ok"
pass "complete manifest but missing files"

# --- stale incomplete manifest is repaired, not treated as installed ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=8
write_manifest "$PROTON_STABLE_APPID" 2 10 100 "Proton 11.0 (ARM64)"
cat >"$WORKDIR/hook-stale.sh" <<EOF
#!/usr/bin/env bash
cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "100"
  "BytesToDownload" "100"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
EOF
chmod +x "$WORKDIR/hook-stale.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-stale.sh"
FLAG_YES=1
path="$(ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL")"
[[ "$(uri_count "steam://install/${PROTON_STABLE_APPID}")" == "1" ]] || fail "stale manifest skipped the URI"
[[ -n "$path" ]] || fail "stale repair produced no path"
pass "stale incomplete manifest"

# --- sequential recheck: runtime installed while Proton 11 installs ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=8
cat >"$WORKDIR/hook-transitive.sh" <<EOF
#!/usr/bin/env bash
uri="\$1"
case "\$uri" in
  *${PROTON_STABLE_APPID}*)
    cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "100"
  "BytesToDownload" "100"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
    mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
    printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
    printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
    cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${STEAM_RUNTIME_ARM64_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "10"
  "BytesToDownload" "10"
  "installdir" "SteamLinuxRuntime_4"
}
ACF
    mkdir -p "$HOME/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4"
    ;;
  *${PROTON_EXPERIMENTAL_APPID}*)
    cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_EXPERIMENTAL_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "100"
  "BytesToDownload" "100"
  "installdir" "Proton Experimental (ARM64)"
}
ACF
    mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton Experimental (ARM64)/files/bin-arm64"
    printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton Experimental (ARM64)/proton"
    printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton Experimental (ARM64)/files/bin-arm64/wine"
    ;;
esac
EOF
chmod +x "$WORKDIR/hook-transitive.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-transitive.sh"
FLAG_NON_INTERACTIVE=1
ensure_required_proton_stack >/dev/null
[[ "$(uri_count "steam://install/${PROTON_STABLE_APPID}")" == "1" ]] || fail "stable URI missing"
[[ "$(uri_count "steam://install/${PROTON_EXPERIMENTAL_APPID}")" == "1" ]] || fail "experimental URI missing"
[[ "$(uri_count "steam://install/${STEAM_RUNTIME_ARM64_APPID}")" == "0" ]] || fail "runtime URI sent after transitive install"
pass "transitive runtime recheck"

# --- later component already present before its turn ---
reset_steam
install_ready_proton "$PROTON_EXPERIMENTAL_APPID" "Proton Experimental (ARM64)"
write_manifest "$STEAM_RUNTIME_ARM64_APPID" 4 10 10 "SteamLinuxRuntime_4"
runtime_tree
cat >"$WORKDIR/hook-only-stable.sh" <<EOF
#!/usr/bin/env bash
cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "100"
  "BytesToDownload" "100"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
EOF
chmod +x "$WORKDIR/hook-only-stable.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-only-stable.sh"
FLAG_YES=1
ensure_required_proton_stack >/dev/null
[[ "$(uri_count "steam://install/${PROTON_STABLE_APPID}")" == "1" ]] || fail "expected only stable URI"
[[ "$(uri_count "steam://install/${PROTON_EXPERIMENTAL_APPID}")" == "0" ]] || fail "experimental popup"
[[ "$(uri_count "steam://install/${STEAM_RUNTIME_ARM64_APPID}")" == "0" ]] || fail "runtime popup"
pass "component already present before its turn"

# --- non-interactive sends the URI and says the headset must confirm ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=8
cat >"$WORKDIR/hook-noninteractive.sh" <<EOF
#!/usr/bin/env bash
cat > "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" <<'ACF'
"AppState"
{
  "StateFlags" "4"
  "BytesDownloaded" "100"
  "BytesToDownload" "100"
  "installdir" "Proton 11.0 (ARM64)"
}
ACF
mkdir -p "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64"
printf '%s\n' '#!/bin/sh' > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/proton"
printf '%s\n' wine > "$HOME/.local/share/Steam/steamapps/common/Proton 11.0 (ARM64)/files/bin-arm64/wine"
EOF
chmod +x "$WORKDIR/hook-noninteractive.sh"
BSMF_STEAM_HOOK="$WORKDIR/hook-noninteractive.sh"
FLAG_NON_INTERACTIVE=1
FLAG_YES=0
ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL" >"$WORKDIR/ni.out" 2>"$WORKDIR/ni.err"
[[ "$(uri_count "steam://install/${PROTON_STABLE_APPID}")" == "1" ]] || fail "non-interactive did not send URI"
grep -F "Confirm the installation inside the Steam Frame headset" "$WORKDIR/ni.err" >/dev/null || fail "headset confirmation not mentioned"
pass "non-interactive"

# --- fresh config receives both Proton folders ---
reset_steam
install_ready_proton "$PROTON_STABLE_APPID" "Proton 11.0 (ARM64)"
install_ready_proton "$PROTON_EXPERIMENTAL_APPID" "Proton Experimental (ARM64)"
FLAG_DRY_RUN=0
configure_bsmanager_proton
python3 - "$XDG_CONFIG_HOME/bs-manager/config.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("proton-folder", "").endswith("Proton 11.0 (ARM64)"), data
assert data.get("prefix-proton-folder", "").endswith("Proton Experimental (ARM64)"), data
PY
pass "fresh config"

# --- xdg-open remains only a fallback ---
reset_steam
saved_path="$PATH"
export PATH="$WORKDIR/bin:/usr/bin:/bin"
mv "$WORKDIR/bin/steam" "$WORKDIR/bin/steam.hidden"
export BSMF_STEAM_INSTALL_TIMEOUT=2
FLAG_DRY_RUN=0
FLAG_NON_INTERACTIVE=1
set +e
ensure_steam_app "$PROTON_STABLE_APPID" "$PROTON_STABLE_LABEL" >/dev/null 2>"$WORKDIR/xdg.err"
set -e
export PATH="$saved_path"
mv "$WORKDIR/bin/steam.hidden" "$WORKDIR/bin/steam"
grep -F "xdg steam://install/${PROTON_STABLE_APPID}" "$BSMF_STEAM_LOG" >/dev/null || fail "xdg-open fallback not used"
pass "xdg-open fallback"

# --- Ctrl+C leaves the script without deleting Steam state ---
reset_steam
export BSMF_STEAM_INSTALL_TIMEOUT=5
write_manifest "$PROTON_STABLE_APPID" 2 1 100 "Proton 11.0 (ARM64)"
# Job control so the child is not started with SIGINT ignored.
set -m
bash --noprofile --norc -c '
export HOME="$1" XDG_DATA_HOME="$2" XDG_CONFIG_HOME="$3" XDG_STATE_HOME="$4" XDG_RUNTIME_DIR="$5"
export BSMF_LIB_ONLY=1 BSMF_STEAM_INSTALL_TIMEOUT=5 BSMF_STEAM_POLL_INTERVAL=1 LC_ALL=C
export PATH="$6"
# shellcheck disable=SC1090
source "$7"
UI_LANG=en
monitor_steam_install "$8" "Proton 11.0 (ARM64)" present 2 1
' _ "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$PATH" "$ROOT/bsmanager-frame.sh" "$PROTON_STABLE_APPID" >"$WORKDIR/int.out" 2>"$WORKDIR/int.err" &
int_pid=$!
sleep 1
kill -INT "$int_pid" 2>/dev/null || true
set +e
wait "$int_pid"
int_rc=$?
set -e
set +m
[[ -f "$HOME/.local/share/Steam/steamapps/appmanifest_${PROTON_STABLE_APPID}.acf" ]] || fail "interrupt removed the manifest"
if [[ "$int_rc" -eq 130 ]] && grep -F "Interrupted" "$WORKDIR/int.err" >/dev/null; then
    pass "interrupt"
elif [[ "$(uname -s)" != "Linux" ]]; then
    printf 'SKIP interrupt (rc=%s; signal delivery unavailable)\n' "$int_rc"
else
    printf 'interrupt stderr:\n' >&2
    cat "$WORKDIR/int.err" >&2 || true
    fail "interrupt rc=$int_rc"
fi

printf 'ALL_OK\n'
