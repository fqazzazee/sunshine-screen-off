#!/usr/bin/env bash
# Remove sunshine-screen-off and restore normal monitor behaviour.
#   ./uninstall.sh [--capture kms|wlr|x11|...]   also switch Sunshine's capture method back
set -euo pipefail

bindir="$HOME/.local/bin"
confdir="$HOME/.config/sunshine"
capture=""

while [ $# -gt 0 ]; do
    case "$1" in
        --capture) capture="${2:?--capture needs a value, e.g. kms}"; shift 2 ;;
        -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

step() { echo "==> $*"; }

step "Stopping any stream-only display and restoring the monitor"
if [ -x "$bindir/sunshine-virtual-display" ]; then
    "$bindir/sunshine-virtual-display" reset || true
elif [ -x /usr/local/bin/sunshine-dp-power ]; then
    sudo /usr/local/bin/sunshine-dp-power on || true
fi

step "Removing Sunshine apps and prep commands"
if [ -f "$confdir/apps.json" ]; then
    cp "$confdir/apps.json" "$confdir/apps.json.bak-$(date +%Y%m%d-%H%M%S)"
    python3 - "$confdir/apps.json" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    conf = json.load(f)
apps = [a for a in conf.get("apps", [])
        if a.get("name") not in ("Desktop (Screen Off)", "Steam Big Picture (Screen Off)")]
for app in apps:
    prep = [p for p in app.get("prep-cmd", [])
            if "sunshine-virtual-display" not in (p.get("do") or "") + (p.get("undo") or "")]
    if prep:
        app["prep-cmd"] = prep
    else:
        app.pop("prep-cmd", None)
conf["apps"] = apps
with open(path, "w") as f:
    json.dump(conf, f, indent=4)
    f.write("\n")
EOF
fi

if [ -n "$capture" ] && [ -f "$confdir/sunshine.conf" ]; then
    step "Setting Sunshine capture = $capture"
    sed -i -E "s/^\s*capture\s*=.*/capture = $capture/" "$confdir/sunshine.conf"
fi

step "Removing scripts"
rm -f "$bindir/sunshine-virtual-display"
# sunshine-steam is still used by the plain "Steam Big Picture" app if you kept it.
if ! grep -q sunshine-steam "$confdir/apps.json" 2>/dev/null; then
    rm -f "$bindir/sunshine-steam"
fi
rm -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/sunshine-virtual-display.*

step "Removing login hook"
systemctl --user disable sunshine-session-restart.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/sunshine-session-restart.service"
systemctl --user daemon-reload

step "Removing root helper and sudoers rule (sudo)"
sudo rm -f /usr/local/bin/sunshine-dp-power /etc/sudoers.d/sunshine-dp-power

cat <<EOF

Uninstalled. Restart Sunshine to pick up the changes:
  systemctl --user restart app-dev.lizardbyte.app.Sunshine   # or: sunshine.service
EOF
