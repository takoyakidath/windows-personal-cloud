#!/usr/bin/env bash
# Writes the first-boot (cloud-init) setup for the Raspberry Pi controller onto a freshly
# flashed Raspberry Pi OS card. On first boot the Pi clones this repo and runs
# controller/install.sh. No secrets are written: the Discord token is set later over SSH.
#
#   scripts/prepare-pi-sd.sh /Volumes/bootfs [options]
#     --hostname NAME        (default: wpc-controller)
#     --user NAME            (default: takoyaki)
#     --password-hash HASH   SHA-512 crypt hash (default: ask for a password)
#     --from DIR             reuse the user's password hash and network-config from an
#                            earlier Raspberry Pi Imager card (copies of user-data / network-config)
#     --network-config FILE  cloud-init network-config (Wi-Fi); default: wired DHCP only
#     --branch NAME          (default: main)
#     --with-token           ask for the Discord bot token (hidden input) and put it on the card;
#                            first boot moves it to /etc/windows-controller and deletes it from the card
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootfs="${1:?usage: prepare-pi-sd.sh <bootfs mount point> [options]}"; shift
hostname=wpc-controller user=takoyaki hash="" from="" netcfg="" branch=main with_token=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) hostname="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --password-hash) hash="$2"; shift 2 ;;
    --from) from="$2"; shift 2 ;;
    --network-config) netcfg="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --with-token) with_token=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$bootfs/cmdline.txt" && -f "$bootfs/config.txt" ]] || { echo "$bootfs does not look like a Raspberry Pi boot partition" >&2; exit 1; }

if [[ -n "$from" ]]; then
  [[ -z "$hash" ]] && hash="$(sed -nE 's/^[[:space:]]*passwd:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' "$from/user-data" | head -1)"
  [[ -z "$netcfg" && -f "$from/network-config" ]] && netcfg="$from/network-config"
fi
if [[ -z "$hash" ]]; then
  read -rsp "Password for $user on the Pi: " pw; echo
  hash="$(printf '%s' "$pw" | openssl passwd -6 -stdin)"
fi
[[ "$hash" == \$* ]] || { echo "password hash looks wrong" >&2; exit 1; }

repo_url="$(git -C "$root" remote get-url origin)"
sed -e "s|@HOSTNAME@|$hostname|" -e "s|@USER@|$user|" -e "s|@PASSWD_HASH@|$hash|" \
    -e "s|@BRANCH@|$branch|" -e "s|@REPO_URL@|$repo_url|" \
    -e "s|@TIMEZONE@|Asia/Tokyo|" -e "s|@KEYBOARD@|jp|" \
    "$root/controller/image/user-data.template" > "$bootfs/user-data"

if [[ -n "$netcfg" ]]; then
  [[ "$netcfg" -ef "$bootfs/network-config" ]] || cp "$netcfg" "$bootfs/network-config"
else
  printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: true\n      optional: true\n' > "$bootfs/network-config"
fi

instance="wpc-$(date +%s)"
printf 'dsmode: local\ninstance-id: %s\n' "$instance" > "$bootfs/meta-data"
# Point cloud-init at the boot partition (same as Raspberry Pi Imager does); replace any previous ds=.
cmdline="$(tr -d '\n' < "$bootfs/cmdline.txt" | sed -E 's/ ?ds=nocloud[^ ]*//')"
printf '%s ds=nocloud;i=%s\n' "$cmdline" "$instance" > "$bootfs/cmdline.txt"

if [[ $with_token -eq 1 ]]; then
  read -rsp "Discord bot token (input hidden): " token; echo
  [[ -n "$token" ]] || { echo "empty token" >&2; exit 1; }
  printf 'DISCORD_TOKEN=%s\n' "$token" > "$bootfs/wpc-secrets.env"
  unset token
  echo "Token written to $bootfs/wpc-secrets.env (moved off the card on first boot)."
fi

echo "First-boot setup written to $bootfs (hostname $hostname, user $user, branch $branch)."
