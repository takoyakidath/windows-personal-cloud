"""Send a magic packet by hand, e.g. for the WoL verification (docs/wol-verification.md).

    python -m wake aa:bb:cc:dd:ee:ff [broadcast]
"""

import sys

from wake.wol import send_magic_packet

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python -m wake <mac> [broadcast]")
    send_magic_packet(sys.argv[1], *(sys.argv[2:3] or []))
    print(f"magic packet sent to {sys.argv[1]}")
