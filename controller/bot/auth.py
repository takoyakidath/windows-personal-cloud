"""Who may control the PC from Discord (product.txt §6.2): explicit user IDs or role IDs only."""

from __future__ import annotations

from collections.abc import Iterable

from core.config import DiscordConfig


def is_authorized(cfg: DiscordConfig, user_id: int, role_ids: Iterable[int]) -> bool:
    if user_id in cfg.allowed_user_ids:
        return True
    return any(r in cfg.allowed_role_ids for r in role_ids)
