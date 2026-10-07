"""Discord slash commands: /win status, /win wake, ... (product.txt §6, §42).

Every command maps to one allowlisted winctl command. There is no way to send arbitrary input to
the PC: no command takes free text.
"""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import replace
from pathlib import Path

import discord
from discord import app_commands

from bot.auth import is_authorized
from core.config import Config
from core.state import StateStore
from core.systemd import sd_notify, watchdog_interval
from health.monitor import Monitor
from health.status import Observation, format_status
from health.windows import WindowsClient
from wake.wol import send_magic_packet

log = logging.getLogger("controller.bot")


class ControllerBot(discord.Client):
    def __init__(self, config: Config):
        super().__init__(intents=discord.Intents.default())
        self.config = config
        self.tree = app_commands.CommandTree(self)
        state_path = Path(config.state_file)
        self.store = StateStore(state_path)
        # A wake interrupted by a restart must not leave the PC shown as WAKING forever.
        self.store.save(replace(self.store.load(), waking=False))
        self.client = WindowsClient(config.windows, known_hosts=str(state_path.parent / "known_hosts"))
        w = config.windows
        self.monitor = Monitor(
            name=w.name,
            client=self.client,
            store=self.store,
            wake_config=config.wake,
            send_wol=lambda: send_magic_packet(w.mac_address, w.broadcast),
            notify=self.notify,
        )
        self.tree.add_command(build_group(self))
        self._background: set[asyncio.Task] = set()

    def spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    async def setup_hook(self) -> None:
        if self.config.discord.guild_id:
            guild = discord.Object(id=self.config.discord.guild_id)
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
        else:
            await self.tree.sync()
        self.spawn(self.monitor.run_forever(self.config.poll_interval_seconds))
        interval = watchdog_interval()
        if interval:
            self.spawn(self._watchdog(interval))

    async def on_ready(self) -> None:
        log.info("logged in as %s", self.user)
        sd_notify("READY=1")

    async def _watchdog(self, interval: float) -> None:
        while True:
            sd_notify("WATCHDOG=1")
            await asyncio.sleep(interval)

    async def notify(self, message: str) -> None:
        log.info("notify: %s", message)
        channel_id = self.config.discord.notify_channel_id
        if not channel_id:
            return
        try:
            channel = self.get_channel(channel_id) or await self.fetch_channel(channel_id)
            await channel.send(message)
        except discord.DiscordException:
            log.exception("failed to send notification")


def _block(text: str) -> str:
    return text if len(text) < 1900 else text[:1900] + "\n…"


