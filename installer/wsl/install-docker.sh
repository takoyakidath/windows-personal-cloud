#!/usr/bin/env bash
# Installs Docker Engine + Compose plugin inside WSL2 Ubuntu (run as root). Idempotent.
# Usage: install-docker.sh <linux-user>
set -euo pipefail

user="${1:?usage: install-docker.sh <linux-user>}"

if ! command -v docker >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

getent group docker >/dev/null || groupadd docker
id -nG "$user" | grep -qw docker || usermod -aG docker "$user"

# Docker API stays on the local unix socket only (never exposed on TCP, product.txt §16).
systemctl enable --now docker >/dev/null
docker --version
docker compose version
