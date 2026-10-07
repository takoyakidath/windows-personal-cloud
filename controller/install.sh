#!/usr/bin/env bash
# Raspberry Pi controller installer (product.txt §5, §41). Idempotent; run as root:
#   sudo ./controller/install.sh [--hardware-watchdog]
set -euo pipefail

CONTROLLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_USER=windows-controller
ETC=/etc/windows-controller
VENV=/opt/windows-controller/venv
UNIT=/etc/systemd/system/windows-controller.service

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
sed "s|@CONTROLLER_DIR@|$CONTROLLER_DIR|" "$CONTROLLER_DIR/systemd/windows-controller.service" > "$UNIT"
systemctl daemon-reload
systemctl enable windows-controller >/dev/null

if [[ "${1:-}" == "--hardware-watchdog" ]]; then
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
