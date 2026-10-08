# Windows Personal Cloud

> **個人用の環境定義です**（takoyaki の Alienware m17 R3 + Raspberry Pi 用）。
> 自分の環境で使う場合は fork して、`config/system.json`（PC 名・MAC・WSL ユーザー・リポジトリ URL など）、
> `config/games.json`、`config/ssh/` を書き換える。コード側に個人の値は入れていない。

Alienware m17 R3 (Windows) を Workstation / Gaming PC / 開発サーバー / Personal Cloud として使うための
**Environment as Code** リポジトリ。Windows を入れ直しても、このリポジトリから環境を再構築できる。

要件は [product.txt](product.txt)、設計は [docs/architecture-v2.md](docs/architecture-v2.md)。

```
GitHub (このリポジトリ)  = PCの設計図
Windows                  = 実際のコンピューティング (winctl)
Raspberry Pi             = Always-on Controller (Discord Bot / Wake-on-LAN / Health Check)
Discord                  = Remote Control Interface (/win status, /win wake, ...)
```

## セットアップ

### 1. Windows

クリーンな Windows で（winget も Git も事前に不要）:

1. ブラウザで https://github.com/takoyakidath/windows-personal-cloud → **Code → Download ZIP** → 展開
2. スタートを右クリック →「Windows PowerShell (管理者)」で:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& "$HOME\Downloads\windows-personal-cloud-main\bootstrap.ps1"
```

`bootstrap.ps1` が winget を修復（ソースのリセット）→ Git をインストール（winget が駄目なら署名を検証した Git for Windows の公式インストーラ）
→ `C:\ProgramData\winctl\repo` に clone → そこから `installer\install.ps1` を実行する。展開した ZIP はその後消してよい。

> `irm <URL> | iex` 形式（ダウンロードしてそのまま実行）は Microsoft Defender に
> `Trojan:Win32/Commando` として検出される。マルウェアと同じ手口なので使わない。
再起動が必要な場合は自動で再起動し、ログオン後に続きから再開する。何度実行しても安全。

最後に表示される **Manual actions** だけ手で行う（Tailscale ログイン、Parsec ログイン、WSL パスワード、BIOS など）。

再インストール時のチェックリスト: [docs/reinstall.md](docs/reinstall.md)

### 2. Raspberry Pi

```bash
sudo git clone https://github.com/takoyakidath/windows-personal-cloud.git /opt/windows-personal-cloud
sudo /opt/windows-personal-cloud/controller/install.sh
```

詳細は [controller/README.md](controller/README.md)。

### 3. 実機検証

Wake-on-LAN が Hibernate から動くかは実機でしか分からない。
[docs/bios.md](docs/bios.md) → [docs/wol-verification.md](docs/wol-verification.md) の順に確認し、
結果に応じて `config/system.json` の `power.night_mode` を決める（`hibernate` / `sleep` / `shutdown` / `none`）。

## winctl

```
winctl status [--json]     CPU / RAM / GPU / VRAM / サービス / ヘルス
winctl doctor              ヘルスチェック詳細 (exit 1 = DEGRADED, 2 = ERROR)
winctl ready|game|work|server   モード切替 (config/services.json の profile を適用)
winctl sleep [--force]     サービス停止 → WSL 停止 → Hibernate (ゲーム中・Backup 中などは中止)
winctl wake                サービス復旧して READY へ (起動・復帰時は自動実行)
winctl inhibit on|tonight|off   21:00 の自動 Hibernate を禁止 (tonight = 翌朝 6:00 まで) / 許可
winctl services [start|stop NAME]
winctl disk
winctl backup [verify]     Workspace → 外付け SSD / NAS (robocopy、既定では削除しない)
winctl backup on|off       Backup の有効 / 無効 (既定は無効。この PC の system.local.json に保存)
winctl restore [--yes]     Backup → Workspace (削除しない・新しいファイルは上書きしない)
winctl sync                git pull
winctl update [--packages] git pull + インストーラ再実行 (+ winget upgrade)
winctl reboot | shutdown
winctl logs | history
```

ログ: `C:\ProgramData\winctl\logs\`、状態: `C:\ProgramData\winctl\state.json`

## Discord

| Command | 動作 |
| --- | --- |
| `/win status` | 状態表示（READY / DEGRADED / ERROR / HIBERNATED / OFFLINE …） |
| `/win wake [mode:GAME]` | Wake-on-LAN → 30s / 60s / 120s … で確認 → READY で通知（mode 指定時はそのモードへ切替） |
| `/win sleep` | `winctl sleep`（安全チェックあり） |
| `/win ready` `/win game` `/win work` `/win server` | モード切替 |
| `/win stay-awake` / `/win allow-sleep` | 今夜の自動 Hibernate を中止（翌朝 6:00 まで）/ 再開 |
| `/win doctor` | ヘルスチェック |
| `/win update` | `winctl update` |
| `/win reboot confirm:True` / `/win shutdown confirm:True` | 再起動 / シャットダウン |

Pi は状態の変化も通知する: Hibernate 移行、ヘルスチェック失敗、**予期しないオフライン**（READY から突然応答なし）、手動起動での復帰。

任意のコマンドは実行できない。Pi の SSH 鍵は Windows 側で `winctl remote` に強制され、allowlist 外は拒否される。

## 自動更新

GitHub に push すれば、両方のマシンが自動で追従する（fast-forward のみ。ローカル変更があれば何もしない）。

| マシン | タイミング | 動作 |
| --- | --- | --- |
| Windows | 毎日 12:00（電源オフで逃したら次の起動時） | `winctl sync --auto`。winctl と config は即反映。`installer/` などが変わったときは自動では再実行せず Discord に通知 → `/win update` |
| Raspberry Pi | 毎日 04:00 頃 | `controller/update.sh`。`controller/` が変わったら `install.sh` を再実行してサービスを再起動。ログ: `/var/log/windows-controller/update.log` |

## 設定

| ファイル | 内容 |
| --- | --- |
| `config/system.json` | ホスト名、Workspace、WSL、電源 (night mode)、Backup 先、winget パッケージ |
| `config/services.json` | サービス定義とモードごとの start / stop |
| `config/games.json` | ゲームのプロセス名（ここにあるものだけをゲームとして扱う） |
| `config/ssh/` | SSH **公開**鍵（自分用 / Pi 用） |
| `config/*.local.json` | Git 管理外の上書き（任意） |

Secret（Discord token、Tailscale auth key、Webhook URL など）はリポジトリに置かない。
Windows は `C:\ProgramData\winctl\secrets.json`、Pi は `/etc/windows-controller/controller.env` に置く。

## Tests

```bash
scripts/test.sh            # pytest (controller) + Pester (winctl, pwsh があれば)
```

CI（`.github/workflows/ci.yml`）は Ubuntu で pytest を、Windows PowerShell 5.1 で Pester と構文チェックを実行する。

## Layout

```
bootstrap.ps1        Win+R から実行する入口
installer/           install.ps1 + steps/NN-*.ps1 (冪等・再開可能)
winctl/              Windows 管理 CLI (PowerShell 5.1 互換)
controller/          Raspberry Pi: Discord Bot / WoL / Health Check (Python)
config/              環境定義
docker/              WSL 内 Docker の使い方
docs/                設計・BIOS・WoL 検証
scripts/             開発用スクリプト
```
