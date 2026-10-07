"""Minimal sd_notify (no dependency) for Type=notify + WatchdogSec (product.txt §41)."""

from __future__ import annotations

import os
import socket


def sd_notify(message: str) -> bool:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return False
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.connect(addr)
        sock.sendall(message.encode())
    return True


def watchdog_interval() -> float | None:
    """Half of WATCHDOG_USEC in seconds, or None when the watchdog is off."""
    usec = os.environ.get("WATCHDOG_USEC")
    return int(usec) / 2_000_000 if usec else None