def build_group(bot: ControllerBot) -> app_commands.Group:
    group = app_commands.Group(name="win", description="Control the Windows PC")

    async def authorized(interaction: discord.Interaction) -> bool:
        roles = [r.id for r in getattr(interaction.user, "roles", [])]
        if is_authorized(bot.config.discord, interaction.user.id, roles):
            return True
        log.warning("denied /win for user %s", interaction.user.id)
        await interaction.response.send_message("You are not allowed to control this PC.", ephemeral=True)
        return False

    async def status_text() -> tuple[Observation, str, str]:
        obs, display, state = await bot.monitor.observe()
        return obs, display, format_status(bot.config.windows.name, display, obs, state)

    async def run_remote(interaction: discord.Interaction, command: str, done: str | None = None) -> None:
        """Runs an allowlisted command after making sure the PC is reachable."""
        if not await authorized(interaction):
            return
        await interaction.response.defer(thinking=True)
        log.info("/win %s by %s", command, interaction.user.id)
        if not await bot.client.reachable():
            _, display, text = await status_text()
            await interaction.followup.send(_block(f"PC is not reachable. Use `/win wake` first.\n\n{text}"))
            return
        try:
            result = await bot.client.run(command)
        except (RuntimeError, ValueError) as e:
            await interaction.followup.send(f"🔴 `{command}` failed: {e}")
            return
        if done:
            await interaction.followup.send(done)
        else:
            obs = Observation(True, result)
            display = str(result.get("state") or "DEGRADED")
            await interaction.followup.send(_block(format_status(bot.config.windows.name, display, obs, bot.store.load())))

    @group.command(name="status", description="Show the PC state")
    async def status(interaction: discord.Interaction):
        if not await authorized(interaction):
            return
        await interaction.response.defer(thinking=True)
        _, _, text = await status_text()
        await interaction.followup.send(_block(text))

    @group.command(name="wake", description="Wake the PC with Wake-on-LAN")
    @app_commands.describe(mode="Mode to switch to once the PC is up")
    @app_commands.choices(mode=[
        app_commands.Choice(name="READY", value="ready"),
        app_commands.Choice(name="GAME", value="game"),
        app_commands.Choice(name="WORK", value="work"),
        app_commands.Choice(name="SERVER", value="server"),
    ])
    async def wake(interaction: discord.Interaction, mode: app_commands.Choice[str] | None = None):
        if not await authorized(interaction):
            return
        await interaction.response.defer(thinking=True)
        target = mode.value if mode else None
        log.info("/win wake mode=%s by %s", target, interaction.user.id)
        if bot.monitor.waking:
            await interaction.followup.send("⚡ Wake already in progress.")
            return
        obs, display, text = await status_text()
        if obs.reachable and obs.status and display in ("READY", "WORK", "SERVER", "GAME"):
            if not target:
                await interaction.followup.send(_block(f"Already up.\n\n{text}"))
                return
            await interaction.followup.send(f"Already up. Switching to {target.upper()}…")
        else:
            suffix = f", then switch to {target.upper()}" if target else ""
            await interaction.followup.send(f"⚡ Sending Wake-on-LAN{suffix}. I will post here when the PC is ready.")
        bot.spawn(bot.monitor.wake(mode=target))

    @group.command(name="sleep", description="Stop services and hibernate (skipped while gaming / backing up)")
    async def sleep(interaction: discord.Interaction):
        await run_remote(interaction, "sleep", "💤 Sleep requested. The PC hibernates unless a game, backup or important job is running.")

    @group.command(name="ready", description="Switch to READY mode")
    async def ready(interaction: discord.Interaction):
        await run_remote(interaction, "ready")

    @group.command(name="game", description="Switch to GAME mode (stops WSL/Docker, no auto-hibernate)")
    async def game(interaction: discord.Interaction):
        await run_remote(interaction, "game")

    @group.command(name="work", description="Switch to WORK mode")
    async def work(interaction: discord.Interaction):
        await run_remote(interaction, "work")

    @group.command(name="server", description="Switch to SERVER mode")
    async def server(interaction: discord.Interaction):
        await run_remote(interaction, "server")

    @group.command(name="doctor", description="Run health checks")
    async def doctor(interaction: discord.Interaction):
        await run_remote(interaction, "doctor")

    @group.command(name="stay-awake", description="Skip tonight's automatic hibernate (until 06:00)")
    async def stay_awake(interaction: discord.Interaction):
        await run_remote(interaction, "stayawake")

    @group.command(name="allow-sleep", description="Re-enable automatic hibernate")
    async def allow_sleep(interaction: discord.Interaction):
        await run_remote(interaction, "allowsleep")

    @group.command(name="update", description="git pull the config repo and re-run the installer")
    async def update(interaction: discord.Interaction):
        await run_remote(interaction, "update", "🔄 Update started. Check `/win status` in a few minutes.")

    @group.command(name="reboot", description="Reboot the PC")
    @app_commands.describe(confirm="Set to True to really reboot")
    async def reboot(interaction: discord.Interaction, confirm: bool = False):
        if not confirm:
            await interaction.response.send_message("Add `confirm:True` to reboot.", ephemeral=True)
            return
        await run_remote(interaction, "reboot", "🔁 Reboot requested.")

    @group.command(name="shutdown", description="Shut the PC down (needs manual power on or WoL)")
    @app_commands.describe(confirm="Set to True to really shut down")
    async def shutdown(interaction: discord.Interaction, confirm: bool = False):
        if not confirm:
            await interaction.response.send_message("Add `confirm:True` to shut down.", ephemeral=True)
            return
        await run_remote(interaction, "shutdown", "⏻ Shutdown requested.")

    return group


def run(config: Config) -> None:
    token = os.environ.get("DISCORD_TOKEN")
    if not token:
        raise SystemExit("DISCORD_TOKEN is not set (see config/controller.env.example)")
    ControllerBot(config).run(token, log_handler=None)
