import json

import pytest

from core.config import ConfigError, load_config


def write(tmp_path, data):
    p = tmp_path / "controller.json"
    p.write_text(json.dumps(data))
    return p


def minimal():
    return {
        "windows": {"host": "10.0.0.2", "ssh_user": "u", "ssh_key": "/k", "mac_address": "aa:bb:cc:dd:ee:ff"},
        "discord": {"allowed_user_ids": [1]},
    }


def test_defaults_are_filled(tmp_path):
    cfg = load_config(write(tmp_path, minimal()))
    assert cfg.windows.ssh_port == 22
    assert cfg.windows.name == "Windows PC"
    assert cfg.wake.check_delays_seconds == [30, 60, 120, 120, 120, 150]
    assert cfg.poll_interval_seconds == 30
    assert cfg.discord.allowed_user_ids == {1}


def test_invalid_mac_is_rejected(tmp_path):
    data = minimal()
    data["windows"]["mac_address"] = "nope"
    with pytest.raises(ConfigError, match="mac_address"):
        load_config(write(tmp_path, data))


def test_missing_host_is_rejected(tmp_path):
    data = minimal()
    del data["windows"]["host"]
    with pytest.raises(ConfigError, match="host"):
        load_config(write(tmp_path, data))


def test_no_authorized_users_or_roles_is_rejected(tmp_path):
    data = minimal()
    data["discord"] = {}
    with pytest.raises(ConfigError, match="allowed_user_ids"):
        load_config(write(tmp_path, data))
