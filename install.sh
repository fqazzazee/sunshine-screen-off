#!/usr/bin/env bash
# Install sunshine-screen-off for the current user.
#   ./install.sh [--connector cardN-XXX-N]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bindir="$HOME/.local/bin"
confdir="$HOME/.config/sunshine"
connector=""

while [ $# -gt 0 ]; do
    case "$1" in
        --connector) connector="${2:?--connector needs a value, e.g. card1-DP-1}"; shift 2 ;;
        -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root (sudo is used where needed)"

step "Checking dependencies"
for cmd in python3 gdctl sudo visudo; do
    command -v "$cmd" >/dev/null || die "'$cmd' not found"
done
command -v sunshine >/dev/null || echo "    warning: 'sunshine' not found in PATH"
python3 - <<'EOF' || die "need python-gobject, gstreamer and gst-plugin-pipewire"
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, GLibUnix, Gst
Gst.init(None)
assert Gst.ElementFactory.find("pipewiresrc"), "pipewiresrc missing"
EOF

step "Detecting the physical monitor"
if [ -z "$connector" ]; then
    mapfile -t connected < <(for s in /sys/class/drm/card*-*/status; do
        [ "$(cat "$s")" = connected ] && basename "$(dirname "$s")"; done)
    case ${#connected[@]} in
        0) die "no connected monitor found; pass --connector" ;;
        1) connector=${connected[0]} ;;
        *) die "several monitors connected (${connected[*]}); pass --connector <one>" ;;
    esac
fi
[[ "$connector" =~ ^card[0-9]+-[A-Za-z0-9-]+$ ]] || die "invalid connector name: $connector"
[ -e "/sys/class/drm/$connector/status" ] || die "/sys/class/drm/$connector does not exist"
echo "    using $connector"

step "Installing user scripts to $bindir"
install -Dm755 "$here/bin/sunshine-virtual-display" "$bindir/sunshine-virtual-display"
install -Dm755 "$here/bin/sunshine-steam" "$bindir/sunshine-steam"

step "Installing root helper and sudoers rule (sudo)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed "s/@CONNECTOR@/$connector/" "$here/sbin/sunshine-dp-power.in" > "$tmp/sunshine-dp-power"
echo "$USER ALL=(root) NOPASSWD: /usr/local/bin/sunshine-dp-power" > "$tmp/sudoers"
visudo -cqf "$tmp/sudoers" || die "generated sudoers rule failed validation"
sudo install -m 755 -o root -g root "$tmp/sunshine-dp-power" /usr/local/bin/sunshine-dp-power
sudo install -m 440 -o root -g root "$tmp/sudoers" /etc/sudoers.d/sunshine-dp-power

step "Configuring Sunshine in $confdir"
mkdir -p "$confdir"
stamp=$(date +%Y%m%d-%H%M%S)
touch "$confdir/sunshine.conf"
cp "$confdir/sunshine.conf" "$confdir/sunshine.conf.bak-$stamp"
if grep -qE '^\s*capture\s*=' "$confdir/sunshine.conf"; then
    sed -i -E 's/^\s*capture\s*=.*/capture = portal/' "$confdir/sunshine.conf"
else
    echo "capture = portal" >> "$confdir/sunshine.conf"
fi
[ -f "$confdir/apps.json" ] && cp "$confdir/apps.json" "$confdir/apps.json.bak-$stamp"
python3 - "$confdir/apps.json" <<'EOF'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as f:
        conf = json.load(f)
except FileNotFoundError:
    conf = {"apps": [{"name": "Desktop", "image-path": "desktop.png"}]}

start = {"do": "sunshine-virtual-display start", "undo": "sunshine-virtual-display stop"}
reset = {"do": "sunshine-virtual-display reset", "undo": ""}
steam_close = {"do": "", "undo": "sunshine-steam steam://close/bigpicture"}
new_apps = [
    {"name": "Desktop (Screen Off)", "image-path": "desktop.png", "prep-cmd": [start]},
    {"name": "Steam Big Picture (Screen Off)", "image-path": "steam.png",
     "detached": ["sunshine-steam steam://open/bigpicture"],
     "prep-cmd": [start, steam_close]},
]

apps = conf.setdefault("apps", [])
# Normal apps first make sure the physical monitor and portal permission are back.
for app in apps:
    prep = app.setdefault("prep-cmd", [])
    if not any("sunshine-virtual-display" in (p.get("do") or "") for p in prep):
        prep.insert(0, dict(reset))
names = {a.get("name") for a in apps}
apps.extend(a for a in new_apps if a["name"] not in names)

env = conf.setdefault("env", {})
path_env = env.get("PATH", "$(PATH)")
if "$(HOME)/.local/bin" not in path_env:
    env["PATH"] = path_env + ":$(HOME)/.local/bin"

with open(path, "w") as f:
    json.dump(conf, f, indent=4)
    f.write("\n")
EOF

step "Installing login hook to restart Sunshine inside the desktop session"
sunshine_unit=sunshine.service
systemctl --user cat app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1 &&
    sunshine_unit=app-dev.lizardbyte.app.Sunshine.service
unitdir="$HOME/.config/systemd/user"
mkdir -p "$unitdir"
sed "s/@SUNSHINE_UNIT@/$sunshine_unit/" "$here/systemd/sunshine-session-restart.service.in" \
    > "$unitdir/sunshine-session-restart.service"
systemctl --user daemon-reload
systemctl --user enable sunshine-session-restart.service
echo "    restarts $sunshine_unit on login"

cat <<EOF

Installed. Backups: $confdir/*.bak-$stamp

Next steps:
  1. Restart Sunshine:
       systemctl --user restart app-dev.lizardbyte.app.Sunshine   # or: sunshine.service
  2. At the desk, GNOME asks which screen Sunshine may share: pick your
     physical monitor, allow remote interaction, click Share. This happens
     once; the choice is remembered.
  3. In Moonlight, start "Desktop (Screen Off)" or
     "Steam Big Picture (Screen Off)".
EOF
