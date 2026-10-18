#!/usr/bin/env bash
# Beat Saber Steam shortcut on a Steam Frame: text title + library tile, no logo.
# A custom logo replaces the title, so this script clears that slot.
#
#   tools/steam-shortcut-frame.sh show
#   tools/steam-shortcut-frame.sh apply      # title + tile, remove the logo
#   tools/steam-shortcut-frame.sh remove
#   tools/steam-shortcut-frame.sh recreate   # remove, then create again
#
# Optional: tools/steam-shortcut-frame.sh recreate 1.40.8
set -euo pipefail

VERSION="${2:-1.40.8}"
ACTION="${1:-}"
NAME="Beat Saber ${VERSION}"
WRAPPER="${HOME}/.local/bin/beat-saber-${VERSION}-modded"
STARTDIR="${HOME}/.local/share/BSManager/BSInstances/${VERSION}"
VDF="${HOME}/.local/share/Steam/userdata/411327032/config/shortcuts.vdf"
GRID="${HOME}/.local/share/Steam/userdata/411327032/config/grid"

case "$ACTION" in
    show|apply|remove|recreate) ;;
    *)
        echo "usage: $0 {show|apply|remove|recreate} [version]" >&2
        exit 2
        ;;
esac

ICON=""
for candidate in \
    "${HOME}/.local/share/icons/hicolor/256x256/apps/bs-manager.png" \
    "${HOME}/.local/opt/bs-manager/resources/icon.png" \
    "${HOME}/.local/opt/bs-manager/bs-manager.png" \
    "${HOME}/.local/opt/bs-manager/icon.png"
do
    if [[ -f "$candidate" ]]; then
        ICON="$candidate"
        break
    fi
done
if [[ -z "$ICON" ]]; then
    echo "aucune image png trouvée pour la tuile" >&2
    exit 1
fi

if [[ "$ACTION" != "show" && -f "$VDF" ]]; then
    cp -a "$VDF" "${HOME}/shortcuts-beat-saber-$(date +%Y%m%dT%H%M%S).vdf"
fi

export ACTION NAME WRAPPER STARTDIR VDF GRID ICON
python3 - <<'PY'
import base64, json, os, shutil, socket, struct, time, urllib.request
from pathlib import Path
from urllib.parse import urlparse

ACTION = os.environ["ACTION"]
NAME = os.environ["NAME"]
WRAPPER = os.environ["WRAPPER"]
STARTDIR = os.environ["STARTDIR"]
VDF = os.environ["VDF"]
GRID = Path(os.environ["GRID"])
ICON = os.environ["ICON"]
IMAGE = base64.b64encode(Path(ICON).read_bytes()).decode()

def parse_vdf(path):
    data = open(path, "rb").read()
    pos = 0
    def cstr():
        nonlocal pos
        end = data.index(b"\x00", pos)
        text = data[pos:end].decode("utf-8", "replace")
        pos = end + 1
        return text
    def obj():
        nonlocal pos
        out = {}
        while pos < len(data):
            kind = data[pos]
            pos += 1
            if kind == 0x08:
                return out
            key = cstr()
            if kind == 0x00:
                out[key] = obj()
            elif kind == 0x01:
                out[key] = cstr()
            elif kind == 0x02:
                out[key] = struct.unpack_from("<i", data, pos)[0]
                pos += 4
            elif kind in (0x07, 0x0A):
                out[key] = struct.unpack_from("<Q", data, pos)[0]
                pos += 8
            else:
                raise SystemExit("VDF illisible, type %s" % kind)
        return out
    return obj()

def matches(row):
    if not isinstance(row, dict):
        return False
    blob = (str(row.get("Exe") or "") + " " + str(row.get("StartDir") or "")).replace('"', "").replace("\\", "/")
    return WRAPPER in blob or STARTDIR.rstrip("/") in blob

def appid_of(row):
    return int(row["appid"]) & 0xFFFFFFFF

def shortcuts():
    if not os.path.isfile(VDF):
        return []
    root = parse_vdf(VDF)
    table = root.get("shortcuts") or {}
    found = []
    for row in table.values():
        if matches(row):
            found.append(row)
    return found

def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise SystemExit("connexion coupée")
        buf += chunk
    return buf

def ws_connect(url):
    parsed = urlparse(url)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    sock = socket.create_connection((parsed.hostname, parsed.port), timeout=60)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        "GET %s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n" % (path, parsed.hostname, parsed.port, key)
    ).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += sock.recv(4096)
    return sock

def ws_send(sock, text):
    data = text.encode()
    mask = os.urandom(4)
    header = bytearray([0x81])
    size = len(data)
    if size < 126:
        header.append(0x80 | size)
    elif size < 65536:
        header.append(0x80 | 126)
        header += size.to_bytes(2, "big")
    else:
        header.append(0x80 | 127)
        header += size.to_bytes(8, "big")
    sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def ws_recv(sock):
    parts = []
    while True:
        first, second = read_exact(sock, 2)
        fin, opcode, length = first & 0x80, first & 0x0F, second & 0x7F
        if length == 126:
            length = int.from_bytes(read_exact(sock, 2), "big")
        elif length == 127:
            length = int.from_bytes(read_exact(sock, 8), "big")
        payload = read_exact(sock, length)
        if opcode == 8:
            raise SystemExit("CDP fermé")
        if opcode in (0, 1):
            parts.append(payload)
            if fin:
                return b"".join(parts).decode()

