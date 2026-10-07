from core.config import WindowsConfig
from health.windows import WindowsClient, ALLOWED_COMMANDS
import pytest

CFG = WindowsConfig(host="10.0.0.2", ssh_user="me", ssh_key="/k", mac_address="aa:bb:cc:dd:ee:ff", ssh_port=2222)


def test_ssh_argv_is_fixed_and_batch_mode():
    argv = WindowsClient(CFG, known_hosts="/kh").ssh_argv("status")
    assert argv[0] == "ssh"
    assert "BatchMode=yes" in argv
    assert argv[-2:] == ["me@10.0.0.2", "status"]
    assert argv[argv.index("-p") + 1] == "2222"
    assert argv[argv.index("-i") + 1] == "/k"


def test_rejects_commands_outside_allowlist():
    client = WindowsClient(CFG, known_hosts="/kh")
    with pytest.raises(ValueError):
        client.ssh_argv("powershell -c whoami")
    assert "exec" not in ALLOWED_COMMANDS


async def test_run_parses_json(monkeypatch):
    client = WindowsClient(CFG, known_hosts="/kh")

    async def fake_exec(argv, timeout):
        return 0, b'{"state": "READY"}', b""

    monkeypatch.setattr(client, "_exec", fake_exec)
    assert await client.run("status") == {"state": "READY"}


async def test_run_raises_on_failure(monkeypatch):
    client = WindowsClient(CFG, known_hosts="/kh")

    async def fake_exec(argv, timeout):
        return 255, b"", b"Connection refused"

    monkeypatch.setattr(client, "_exec", fake_exec)
    with pytest.raises(RuntimeError, match="Connection refused"):
        await client.run("status")
