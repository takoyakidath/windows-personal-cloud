from core.config import WakeConfig
from core.state import ControllerState
from health.monitor import Monitor
from health.status import Observation


class FakeClient:
    def __init__(self, observations):
        self.observations = list(observations)
        self.calls = 0

    async def observe(self):
        self.calls += 1
        if len(self.observations) > 1:
            return self.observations.pop(0)
        return self.observations[0]


class MemoryStore:
    def __init__(self, state=None):
        self.state = state or ControllerState()

    def load(self):
        return self.state

    def save(self, state):
        self.state = state


def ready(state="READY"):
    return Observation(True, {"state": state, "mode": state})


def make(observations, delays=(30, 60, 120)):
    sent, notes, slept = [], [], []

    async def notify(msg):
        notes.append(msg)

    async def sleep(s):
        slept.append(s)

    m = Monitor(
        name="PC",
        client=FakeClient(observations),
        store=MemoryStore(ControllerState(last_mode="SLEEP")),
        wake_config=WakeConfig(check_delays_seconds=list(delays)),
        send_wol=lambda: sent.append(1),
        notify=notify,
        sleep=sleep,
    )
    return m, sent, notes, slept


async def test_wake_when_already_up_sends_nothing():
    m, sent, notes, _ = make([ready()])
    result = await m.wake()
    assert result == "READY"
    assert sent == []


async def test_wake_sends_packet_and_reports_ready():
    m, sent, notes, slept = make([Observation(False), Observation(False), Observation(False), ready()])
    result = await m.wake()
    assert result == "READY"
    assert len(sent) >= 1
    assert slept[:2] == [30, 60]
    assert notes[0].startswith("⚡")
    assert notes[-1].startswith("🟢")
    assert m.store.state.waking is False


async def test_wake_waits_through_degraded_until_ready():
    m, _, notes, _ = make([Observation(False), ready("DEGRADED"), ready()])
    assert await m.wake() == "READY"


async def test_wake_timeout_reports_failure():
    m, _, notes, slept = make([Observation(False)], delays=(30, 60, 120))
    result = await m.wake()
    assert result == "OFFLINE"
    assert slept == [30, 60, 120]
    assert notes[-1] == "🔴 Windows failed to become ready."
    assert m.store.state.waking is False


async def test_poll_records_last_seen_and_mode():
    m, *_ = make([ready("SLEEP")])
    await m.poll()
    assert m.store.state.last_mode == "SLEEP"
    assert m.store.state.last_seen


async def test_poll_notifies_hibernate_transition():
    m, _, notes, _ = make([ready("SLEEP"), Observation(False)])
    await m.poll()
    await m.poll()
    assert notes == ["💤 Windows PC entered Hibernate."]


async def test_poll_notifies_health_failure_once():
    m, _, notes, _ = make([ready("READY"), ready("ERROR"), ready("ERROR")])
    for _ in range(3):
        await m.poll()
    assert notes == ["🔴 Windows PC failed health check."]
