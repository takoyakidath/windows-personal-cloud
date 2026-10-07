from core.state import ControllerState, StateStore


def test_roundtrip(tmp_path):
    store = StateStore(tmp_path / "sub" / "state.json")
    assert store.load() == ControllerState()
    store.save(ControllerState(last_mode="SLEEP", last_seen="t", last_state="READY", waking=True))
    assert store.load() == ControllerState(last_mode="SLEEP", last_seen="t", last_state="READY", waking=True)


def test_corrupt_file_yields_default(tmp_path):
    p = tmp_path / "state.json"
    p.write_text("{not json")
    assert StateStore(p).load() == ControllerState()
