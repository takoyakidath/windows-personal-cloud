"""Background polling, the /win wake flow (product.txt §8, §26) and failure handling (§40)."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import replace
from datetime import datetime

from core.config import WakeConfig
from core.state import ControllerState
from health.status import READY_STATES, Observation, classify

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
        """One periodic check. Notifies on transitions into HIBERNATED and ERROR."""
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

    async def wake(self) -> str:
        async with self._wake_lock:
            obs, display, _ = await self.observe()
            if obs.reachable and display in READY_STATES:
                return display

            self.store.save(replace(self.store.load(), waking=True))
            try:
                log.info("sending magic packet")
                self.send_wol()
                await self.notify("⚡ Wake requested.")
                for delay in self.wake_config.check_delays_seconds:
                    await self.sleep(delay)
                    obs, display, _ = await self.observe()
                    log.info("wake check: %s", display)
                    if obs.reachable and display in READY_STATES:
                        await self.notify("🟢 Windows PC is ready.")
                        return display
                    if not obs.reachable and self.wake_config.resend_packet:
                        self.send_wol()
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
