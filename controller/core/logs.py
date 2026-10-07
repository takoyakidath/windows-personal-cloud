"""Logging to /var/log/windows-controller/ (product.txt §38) and to stderr (journald)."""

from __future__ import annotations

import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path


def setup_logging(log_dir: str) -> None:
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    stderr = logging.StreamHandler()
    stderr.setFormatter(fmt)
    root.addHandler(stderr)
    try:
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        file = RotatingFileHandler(Path(log_dir) / "controller.log", maxBytes=2_000_000, backupCount=5, encoding="utf-8")
        file.setFormatter(fmt)
        root.addHandler(file)
    except OSError as e:
        root.warning("file logging disabled: %s", e)
    logging.getLogger("discord").setLevel(logging.WARNING)
