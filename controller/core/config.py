"""Controller configuration: controller.json (+ DISCORD_TOKEN from the environment)."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from wake.wol import parse_mac

DEFAULT_PATH = Path("/etc/windows-controller/controller.json")


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class WindowsConfig:
    host: str
    ssh_user: str
    ssh_key: str
    mac_address: str
    name: str = "Windows PC"
    ssh_port: int = 22
    broadcast: str = "255.255.255.255"


@dataclass(frozen=True)
class DiscordConfig:
    guild_id: int = 0
    notify_channel_id: int = 0
    allowed_user_ids: frozenset[int] = frozenset()
    allowed_role_ids: frozenset[int] = frozenset()


@dataclass(frozen=True)
class WakeConfig:
    check_delays_seconds: list[int] = field(default_factory=lambda: [30, 60, 120, 120, 120, 150])
    resend_packet: bool = True


@dataclass(frozen=True)
class Config:
    windows: WindowsConfig
    discord: DiscordConfig
    wake: WakeConfig
    poll_interval_seconds: int = 30
    state_file: str = "/var/lib/windows-controller/state.json"
    log_dir: str = "/var/log/windows-controller"


def _require(section: dict, key: str, where: str):
    value = section.get(key)
    if value in (None, ""):
        raise ConfigError(f"{where}.{key} is required")
    return value


def load_config(path: Path | str = DEFAULT_PATH) -> Config:
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError as e:
        raise ConfigError(f"config not found: {path}") from e
    except json.JSONDecodeError as e:
        raise ConfigError(f"invalid JSON in {path}: {e}") from e

    w = raw.get("windows") or {}
    mac = _require(w, "mac_address", "windows")
    try:
        parse_mac(mac)
    except ValueError as e:
        raise ConfigError(f"windows.mac_address: {e}") from e
    windows = WindowsConfig(
        host=_require(w, "host", "windows"),
        ssh_user=_require(w, "ssh_user", "windows"),
        ssh_key=_require(w, "ssh_key", "windows"),
        mac_address=mac,
        name=w.get("name") or "Windows PC",
        ssh_port=int(w.get("ssh_port") or 22),
        broadcast=w.get("broadcast") or "255.255.255.255",
    )

    d = raw.get("discord") or {}
    users = frozenset(int(x) for x in d.get("allowed_user_ids") or [])
    roles = frozenset(int(x) for x in d.get("allowed_role_ids") or [])
    if not users and not roles:
        # Deny-by-default would make the bot useless; refuse to start instead of silently allowing nobody.
        raise ConfigError("discord.allowed_user_ids or discord.allowed_role_ids must not both be empty")
    discord = DiscordConfig(
        guild_id=int(d.get("guild_id") or 0),
        notify_channel_id=int(d.get("notify_channel_id") or 0),
        allowed_user_ids=users,
        allowed_role_ids=roles,
    )

    wk = raw.get("wake") or {}
    wake = WakeConfig(
        check_delays_seconds=[int(x) for x in wk.get("check_delays_seconds") or WakeConfig().check_delays_seconds],
        resend_packet=bool(wk.get("resend_packet", True)),
    )
    return Config(
        windows=windows,
        discord=discord,
        wake=wake,
        poll_interval_seconds=int(raw.get("poll_interval_seconds") or 30),
        state_file=raw.get("state_file") or Config.state_file,
        log_dir=raw.get("log_dir") or Config.log_dir,
    )
