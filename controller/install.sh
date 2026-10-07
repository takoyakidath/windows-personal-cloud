#!/usr/bin/env bash
# Raspberry Pi controller installer (product.txt §5, §41). Idempotent; run as root:
#   sudo ./controller/install.sh [--hardware-watchdog] [--wol-link 10.99.0.1/24]
#
#   --wol-link CIDR   eth0 is a direct cable to the PC used only for Wake-on-LAN: give it this
#                     static address (no gateway) and set windows.broadcast in controller.json to
#                     that subnet's broadcast (e.g. 10.99.0.255) so magic packets leave via eth0.
# Both settings persist, so later runs (e.g. from update.sh) need not repeat the options.
set -euo pipefail

HARDWARE_WATCHDOG=0
WOL_LINK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hardware-watchdog) HARDWARE_WATCHDOG=1; shift ;;
    --wol-link) WOL_LINK="${2:?--wol-link needs an address like 10.99.0.1/24}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

CONTROLLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_USER=windows-controller
ETC=/etc/windows-controller
VENV=/opt/windows-controller/venv

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

echo "==> packages"
apt-get update -q
apt-get install -y -q python3 python3-venv openssh-client

echo "==> user and directories"
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home-dir /var/lib/windows-controller --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -o root -g "$SERVICE_USER" -m 0750 "$ETC"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 /var/lib/windows-controller /var/log/windows-controller

echo "==> python venv"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$CONTROLLER_DIR/requirements.txt"

echo "==> configuration (existing files are never overwritten)"
[[ -f "$ETC/controller.json" ]] || install -o root -g "$SERVICE_USER" -m 0640 "$CONTROLLER_DIR/config/controller.example.json" "$ETC/controller.json"
[[ -f "$ETC/controller.env" ]] || install -o root -g "$SERVICE_USER" -m 0640 "$CONTROLLER_DIR/config/controller.env.example" "$ETC/controller.env"

echo "==> SSH key for the Windows PC"
if [[ ! -f "$ETC/id_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "windows-controller@$(hostname)" -f "$ETC/id_ed25519"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$ETC/id_ed25519" "$ETC/id_ed25519.pub"
chmod 0600 "$ETC/id_ed25519"

echo "==> systemd"
if ! runuser -u "$SERVICE_USER" -- test -r "$CONTROLLER_DIR/bot/app.py"; then
  echo "$SERVICE_USER cannot read $CONTROLLER_DIR. Clone the repo to /opt/windows-personal-cloud instead." >&2
  exit 1
fi
# The service runs the code straight from this checkout; it must be readable by the service user.
for unit in windows-controller.service windows-controller-update.service windows-controller-update.timer; do
  sed "s|@CONTROLLER_DIR@|$CONTROLLER_DIR|" "$CONTROLLER_DIR/systemd/$unit" > "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable windows-controller >/dev/null
# Daily git pull (fast-forward only) + reinstall when controller/ changed: controller/update.sh
systemctl enable --now windows-controller-update.timer >/dev/null

if [[ -n "$WOL_LINK" ]]; then
  echo "==> eth0 WoL link ($WOL_LINK)"
  # Reuse whatever NetworkManager profile owns eth0 (cloud-init creates netplan-eth0), else create one.
  con="$(nmcli -t -f NAME,DEVICE connection show | awk -F: '$2=="eth0"{print $1; exit}')"
  if [[ -z "$con" ]]; then
    con="$(nmcli -t -f NAME connection show | grep -x -e 'netplan-eth0' -e 'wol-link' | head -1 || true)"
  fi
  if [[ -z "$con" ]]; then
    nmcli connection add type ethernet ifname eth0 con-name wol-link >/dev/null
    con=wol-link
  fi
  nmcli connection modify "$con" ipv4.method manual ipv4.addresses "$WOL_LINK" ipv4.gateway "" \
    ipv4.never-default yes ipv6.method disabled connection.autoconnect yes
  nmcli connection up "$con" >/dev/null 2>&1 || echo "    eth0 not up yet (cable unplugged?); it will come up with the link"
  echo "    $con: $WOL_LINK (set windows.broadcast to this subnet's broadcast address)"
fi

if [[ $HARDWARE_WATCHDOG -eq 1 ]]; then
  # Reboot the Pi itself if the kernel hangs.
  mkdir -p /etc/systemd/system.conf.d
  printf '[Manager]\nRuntimeWatchdogSec=15\n' > /etc/systemd/system.conf.d/watchdog.conf
  systemctl daemon-reexec
  echo "    hardware watchdog enabled"
fi

if grep -q '^DISCORD_TOKEN=.\+' "$ETC/controller.env" && ! grep -q '"aa:bb:cc:dd:ee:ff"' "$ETC/controller.json"; then
  systemctl restart windows-controller
  echo "==> started: journalctl -u windows-controller -f"
else
  cat <<MSG

Next steps:
  1. Edit $ETC/controller.json  (Windows host / MAC / Discord IDs)
  2. Put the bot token in        $ETC/controller.env
  3. Add this public key to config/ssh/controller.pub in the repo and run the Windows installer
     (or winctl update):

$(cat "$ETC/id_ed25519.pub")

  4. sudo systemctl restart windows-controller
MSG
fi
