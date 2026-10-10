# sunshine-screen-off

Stream-only virtual display for [Sunshine](https://github.com/LizardByte/Sunshine) on **GNOME Wayland**.

Adds "Screen Off" apps to Sunshine. When one is launched from Moonlight:

- a virtual monitor is created at the client's exact resolution and frame rate (e.g. 2880x1800@60, 2560x1440@120)
- it becomes the **only** display, so windows, Steam Big Picture, etc. open there
- the physical monitor gets **no signal** and goes to standby, so nobody at the desk can see the stream
- when you quit the app in Moonlight, the virtual monitor is removed and the physical monitor comes back in your normal layout (resolution, refresh rate, VRR)

The virtual monitor is never a second screen next to your real one, and it only exists while a Screen Off session is running. If the helper process dies, Mutter removes the virtual monitor with it.

The normal apps (Desktop, Steam Big Picture) keep streaming the physical monitor as before.

## Tested on

| | |
|---|---|
| Distro | CachyOS (Arch) |
| Desktop | GNOME Shell / Mutter 50.5, Wayland |
| Sunshine | 2026.922 (Arch package, user service, started at boot via linger) |
| GPU | NVIDIA RTX 4070 Ti, driver 615.71 (`nvidia-drm.modeset=1`), plus AMD iGPU |
| Monitor | LG UltraGear 1440p165 over DisplayPort |

It should work on any GNOME ≥ 48 (needs `gdctl`) with a Sunshine build that has XDG Portal capture. Please open an issue if you try it elsewhere.

## How it works

There are three problems, each with a fix:

1. **A virtual monitor that only exists during the stream.** `sunshine-virtual-display` opens a Mutter ScreenCast session with `RecordVirtual`. Mutter creates a monitor (`Meta-0`) sized to the first PipeWire consumer's format, so the helper attaches a tiny GStreamer `pipewiresrc ! fakesink` pipeline asking for the client's `SUNSHINE_CLIENT_WIDTH`/`HEIGHT`/`FPS`. Then `gdctl` makes that monitor the only logical monitor. When the helper exits, the session closes, the monitor disappears, and Mutter falls back to your saved layout from `monitors.xml`.

2. **Sunshine must capture the virtual monitor without a dialog.** KMS capture can't see virtual monitors, so Sunshine uses `capture = portal`. The portal remembers the screen you picked by `vendor:product:serial`, but every Mutter virtual monitor gets a new serial. So the helper rewrites the monitor in Sunshine's saved permission (xdg-desktop-portal's PermissionStore, table `remote-desktop`, token from `~/.config/sunshine/portal_token`) to the new virtual monitor on start, and back to the physical one on stop.

3. **The physical monitor has to actually go dark.** Removing a monitor from GNOME's layout is not enough: Mutter never switches off that monitor's output (CRTC), so NVIDIA keeps sending the last frame and the monitor shows a frozen image. The helper therefore:
   - writes `off` to `/sys/class/drm/<connector>/status` through a tiny root helper (`sunshine-dp-power`, allowed by one sudoers line), so the kernel treats the monitor as unplugged, and
   - toggles Mutter's `PowerSaveMode` 3 → 0 for one second. Power-save switches off every output on the GPU; waking only re-enables outputs in the current layout, which now only has the virtual monitor. The monitor loses signal and sleeps.

   On stop, the connector goes back to `detect` and Mutter restores the monitor normally.

DDC/CI power-off (`ddcutil setvcp D6 05`) was tried first and doesn't work: many monitors fully disconnect and can't be woken over DDC again.

### Starting Sunshine at boot

With linger, Sunshine starts before anyone logs in. It then activates `xdg-desktop-portal` before GNOME is running, so the portal comes up without the GNOME backend (no ScreenCast interface). Sunshine never retries, and every stream fails with *"failed to initialize video capture/encoding"* (503), even after you log in. Portal capture needs a logged-in GNOME session anyway, so the installer adds `sunshine-session-restart.service`, which runs on `graphical-session.target` and restarts the portal and Sunshine once the desktop is up.

### Steam wrapper

If Sunshine starts before you log in (for example a user service with linger), it has no `DISPLAY`/`XAUTHORITY`, and Steam fails with *"Unable to open a connection to X"*. `sunshine-steam` imports those variables from the live session (`systemctl --user show-environment`) before running Steam. The XAuthority filename changes every login, so it can't be hardcoded.

## Installation

Dependencies (Arch package names):

```sh
sudo pacman -S --needed python-gobject gstreamer gst-plugin-pipewire mutter
```

Install:

```sh
git clone https://github.com/fqazzazee/sunshine-screen-off.git
cd sunshine-screen-off
./install.sh                         # auto-detects the connected monitor
./install.sh --connector card1-DP-1  # required if more than one monitor is connected
```

List connectors with `ls /sys/class/drm/ | grep -- -` and `cat /sys/class/drm/*/status`.

The installer:

- copies `sunshine-virtual-display` and `sunshine-steam` to `~/.local/bin`
- installs `/usr/local/bin/sunshine-dp-power` (root-owned, connector fixed at install time) and `/etc/sudoers.d/sunshine-dp-power`, checked with `visudo`, so only that command can run without a password
- sets `capture = portal` in `~/.config/sunshine/sunshine.conf`
- adds **Desktop (Screen Off)** and **Steam Big Picture (Screen Off)** to `~/.config/sunshine/apps.json`, and adds a `sunshine-virtual-display reset` prep step to your existing apps
- enables `sunshine-session-restart.service`, which restarts Sunshine after you log in (see below)
- saves timestamped backups of both config files

### First run

1. Restart Sunshine:
   ```sh
   systemctl --user restart app-dev.lizardbyte.app.Sunshine   # Arch/Flathub-style unit name
   # or: systemctl --user restart sunshine
   ```
2. **At the desk**, GNOME asks which screen Sunshine may share. Pick your physical monitor, allow remote interaction, and click **Share**. This happens only once.

   If Sunshine logs `RemoteDesktop Start: no streams in response`, an old permission without a screen is saved. Delete `~/.config/sunshine/portal_token` (or use *Reset XDG Portal Capture* in Sunshine's web UI), restart, and pick the screen again.

3. In Moonlight, start **Desktop (Screen Off)** or **Steam Big Picture (Screen Off)**.

## Usage

| App | Physical monitor | Streams |
|---|---|---|
| Desktop | on | physical monitor |
| Steam Big Picture | on | physical monitor |
| Desktop (Screen Off) | **off (no signal)** | virtual monitor at the client's resolution |
| Steam Big Picture (Screen Off) | **off (no signal)** | virtual monitor, Big Picture opened on it |

- **Quit** the app in Moonlight to end a Screen Off session and get the monitor back. **Disconnecting or suspending** keeps the app, and the dark monitor, running.
- Starting a normal app runs `reset` first, so it always brings the physical monitor back.

### Making your own Screen Off app

Add this prep step to any app in Sunshine's web UI or `apps.json`, as the **first** prep command so its undo runs last:

```json
{ "do": "sunshine-virtual-display start", "undo": "sunshine-virtual-display stop" }
```

`examples/apps.json` shows a complete file.

### Command reference

```text
sunshine-virtual-display start   create the virtual monitor, make it the only display, cut the physical signal
sunshine-virtual-display stop    remove it; the physical monitor comes back
sunshine-virtual-display reset   stop + force the physical monitor on + point the portal back at it
sudo sunshine-dp-power off|on    cut / restore the physical monitor's signal only
```

`start` reads `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT` and `SUNSHINE_CLIENT_FPS`, which Sunshine sets for prep commands, and defaults to 1920x1080@60. The log is at `$XDG_RUNTIME_DIR/sunshine-virtual-display.log`.

## Rescue over SSH

If the monitor stays dark (for example the helper was killed with `SIGKILL`, or Sunshine crashed mid-session), SSH in as the **same user** that is logged into GNOME. SSH sessions don't have the desktop's D-Bus address, so set it first:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
```

Then, from least to most drastic:

```sh
# 1. The normal fix: stop the virtual monitor, reconnect the physical one, fix the portal permission
~/.local/bin/sunshine-virtual-display reset

# 2. If that fails: do its steps by hand
pkill -f 'sunshine-virtual-display run'          # removes the virtual monitor
sudo /usr/local/bin/sunshine-dp-power on         # reconnect the physical monitor
gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
  --object-path /org/gnome/Mutter/DisplayConfig \
  --method org.freedesktop.DBus.Properties.Set \
  org.gnome.Mutter.DisplayConfig PowerSaveMode '<int32 0>'   # wake the screen
gdctl show                                       # the physical monitor should be listed

# 3. Kernel level (if the root helper is gone): replace the connector with yours
echo detect | sudo tee /sys/class/drm/card1-DP-1/status

# 4. Restart Sunshine, then log out and back in, then reboot
systemctl --user restart app-dev.lizardbyte.app.Sunshine
loginctl terminate-user "$USER"                  # ends the GNOME session
sudo reboot                                      # the sysfs override doesn't survive a reboot
```

Without SSH, starting the normal **Desktop** app from Moonlight also runs `reset`. Starting it still works while the physical monitor is off, though the stream may be black until the monitor reconnects.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Steam: *"Unable to open a connection to X"* | Sunshine started before login; use `sunshine-steam` instead of `steam` in the app. |
| Physical monitor shows a frozen frame | The power-save toggle didn't run. Check the log; `modetest -M nvidia-drm -p` shows whether the CRTC still has a framebuffer. |
| GNOME share dialog on every stream | The saved permission doesn't match. Run `reset`, restart Sunshine and pick the screen again. |
| Stream black / Sunshine can't find a display | Check `~/.config/sunshine/sunshine.log` for `[portalgrab]` lines and make sure `capture = portal`. |
| `virtual display failed to start` | Read `$XDG_RUNTIME_DIR/sunshine-virtual-display.log`. Needs `gst-plugin-pipewire` and GNOME ≥ 48 (`gdctl`). |

## Uninstallation

```sh
./uninstall.sh                 # keeps capture = portal
./uninstall.sh --capture kms   # also switches Sunshine back to KMS capture
systemctl --user restart app-dev.lizardbyte.app.Sunshine
```

This brings the monitor back, removes the Screen Off apps and the `reset` prep steps from `apps.json` (with a backup), and deletes the scripts, the root helper and the sudoers rule. `sunshine-steam` is kept if an app still uses it.

## Security notes

- The sudoers rule allows exactly one command, `/usr/local/bin/sunshine-dp-power on|off`. The script is root-owned and not writable by your user, and the connector it touches is fixed at install time.
- The helper only edits the portal permission whose token is in Sunshine's own `portal_token` file, and it changes only the monitor it points at.

## Support

If it let you stream with your monitor dark, you can [buy me a coffee ☕](https://buymeacoffee.com/fqazzazee).

## License

MIT
