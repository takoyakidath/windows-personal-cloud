"""Persistent controller state: what the Pi last knew about the Windows PC."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class ControllerState:
    last_seen: str | None = None    # ISO time the PC last answered
    last_mode: str | None = None    # winctl mode at that time (SLEEP means it was going to hibernate)
    last_state: str | None = None   # last classified state (READY, HIBERNATED, OFFLINE, ...)
    waking: bool = False            # a /win wake is in progress


class StateStore:
    def __init__(self, path: Path | str):
        self.path = Path(path)

    def load(self) -> ControllerState:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            known = {k: data[k] for k in ControllerState.__dataclass_fields__ if k in data}
            return ControllerState(**known)
        except (OSError, ValueError, TypeError):
            return ControllerState()

    def save(self, state: ControllerState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(state)), encoding="utf-8")
        os.replace(tmp, self.path)
