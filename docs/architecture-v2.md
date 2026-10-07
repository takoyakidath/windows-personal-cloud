# Architecture v2

要件は [product.txt](../product.txt)。ここでは実装上の判断と、その理由を記録する。

## 全体

```
Discord ──► Raspberry Pi (controller/) ──WoL──► Alienware
                 │                                  │
                 └── SSH (forced command) ──► winctl remote ──► winctl (status / mode / sleep …)
                                                    │
Mac ── Tailscale ── SSH / RDP / SMB / Parsec ───────┘
```

## 判断と理由

### Windows 側は PowerShell 5.1 互換
クリーンインストール直後の Windows には Windows PowerShell 5.1 しかない。bootstrap / installer / winctl を
すべて 5.1 で動くように書き（三項演算子・`??`・`-AsHashtable` を使わない）、CI で 5.1 上の Pester を回す。

### winctl はリポジトリの checkout から直接動く
`C:\ProgramData\winctl\repo` に clone し、`C:\ProgramData\winctl\bin\winctl.cmd` が `repo\winctl\winctl.ps1` を呼ぶ。
`winctl sync` / `update` で git pull するだけで CLI も設定も更新される。

### Pi → Windows は SSH の forced command
新しい待受ポート（HTTP API など）を作らない。Pi の公開鍵は `administrators_authorized_keys` に
`command="…\winctl.cmd remote",no-pty,no-port-forwarding,…` 付きで入る。クライアントが何を送っても
`SSH_ORIGINAL_COMMAND` として `winctl remote` に渡り、`Resolve-WinctlRemoteCommand` の allowlist
（英小文字 1 単語のみ・引数なし）に一致したものだけ実行される。Pi 側（`health/windows.py`）にも同じ
allowlist があり、Discord コマンドはどれも自由入力を受け取らない。二重の allowlist（product.txt §6.2, §42）。

### Hibernate / Reboot は Scheduled Task 経由
`sleep` `update` `reboot` `shutdown` は SSH セッションが切れても続く必要があるので、`winctl remote` は
on-demand タスク（`\winctl\WinCtl-Sleep` など）を起動して即座に応答する。

### Docker は WSL 内の Docker Engine
Docker Desktop ではなく Ubuntu 内の `docker-ce`（systemd 管理）。`wsl --shutdown` で確実に止まり、
Night Mode の「WSL2 停止 / Docker 停止」が単純になる。Docker API は unix socket のみ。

WSL はアイドル状態の distro を止めるため、`\winctl\WinCtl-WslKeepAlive`（`sleep infinity`）で起動状態を保つ。
タスクとして動かすのは、SSH セッションから起動しても終了時に巻き込まれないようにするため。

### WSL は per-user なので、タスクはログオンユーザーで動く
`WinCtl-Night` などは `Interactive` + `Highest` で登録する。ログオフ中は 21:00 チェックが走らないが、
その状態では WSL / Docker も動いていない。

### モードと状態
- 保存されるのは **mode**（READY / GAME / WORK / SERVER / SLEEP）。
- 表示される **state** はヘルスチェックから毎回計算する（`Resolve-WinctlState`）。
  critical（Network、システムドライブ残量 5% 未満）が落ちていれば ERROR、
  そのモードで必要なサービス（`services.json` の `start`）や Workspace が落ちていれば DEGRADED。
  DEGRADED / ERROR は保存しないので、直れば自動的に元に戻る。

### HIBERNATED と OFFLINE の区別
Windows は Hibernate 中に応答できない。そこで `winctl sleep` は mode を SLEEP にしたあと、
SSH を止めずに `power.sleep_grace_seconds`（既定 45 秒）待ってから Hibernate する。Pi は 30 秒ごとに
status を取得しているので最後の mode=SLEEP を記録でき、応答がなくなったら HIBERNATED、
それ以外で応答がなければ OFFLINE と表示する。

### Night Mode の安全チェック
`Get-WinctlSleepBlockers` が以下を確認し、1 つでもあれば Hibernate しない（理由はログと history に残る）。
- GAME モード（夜間のみ）／ `games.json` のプロセス
- `winctl inhibit on`
- lock（`winctl backup` / `restore` 実行中）
- `power.inhibit_processes`（robocopy、Windows Update の TiWorker など）
- `wpc.inhibit-sleep=true` ラベル付きの Docker コンテナ

