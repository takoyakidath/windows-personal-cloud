"""Talks to the Windows PC: TCP reachability + allowlisted winctl commands over SSH.

The Windows side installs this controller's key with a forced command (`winctl remote`), so the
command string sent here is only ever matched against winctl's own allowlist. This module keeps
a mirror of that list so nothing else is even sent.
"""

from __future__ import annotations

import asyncio
import json

from core.config import WindowsConfig
from health.status import Observation

# Mirror of $RemoteAllowlist in winctl/lib/Remote.ps1.
ALLOWED_COMMANDS = frozenset({
    "ping", "status", "doctor", "ready", "game", "work", "server",
    "sleep", "update", "reboot", "shutdown",
})

_SLOW = {"ready": 240, "game": 240, "work": 240, "server": 240}


class WindowsClient:
    def __init__(self, cfg: WindowsConfig, known_hosts: str):
        self.cfg = cfg
        self.known_hosts = known_hosts

    def ssh_argv(self, command: str) -> list[str]:
        if command not in ALLOWED_COMMANDS:
            raise ValueError(f"command not allowed: {command!r}")
        c = self.cfg
        return [
            "ssh", "-T",
            "-i", c.ssh_key,
            "-p", str(c.ssh_port),
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={self.known_hosts}",
            f"{c.ssh_user}@{c.host}",
            command,
        ]

    async def _exec(self, argv: list[str], timeout: float) -> tuple[int, bytes, bytes]:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise RuntimeError(f"timed out after {timeout:.0f}s")
        return proc.returncode, out, err

    async def run(self, command: str) -> dict:
        code, out, err = await self._exec(self.ssh_argv(command), _SLOW.get(command, 60))
        text = out.decode("utf-8", "replace").lstrip("﻿")
        # winctl prints one JSON line; ignore anything a shell profile might add around it.
        json_lines = [ln for ln in text.splitlines() if ln.strip().startswith("{")]
        if code != 0 and not json_lines:
            raise RuntimeError((err or out).decode("utf-8", "replace").strip() or f"ssh exit {code}")
        if not json_lines:
            raise RuntimeError("no JSON in winctl output")
        data = json.loads(json_lines[-1])
        if data.get("ok") is False:
            raise RuntimeError(data.get("error") or "winctl reported failure")
        return data

    async def reachable(self, timeout: float = 3.0) -> bool:
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection(self.cfg.host, self.cfg.ssh_port), timeout)
        except (OSError, asyncio.TimeoutError):
            return False
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass
        return True

    async def observe(self) -> Observation:
        if not await self.reachable():
            return Observation(reachable=False)
        try:
            return Observation(reachable=True, status=await self.run("status"))
        except (RuntimeError, ValueError) as e:
            return Observation(reachable=True, error=str(e))
