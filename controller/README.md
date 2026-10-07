# Raspberry Pi controller

Windows PC が寝ていても動く「リモコン」（product.txt §5）。Discord Bot・Wake-on-LAN・Health Check・Boot Monitor。
重い処理はしない。

```
bot/      Discord slash commands (/win ...) と認可
wake/     magic packet（python -m wake <MAC> で手動送信）
health/   SSH 経由の status 取得、状態判定、Wake フロー、定期ポーリング
core/     設定、状態ファイル、ログ、systemd notify
config/   設定の例（実ファイルは /etc/windows-controller/）
```

## Install

Raspberry Pi OS (Bookworm, Python 3.11)。Pi は Windows と同じ有線 LAN に置く（WoL はブロードキャスト）。

```bash
sudo git clone https://github.com/takoyakidath/windows-personal-cloud.git /opt/windows-personal-cloud
sudo /opt/windows-personal-cloud/controller/install.sh            # --hardware-watchdog で Pi の HW watchdog も有効化
```

`/home` 以下はサービスユーザーが読めないため、`/opt` に clone する。

その後:

1. **Discord Bot を作る**: Developer Portal → New Application → Bot → Token をコピー。
   OAuth2 URL Generator で scope `bot` + `applications.commands`、権限 `Send Messages` を選び、サーバーに招待する。
2. `/etc/windows-controller/controller.env` に `DISCORD_TOKEN=...` を書く（権限 640、Git には入れない）。
3. `/etc/windows-controller/controller.json` を編集する:
   - `windows.host`: Windows の LAN IP（推奨。Tailscale 名でも可）
   - `windows.ssh_user`: Windows のユーザー名、`windows.mac_address`: 内蔵 Ethernet の MAC
   - `windows.broadcast`: 例 `192.168.1.255`
   - `discord.guild_id`、`discord.notify_channel_id`
   - `discord.allowed_user_ids` / `allowed_role_ids`: **ここにある ID だけ**が操作できる。両方空だと起動しない
4. install.sh が表示した公開鍵（`/etc/windows-controller/id_ed25519.pub`）をリポジトリの
   `config/ssh/controller.pub` に追加して push し、Windows で `winctl update` を実行する。
5. `sudo systemctl restart windows-controller`、ログは `journalctl -u windows-controller -f` と
   `/var/log/windows-controller/controller.log`。

接続確認（Pi から。`status` 以外は allowlist で拒否されることも確認できる）:

```bash
sudo -u windows-controller ssh -i /etc/windows-controller/id_ed25519 <user>@<host> status
sudo -u windows-controller ssh -i /etc/windows-controller/id_ed25519 <user>@<host> whoami   # -> "command not allowed"
```

## Development

```bash
cd controller
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
```
