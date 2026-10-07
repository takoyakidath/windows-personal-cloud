"""Wake-on-LAN magic packets (product.txt §9)."""

from __future__ import annotations

import re
import socket

_HEX = re.compile(r"[^0-9a-fA-F]")


def parse_mac(mac: str) -> bytes:
    """Parse aa:bb:cc:dd:ee:ff / AA-BB-.. / aabb.ccdd.eeff into 6 bytes."""
    digits = _HEX.sub("", mac or "")
    if len(digits) != 12 or len(re.sub(r"[:\-. ]", "", mac)) != 12:
        raise ValueError(f"invalid MAC address: {mac!r}")
    return bytes.fromhex(digits)


def build_magic_packet(mac: str) -> bytes:
    return b"\xff" * 6 + parse_mac(mac) * 16


def send_magic_packet(mac: str, broadcast: str = "255.255.255.255", port: int = 9, count: int = 3) -> None:
    packet = build_magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for _ in range(count):
            sock.sendto(packet, (broadcast, port))
