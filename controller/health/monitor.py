"""Background polling, the /win wake flow (product.txt §8, §26) and failure handling (§40)."""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import replace
from datetime import datetime

from core.config import WakeConfig
from core.state import ControllerState
from health.status import ICONS, READY_STATES, Observation, classify

log = logging.getLogger("controller.monitor")


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


class Monitor:
    def __init__(
        self,
        name: str,
        client,
        store,
        wake_config: WakeConfig,
        send_wol: Callable[[], None],
        notify: Callable[[str], Awaitable[None]],
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ):
        self.name = name
        self.client = client
        self.store = store
        self.wake_config = wake_config
        self.send_wol = send_wol
        self.notify = notify
        self.sleep = sleep
        self._wake_lock = asyncio.Lock()
        self._quiet_until = 0.0

    def expect_offline(self, seconds: float) -> None:
        """A reboot/shutdown was requested: going offline in the next `seconds` is not an incident."""
        self._quiet_until = time.monotonic() + seconds

    @property
    def waking(self) -> bool:
        return self._wake_lock.locked()

    def _record(self, obs: Observation, display: str) -> ControllerState:
        state = self.store.load()
        if obs.reachable:
            mode = (obs.status or {}).get("mode") or state.last_mode
            state = replace(state, last_seen=_now(), last_mode=mode)
        state = replace(state, last_state=display)
        self.store.save(state)
        return state

    async def observe(self) -> tuple[Observation, str, ControllerState]:
        obs = await self.client.observe()
        display = classify(obs, self.store.load())
        return obs, display, self._record(obs, display)

    async def poll(self) -> None:
        """One periodic check. Notifies on state transitions worth knowing about."""
        if self._wake_lock.locked():
            return
        previous = self.store.load().last_state
        _, display, _ = await self.observe()
        if display == previous:
            return
        log.info("state %s -> %s", previous, display)
        if display == "HIBERNATED":
            await self.notify("💤 Windows PC entered Hibernate.")
        elif display == "ERROR":
            await self.notify("🔴 Windows PC failed health check.")
        elif display == "OFFLINE" and previous in READY_STATES | {"DEGRADED"} and time.monotonic() >= self._quiet_until:
            # Gone without `winctl sleep`: crash, power loss, network or manual shutdown.
            await self.notify("🔴 Windows PC went offline unexpectedly.")
        elif display in READY_STATES and previous in ("OFFLINE", "HIBERNATED"):
            # Came back without /win wake (power button, scheduled reboot, ...).
            await self.notify("🟢 Windows PC is back online.")

    async def _apply_mode(self, mode: str | None, display: str) -> str:
        if not mode:
            return display
        try:
            result = await self.client.run(mode)
        except (RuntimeError, ValueError) as e:
            await self.notify(f"🔴 Switching to {mode.upper()} failed: {e}")
            return display
        new = str(result.get("state") or display)
        self._record(Observation(True, result), new)
        await self.notify(f"{ICONS.get(new, '⚪')} Mode: {new}")
        return new

    async def wake(self, mode: str | None = None) -> str:
        """Wake the PC; optionally switch to `mode` (ready/game/work/server) once it is up."""
        async with self._wake_lock:
            obs, display, _ = await self.observe()
            if obs.reachable and display in READY_STATES:
                return await self._apply_mode(mode, display)

            self.store.save(replace(self.store.load(), waking=True))
            try:
                log.info("sending magic packet")
                try:
                    self.send_wol()
                except OSError as e:
                    # e.g. ENETUNREACH when the direct WoL cable is unplugged and eth0 has no address.
                    log.error("magic packet failed: %s", e)
                    await self.notify(f"🔴 Could not send Wake-on-LAN: {e}")
                    return "OFFLINE"
                await self.notify("⚡ Wake requested.")
                for delay in self.wake_config.check_delays_seconds:
                    await self.sleep(delay)
                    obs, display, _ = await self.observe()
                    log.info("wake check: %s", display)
                    if obs.reachable and display in READY_STATES:
                        await self.notify("🟢 Windows PC is ready.")
                        return await self._apply_mode(mode, display)
                    if not obs.reachable and self.wake_config.resend_packet:
                        try:
                            self.send_wol()
                        except OSError as e:
                            log.warning("magic packet resend failed: %s", e)
            finally:
                self.store.save(replace(self.store.load(), waking=False))

            if obs.reachable:
                await self.notify(f"🔴 Windows PC failed health check. (State: {display})")
                return display
            await self.notify("🔴 Windows failed to become ready.")
            self._record(obs, "OFFLINE")
            return "OFFLINE"

    async def run_forever(self, interval: float) -> None:
        while True:
            try:
                await self.poll()
            except Exception:  # keep polling no matter what
                log.exception("poll failed")
            await asyncio.sleep(interval)
