# Wake-on-LAN 実機検証（product.txt §9.1）

Night Mode で使う電源状態を決めるための手順。Alienware と Raspberry Pi を有線 LAN で同じネットワークにつなぎ、AC 電源を接続しておく。

## 構成

Pi の eth0 ⇔ Alienware の内蔵 Ethernet を直結（WoL 専用）。Pi は `install.sh --wol-link 10.99.0.1/24`、
`controller.json` の `windows.broadcast` は `10.99.0.255`。手動送信は `python3 -m wake <MAC> 10.99.0.255`。

## 準備

1. [bios.md](bios.md) の BIOS 設定
2. Windows でインストーラ実行済み（`91-wake-on-lan` が NIC と Fast Startup を設定する）
3. MAC アドレスを確認: `Get-NetAdapter -Physical | ft Name, InterfaceDescription, MacAddress`
4. Pi に `controller/` を置く（`install.sh` 前でも可）

## 手順（電源状態ごとに繰り返す）

| # | 操作 | 確認 |
| --- | --- | --- |
| 1 | Windows: `shutdown /h`（Hibernate） | 電源 LED が消える／ファンが止まる |
| 2 | 1 分待つ | |
| 3 | Pi: `cd controller && python3 -m wake <MAC> [ブロードキャストアドレス]` | |
| 4 | | Alienware が起動するか |
| 5 | | Windows 起動後、Pi から `ping` / `nc -z <IP> 22` が通るか |
| 6 | Windows: `tailscale status` | Tailscale が復帰しているか |
| 7 | Windows: `winctl history` | `wake resume` が記録され、`winctl status` が READY か |

電源状態:

- **Hibernate**: `shutdown /h`
- **Sleep**: スタートメニュー → スリープ（Modern Standby 機の場合は S0ix になる）
- **Shutdown**: `shutdown /s /t 0`

## 結果の記録と反映

| 電源状態 | WoL で起動 | ネットワーク復帰 | Tailscale 復帰 |
| --- | --- | --- | --- |
| Hibernate | | | |
| Sleep | | | |
| Shutdown | | | |

結果に応じて `config/system.json` を設定する（product.txt §25 の優先順位）:

```json
"power": { "night_mode": "hibernate" }
```

1. Hibernate で起動できる → `hibernate`
2. Sleep でのみ起動できる → `sleep`
3. どちらも駄目 → `shutdown`（翌日は手動で電源オン）、または `none`（Night Mode を無効にする）

変更後は `winctl sync` で反映する（再インストールは不要）。

## うまくいかない場合

- 起動しない: BIOS の Deep Sleep Control、AC 接続、Pi と同じ L2 セグメントか、ブロードキャストアドレス（例 `192.168.1.255`）を指定して再送
- 起動するがネットワークが戻らない: デバイスマネージャー → NIC → 電源の管理「電力の節約のために…オフにできる」を外す
- Tailscale が戻らない: `Get-Service Tailscale` が Automatic か。`winctl recover` 後に `winctl doctor`
