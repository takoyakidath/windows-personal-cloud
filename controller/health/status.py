"""Classify what the Pi observes into a display state and render /win status (product.txt §7)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from core.state import ControllerState

# States reported by winctl in which the PC is usable.
READY_STATES = frozenset({"READY", "WORK", "SERVER", "GAME"})

ICONS = {
    "READY": "🟢", "WORK": "🟢", "SERVER": "🟢", "GAME": "🎮",
    "SLEEP": "💤", "HIBERNATED": "💤", "WAKING": "⚡",
    "DEGRADED": "🟡", "ERROR": "🔴", "OFFLINE": "🔴",
}

SERVICE_LABELS = [
    ("tailscale", "Tailscale"), ("ssh", "SSH"), ("wsl", "WSL2"),
    ("docker", "Docker"), ("smb", "SMB"), ("parsec", "Parsec"),
]


@dataclass(frozen=True)
class Observation:
    reachable: bool
    status: dict | None = None   # `winctl status --json` output when SSH worked
    error: str | None = None


def classify(obs: Observation, state: ControllerState) -> str:
    if obs.reachable and obs.status:
        return str(obs.status.get("state") or "DEGRADED").upper()
    if obs.reachable:
        return "DEGRADED"   # Windows is up but winctl did not answer
    if state.waking:
        return "WAKING"
    if state.last_mode == "SLEEP":
        return "HIBERNATED"
    return "OFFLINE"


def _hhmm(iso: str | None) -> str | None:
    if not iso:
        return None
    try:
        return datetime.fromisoformat(iso).strftime("%H:%M")
    except ValueError:
        return iso


def _uptime(seconds: int) -> str:
    days, rem = divmod(int(seconds), 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    return f"{days}d {hours}h {minutes}m" if days else f"{hours}h {minutes}m"


def format_status(name: str, display_state: str, obs: Observation, state: ControllerState) -> str:
    lines = [f"{ICONS.get(display_state, '⚪')} {name}", "", f"State: {display_state}"]
    s = obs.status
    if not s:
        if display_state in ("HIBERNATED", "WAKING") and _hhmm(state.last_seen):
            lines += ["", f"Last Seen: {_hhmm(state.last_seen)}"]
        if obs.error:
            lines += ["", f"Error: {obs.error}"]
        return "\n".join(lines)

    lines.append("")
    cpu, mem, gpu = s.get("cpu") or {}, s.get("memory") or {}, s.get("gpu")
    lines.append(f"CPU: {cpu.get('percent', '?')}%")
    lines.append(f"RAM: {mem.get('used_gb', '?')} / {mem.get('total_gb', '?')} GB")
    if gpu:
        lines.append(f"GPU: {gpu.get('percent', '?')}%")
        lines.append(f"VRAM: {gpu.get('vram_used_gb', '?')} / {gpu.get('vram_total_gb', '?')} GB")

    lines.append("")
    services = s.get("services") or {}
    for key, label in SERVICE_LABELS:
        if key in services:
            lines.append(f"{label}: {services[key]}")
    workspace = next((c for c in s.get("checks") or [] if c.get("name") == "Workspace"), None)
    if workspace is not None:
        lines.append(f"Workspace: {'OK' if workspace.get('ok') else 'MISSING'}")

    backup = next((c for c in s.get("checks") or [] if c.get("name") == "Backup"), None)
    if backup is not None:
        lines.append(f"Last Backup: {backup.get('detail')}" + ("" if backup.get("ok") else " ⚠️"))
    if s.get("inhibit_sleep"):
        until = _hhmm(s.get("inhibit_until"))
        lines.append(f"Auto-sleep: blocked until {until}" if until else "Auto-sleep: blocked")

    failed = [c["name"] for c in s.get("checks") or [] if not c.get("ok") and c.get("severity") != "info"]
    if failed:
        lines += ["", "Problems: " + ", ".join(failed)]
    if "uptime_seconds" in s:
        lines += ["", f"Uptime: {_uptime(s['uptime_seconds'])}"]
    return "\n".join(lines)
