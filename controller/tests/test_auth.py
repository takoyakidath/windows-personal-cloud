from bot.auth import is_authorized
from core.config import DiscordConfig


def test_user_id_allowlist():
    cfg = DiscordConfig(allowed_user_ids=frozenset({1}))
    assert is_authorized(cfg, user_id=1, role_ids=[])
    assert not is_authorized(cfg, user_id=2, role_ids=[])


def test_role_allowlist():
    cfg = DiscordConfig(allowed_role_ids=frozenset({10}))
    assert is_authorized(cfg, user_id=2, role_ids=[5, 10])
    assert not is_authorized(cfg, user_id=2, role_ids=[5])


def test_empty_config_denies_everyone():
    assert not is_authorized(DiscordConfig(), user_id=1, role_ids=[1])
