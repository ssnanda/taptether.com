#!/usr/bin/env bash
# Fixed privileged Ubuntu updater. Only the owner-approved systemd unit calls
# this script. The TapTether agent cannot inject commands, paths or URLs.
set -euo pipefail
[[ "$(id -u)" == 0 ]] || { echo 'Root-only update helper' >&2; exit 1; }
owner="${TAPTETHER_OWNER:-}"
home="${TAPTETHER_HOME:-}"
[[ "$owner" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && "$home" == /* &&
  "$home" != *$'\n'* ]] || { echo 'Invalid configured desktop owner' >&2; exit 1; }
actual_home="$(getent passwd "$owner" | cut -d: -f6)"
[[ "$actual_home" == "$home" ]] || { echo 'Configured user home changed' >&2; exit 1; }
arch="$(dpkg --print-architecture)"
[[ "$arch" == amd64 || "$arch" == arm64 ]] ||
  { echo 'Unsupported Ubuntu architecture' >&2; exit 1; }
current="$(/usr/local/bin/taptether-agent --version)"
info="$(python3 /usr/share/taptether/7b-tt-ubuntu-release-info.py "$arch" "$current")"
IFS=$'\t' read -r latest newer digest url <<<"$info"
if [[ "$newer" != yes ]]; then
  echo "TapTether already current: $current"
  exit 0
fi
tmp="$(mktemp -d /tmp/taptether-update.XXXXXXXX)"
chmod 0700 "$tmp"
trap 'rm -rf -- "$tmp"' EXIT
package="$tmp/taptether.deb"
curl --fail --location --silent --show-error --proto '=https'   --proto-redir '=https' --connect-timeout 12 --max-time 180 "$url"   -o "$package"
printf '%s  %s\n' "$digest" "$package" | sha256sum --check --status ||
  { echo 'Update SHA-256 mismatch' >&2; exit 1; }
[[ "$(dpkg-deb --field "$package" Package)" == taptether-agent &&
   "$(dpkg-deb --field "$package" Version)" == "$latest" &&
   "$(dpkg-deb --field "$package" Architecture)" == "$arch" ]] ||
  { echo 'Downloaded package identity mismatch' >&2; exit 1; }
# dpkg reads the root-only staging directory. apt's _apt sandbox cannot.
DEBIAN_FRONTEND=noninteractive dpkg --install "$package"
bundle=/usr/share/taptether
group="$(id -gn "$owner")"
for row in \
  "4-ubuntu-desktop-setup.sh|taptetherctl|0700" \
  "7-tt-update-ubuntu.sh|taptether-agent-update|0700"; do
  IFS='|' read -r source target mode <<<"$row"
  [[ -f "$bundle/$source" ]] || exit 1
  install -D -o "$owner" -g "$group" -m "$mode" \
    "$bundle/$source" "$home/.local/bin/$target"
done
install -D -o "$owner" -g "$group" -m 0755 \
  "$bundle/taptether_tray.py" \
  "$home/.local/share/taptether/taptether_tray.py"
install -D -o "$owner" -g "$group" -m 0644 \
  "$bundle/TapTether-icon.png" \
  "$home/.local/share/icons/hicolor/512x512/apps/taptether.png"
# Screen support is installed as the graphical desktop owner, not as root.
# Preserve the existing socket, consent token, pairing identity and uinput.
screen="$bundle/taptether_screen.py"
if [[ -s "$screen" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3-gi python3-pil gir1.2-gstreamer-1.0 \
    gir1.2-gst-plugins-base-1.0 gstreamer1.0-plugins-good \
    gstreamer1.0-pipewire xdg-desktop-portal >/dev/null 2>&1 || \
    echo 'TapTether screen dependencies need manual installation.' >&2
  runtime="/run/user/$(id -u "$owner")"
  if [[ -S "$runtime/bus" ]]; then
    runuser -u "$owner" -- env HOME="$home" XDG_RUNTIME_DIR="$runtime" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
      bash "$bundle/10-tt-ubuntu-screen-session.sh" install
  else
    runuser -u "$owner" -- env HOME="$home" \
      bash "$bundle/10-tt-ubuntu-screen-session.sh" install
  fi
fi
# Install the refreshed root helper for the next user-approved update.
install -D -m 0755 "$bundle/9-tt-system-update-ubuntu.sh" \
  /usr/local/libexec/taptether-update-ubuntu.sh
# Update-in-place also applies new per-agent defaults. This root-only, fixed
# helper is invoked by the computer owner's installed systemd update service,
# never by an arbitrary mobile command. A local opt-out marker remains intact.
policy="/etc/polkit-1/rules.d/80-taptether-shutdown.rules"
dropin="/etc/systemd/system/taptether-agent.service.d/40-shutdown.conf"
install -d -m 0755 "$(dirname "$policy")" "$(dirname "$dropin")"
cat >"$tmp/power.rules" <<POLKIT
polkit.addRule(function(action, subject) {
  if ((action.id === "org.freedesktop.login1.power-off" ||
       action.id === "org.freedesktop.login1.power-off-multiple-sessions") &&
      subject.user === "$owner" && subject.isInGroup("taptether")) {
    return polkit.Result.YES;
  }
});
POLKIT
install -m 0644 "$tmp/power.rules" "$policy"
printf '[Service]\\nEnvironment=TAPTETHER_ENABLE_SHUTDOWN=1\\n' \
  >"$tmp/power.conf"
install -m 0644 "$tmp/power.conf" "$dropin"
systemctl daemon-reload
systemctl restart taptether-agent.service
systemctl is-active --quiet taptether-agent.service
echo "TapTether agent upgraded and restarted to $latest"
