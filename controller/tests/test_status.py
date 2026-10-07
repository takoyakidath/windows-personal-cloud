from health.status import Observation, classify, format_status
from core.state import ControllerState

READY_STATUS = {
    "name": "Alienware m17 R3",
    "mode": "READY",
    "state": "READY",
    "uptime_seconds": 4 * 3600 + 32 * 60,
    "cpu": {"percent": 4, "temp_c": None},
    "memory": {"used_gb": 12, "total_gb": 64},
    "gpu": {"percent": 3, "vram_used_gb": 2, "vram_total_gb": 8, "temp_c": 45},
    "services": {"tailscale": "OK", "ssh": "OK", "wsl": "OK", "docker": "OK", "smb": "OK", "parsec": "STOPPED"},
    "checks": [{"name": "Workspace", "ok": True, "detail": "D:\\Workspace", "severity": "required"}],
}


def test_reachable_with_status_uses_windows_state():
    obs = Observation(reachable=True, status=READY_STATUS)
    assert classify(obs, ControllerState()) == "READY"


def test_reachable_but_winctl_fails_is_degraded():
    obs = Observation(reachable=True, status=None, error="timeout")
    assert classify(obs, ControllerState()) == "DEGRADED"


def test_unreachable_after_sleep_is_hibernated():
    state = ControllerState(last_mode="SLEEP", last_seen="2026-10-07T20:47:00+09:00")
    assert classify(Observation(reachable=False), state) == "HIBERNATED"


def test_unreachable_otherwise_is_offline():
    state = ControllerState(last_mode="READY", last_seen="2026-10-07T20:47:00+09:00")
    assert classify(Observation(reachable=False), state) == "OFFLINE"


def test_unreachable_while_waking_is_waking():
    state = ControllerState(last_mode="SLEEP", waking=True)
    assert classify(Observation(reachable=False), state) == "WAKING"


def test_format_ready_matches_product_layout():
    text = format_status("Alienware m17 R3", "READY", Observation(True, READY_STATUS), ControllerState())
    lines = text.splitlines()
    assert lines[0] == "🟢 Alienware m17 R3"
    assert "State: READY" in lines
    assert "CPU: 4%" in lines
    assert "RAM: 12 / 64 GB" in lines
    assert "GPU: 3%" in lines
    assert "VRAM: 2 / 8 GB" in lines
    assert "Tailscale: OK" in lines
    assert "Docker: OK" in lines
    assert "Workspace: OK" in lines
    assert "Uptime: 4h 32m" in lines


def test_format_hibernated_shows_last_seen_time():
    state = ControllerState(last_mode="SLEEP", last_seen="2026-10-07T20:47:00+09:00")
    text = format_status("Alienware m17 R3", "HIBERNATED", Observation(False), state)
    assert text.splitlines() == ["💤 Alienware m17 R3", "", "State: HIBERNATED", "", "Last Seen: 20:47"]


def test_format_offline():
    text = format_status("Alienware m17 R3", "OFFLINE", Observation(False), ControllerState())
    assert text.splitlines() == ["🔴 Alienware m17 R3", "", "State: OFFLINE"]


def test_format_shows_backup_age_and_sleep_block():
    status = dict(READY_STATUS)
    status["checks"] = READY_STATUS["checks"] + [{"name": "Backup", "ok": False, "detail": "9 days ago", "severity": "info"}]
    status["inhibit_sleep"] = True
    status["inhibit_until"] = "2026-10-08T06:00:00+09:00"
    lines = format_status("PC", "READY", Observation(True, status), ControllerState()).splitlines()
    assert "Last Backup: 9 days ago ⚠️" in lines
    assert "Auto-sleep: blocked until 06:00" in lines
