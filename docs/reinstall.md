# Windows 再インストール手順

上から順にやれば終わるチェックリスト。Raspberry Pi 側はそのまま動き続ける（触るのは最後の 2 か所だけ）。

## ディスク構成

SSD 1 台（Micron 2300 1TB）を 2 つに分けている。C: = Windows / アプリ / WSL（約 300GB）、
D: = `Workspace`（残り）。OS の入れ直しでは C: だけを消すので、Workspace は残る。
ゲームは `D:\Workspace\Games` に入れる（Steam: 設定 → ストレージ → ライブラリフォルダを追加）。入れ直し後も
同じフォルダを追加すれば再ダウンロード不要。`Games` はバックアップ対象外（再ダウンロードできるため）。

初回の分割（管理者 PowerShell。C: に余裕があるうちに）:

```powershell
Get-PartitionSupportedSize -DriveLetter C     # SizeMin が 300GB 未満なら OK
Resize-Partition -DriveLetter C -Size 300GB
New-Partition -DiskNumber 0 -UseMaximumSize -DriveLetter D | Format-Volume -FileSystem NTFS -NewFileSystemLabel Workspace
```

## 0. 消す前に

- [ ] **バックアップが終わっている**（C: は全部消える。WSL の中身・デスクトップ・ブラウザのデータも）
- [ ] 必要なら `C:\ProgramData\winctl\secrets.json`（Discord webhook）を控える
- [ ] D:（`Workspace`）にない大事なデータは D: に移しておく（C: は全部消える）

## 1. Windows のインストール

- [ ] インストール先の選択では **Windows のパーティション（C:）だけ**を削除・選択する。
  **`Workspace` ラベルの D: パーティションは消さない**（消さなければ中身はそのまま残る）
- [ ] **ネットワーク（LAN ケーブルも Wi-Fi も）につながずに**セットアップする
  → 「オフライン アカウント」/「制限付きエクスペリエンス」を選び、ユーザー名 **`takoyaki`** で作る
  （Microsoft アカウントで作るとユーザー名がメールの先頭 5 文字 `takoy` になる）
- [ ] セットアップ後に Wi-Fi「penguin」につなぐ
- [ ] Microsoft アカウントを使うなら、ここで「設定 → アカウント → Microsoft アカウントでのサインインに切り替える」
  （ユーザー名とフォルダは `takoyaki` のまま）
- [ ] Windows Update を一通り当てる（winget / App Installer もここで新しくなる）

## 2. セットアップ（winget も Git も事前に不要）

- [ ] ブラウザで https://github.com/takoyakidath/windows-personal-cloud → **Code → Download ZIP** → 展開
- [ ] スタート右クリック →「Windows PowerShell (管理者)」で:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& "$HOME\Downloads\windows-personal-cloud-main\bootstrap.ps1"
```

- PC 名が `alienware` に変わり再起動する → **ログインすると自動で続きから再開**
- `irm ... | iex` 形式は使わない（Defender が Trojan:Win32/Commando として止める）
- 最後に出る **Manual actions** だけ手でやる:
  - [ ] `tailscale up --hostname alienware --unattended`
  - [ ] Parsec にログイン
  - [ ] WSL のパスワード: `wsl -d Ubuntu-24.04 -u root passwd takoyaki`
  - [ ] （任意）`secrets.json`、`winctl backup on`

## 3. Raspberry Pi 側（Windows から `ssh takoyaki@wpc-controller.local`）

- [ ] Windows の SSH ホスト鍵が変わったので、古い鍵を消す:

```bash
sudo -u windows-controller ssh-keygen -R 192.168.11.30 -f /var/lib/windows-controller/known_hosts
```

- [ ] ユーザー名や IP が変わったら `controller.json` を直す（再インストール後のユーザー名は `takoyaki` の想定）:

```bash
sudo sed -i 's/"ssh_user": "takoy"/"ssh_user": "takoyaki"/' /etc/windows-controller/controller.json
grep -E '"host"|ssh_user|mac_address|broadcast' /etc/windows-controller/controller.json
sudo systemctl restart windows-controller
```

  - `host` = Windows の Wi-Fi の IP（`ipconfig` で確認。ルーターで DHCP 予約しておくと変わらない）
  - `mac_address` = `cc:48:3a:5c:90:cd`（内蔵 Ethernet。再インストールでは変わらない）
  - `broadcast` = `10.99.0.255`（Pi と PC の直結ケーブル）

## 4. 確認

- [ ] Windows: `winctl doctor`
- [ ] Discord: `/win status` が READY（または DEGRADED と理由）
- [ ] Mac: Windows App で `192.168.11.30`、ユーザー名 `takoyaki`（Microsoft アカウントに切り替えた場合は `MicrosoftAccount\メールアドレス`）
- [ ] Tailscale 管理画面で古い `alienware` / `desktop-…` 端末を削除
- [ ] BIOS → WoL 検証: [bios.md](bios.md) → [wol-verification.md](wol-verification.md)