`backup.before_night_sleep: true` にすると、Hibernate の前に `winctl backup` を実行する（ドライブ未接続や失敗時はスキップして Hibernate する）。
`winctl doctor` / `status` は最終 Backup からの日数を表示し、`backup.max_age_days`（既定 7）を超えると警告する。

21:00 のタスクは `StartWhenAvailable = false`。電源オフで逃した 21:00 チェックを翌朝の起動直後に実行して、
起きた直後に Hibernate してしまうのを防ぐ。

### 起動 / 復帰時のリカバリ
- ログオン時: `WinCtl-RecoverLogon`
- Sleep / Hibernate からの復帰時: `WinCtl-RecoverResume`（System ログの Power-Troubleshooter Event ID 1）

タスクは `conhost.exe --headless` 経由で起動し、ゲーム中などにコンソール画面が出ないようにする（WSL keep-alive も同様）。

どちらも `winctl recover` を実行する。ネットワーク待ち → mode が SLEEP なら READY に戻す → モードのサービスを起動 →
ヘルスチェック → 通知（webhook を設定している場合）。

### 電源設定
`powercfg` で AC 接続時のアイドル Sleep / Hibernate を無効にする。リモート利用中に OS の判断で寝ないようにし、
寝るタイミングは winctl（21:00 / `/win sleep`）だけが決める。Fast Startup は WoL を妨げるので無効化する。

### Firewall
SSH / RDP / SMB の受信ルールは、ローカライズされない内部名（`OpenSSH-Server-In-TCP`、`FPS-SMB-In-TCP`、
`RemoteDesktop-UserMode-In-*`）で指定し、RemoteAddress を `100.64.0.0/10`（Tailscale）、
`fd7a:115c:a1e0::/48`、`LocalSubnet` に限定する。日本語版 Windows でも同じスクリプトで動く。
ACL も SID（`*S-1-5-32-544` など）で指定する。

### Backup
robocopy で Workspace → `backup.target\Workspace`。既定では **宛先の削除もしない**（`mirror: false`）。
restore は削除せず、Workspace 側の新しいファイルを上書きしない（`/XO`）うえ、`--yes` が必要。
実行中は lock を作り、Night Mode が Hibernate しないようにする。

### Raspberry Pi
- Python 3.11 + discord.py。WoL・SSH・状態判定は標準ライブラリだけで実装する。
- systemd `Type=notify` + `WatchdogSec=120` + `Restart=always`。必要なら `install.sh --hardware-watchdog` で Pi 自体の HW watchdog も使う。
- Wake フロー: 既に READY なら何もしない → magic packet（3 回）→ 30 / 60 / 120 / 120 / 120 / 150 秒ごとに確認
  （応答がなければ再送）→ READY/WORK/SERVER/GAME で 🟢 通知、時間切れなら 🔴 通知（product.txt §40）。
- 通知は Pi が出す（Hibernate への遷移、ERROR への遷移、Wake の結果）。Windows 側にも
  `secrets.json` の `discord_webhook_url` を置けば、Windows からも通知が出る（任意）。

## 実機でしか確認できないこと

| 項目 | 確認方法 |
| --- | --- |
| Hibernate からの WoL | [wol-verification.md](wol-verification.md) |
| `wsl --install --no-launch` 後の distro 登録 | インストーラの Manual actions に出たら手動で 1 回 `wsl --install` |
| WinCtl-WslKeepAlive で Docker が動き続けるか | `winctl work` → 数分後に `winctl status` |
| 復帰イベント（Power-Troubleshooter 1）でのリカバリ | Hibernate → 復帰 → `winctl history` に `wake resume` |
| SSH forced command（Windows OpenSSH） | Pi から `ssh -i … user@pc status` |
| `conhost.exe --headless` でタスクのウィンドウが出ないこと | 21:00 / ログオン時に画面を確認 |
| CPU 温度 | WMI で取れない機種では null（GPU 温度は nvidia-smi） |