MSG = 0

def evaluate(sock, expression):
    global MSG
    MSG += 1
    ws_send(sock, json.dumps({"id": MSG, "method": "Runtime.evaluate", "params": {
        "expression": expression, "returnByValue": True, "awaitPromise": True}}))
    while True:
        data = json.loads(ws_recv(sock))
        if data.get("id") == MSG:
            result = data.get("result") or {}
            if result.get("exceptionDetails"):
                print("erreur JS:", json.dumps(result["exceptionDetails"])[:800])
                return None
            return (result.get("result") or {}).get("value")

def connect():
    with urllib.request.urlopen("http://127.0.0.1:8080/json/list", timeout=5) as response:
        targets = json.load(response)
    shared = next(item for item in targets if "SharedJSContext" in (item.get("title") or ""))
    return ws_connect(shared["webSocketDebuggerUrl"])

def clear_logo_files(appid):
    path = GRID / ("%s_logo.png" % appid)
    if path.exists():
        path.unlink()
        print("fichier logo retiré:", path)

def remove_grid(appid):
    if not GRID.is_dir():
        return
    for path in GRID.glob("%s*" % appid):
        path.unlink()
        print("fichier tuile retiré:", path.name)

def show():
    rows = shortcuts()
    if not rows:
        print("aucun raccourci pour", WRAPPER)
        return
    for row in rows:
        print("titre fichier:", row.get("AppName") or row.get("appname"))
        print("appid:", appid_of(row))
        print("exe:", row.get("Exe"))
        print("dossier:", row.get("StartDir"))
        print("icone fichier:", row.get("icon") or "(aucune)")

def remove_live(sock, rows):
    removed = []
    for row in rows:
        appid = appid_of(row)
        value = evaluate(sock, """
(() => {
  try {
    window.SteamClient.Apps.RemoveShortcut(%s);
    return "retiré";
  } catch (err) {
    return "erreur: " + err;
  }
})()
""" % appid)
        print("suppression", appid, ":", value)
        remove_grid(appid)
        removed.append(appid)
    return removed

def style(sock, appid):
    value = evaluate(sock, """
(async () => {
  const apps = window.SteamClient.Apps;
  const id = %s;
  const out = [];
  try { apps.SetShortcutName(id, %s); out.push("titre"); }
  catch (err) { out.push("titre: " + err); }
  try { apps.SetShortcutExe(id, %s); out.push("exe"); }
  catch (err) { out.push("exe: " + err); }
  try { apps.SetShortcutStartDir(id, %s); out.push("dossier"); }
  catch (err) { out.push("dossier: " + err); }
  try { apps.SetShortcutIsVR(id, true); out.push("vr"); }
  catch (err) { out.push("vr: " + err); }
  try {
    await apps.SetCustomArtworkForApp(id, %s, "png", 0);
    out.push("tuile");
  } catch (err) { out.push("tuile: " + err); }
  try { await apps.ClearCustomArtworkForApp(id, 2); out.push("logo effacé"); }
  catch (err) { out.push("logo: " + err); }
  try { await apps.ClearCustomLogoPositionForApp(id); out.push("position logo effacée"); }
  catch (err) { out.push("position: " + err); }
  return out;
})()
""" % (appid, json.dumps(NAME), json.dumps(WRAPPER), json.dumps(STARTDIR), json.dumps(IMAGE)))
    print("réglages:", ", ".join(value or ["rien"]))
    clear_logo_files(appid)
    GRID.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "p"):
        dest = GRID / ("%s%s.png" % (appid, suffix))
        shutil.copyfile(ICON, dest)
        print("tuile écrite:", dest.name)

def create_live(sock):
    created = evaluate(sock, """
(async () => {
  try {
    const id = await window.SteamClient.Apps.AddShortcut(%s, %s, %s, "");
    return {ok: true, id};
  } catch (err) {
    return {ok: false, error: String(err)};
  }
})()
""" % (json.dumps(NAME), json.dumps(WRAPPER), json.dumps(STARTDIR)))
    print("création:", json.dumps(created, ensure_ascii=False)[:400])
    raw = created.get("id") if isinstance(created, dict) else created
    if isinstance(raw, dict):
        raw = raw.get("appid") or raw.get("id")
    if not isinstance(created, dict) or not created.get("ok") or raw in (None, ""):
        raise SystemExit("création refusée")
    appid = int(raw) & 0xFFFFFFFF
    print("nouvel appid:", appid)
    style(sock, appid)
    return appid

rows = shortcuts()
if ACTION == "show":
    show()
    raise SystemExit(0)

sock = connect()
if ACTION == "apply":
    if not rows:
        print("pas de raccourci : création")
        create_live(sock)
    else:
        for row in rows:
            print("mise à jour", appid_of(row))
            style(sock, appid_of(row))
elif ACTION == "remove":
    if not rows:
        print("rien à supprimer")
    else:
        remove_live(sock, rows)
elif ACTION == "recreate":
    if rows:
        remove_live(sock, rows)
        time.sleep(1)
    else:
        print("rien à supprimer, création directe")
    create_live(sock)
print("OK", ACTION)
PY
