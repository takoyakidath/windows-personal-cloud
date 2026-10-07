# BIOS (Alienware m17 R3)

起動時に `F2` で BIOS Setup。項目名は BIOS バージョンによって異なる。**必要なものだけ**有効にする（product.txt §10）。

| 項目 | 設定 | 理由 |
| --- | --- | --- |
| Wake on LAN / WLAN | **LAN Only** | 内蔵 RJ45 からの magic packet だけで起動する（WLAN からは起動しない） |
| Deep Sleep Control | **Disabled** | 有効だと S4/S5 で NIC の電源が切れ、WoL が届かない |
| USB Wake Support | Disabled | USB Ethernet は使わない。不要な Wake を増やさない |
| AC Wake / Auto Power On | Disabled（まず） | 定時起動は不要。WoL が使えない場合の代替として検討する |
| Block Sleep | Disabled | Sleep (S3 / Modern Standby) へのフォールバックに必要 |

- AC アダプタを接続したまま運用する（バッテリー駆動時は WoL が無効になる機種が多い）。
- Windows 側の設定は `installer/steps/91-wake-on-lan.ps1` が行う（`power.lan_only_wake: true`、既定）:
  - 内蔵 Ethernet: magic packet で起動 ON、パターン起動 OFF（普通の通信で起きないように）
  - それ以外のデバイス（マウス、キーボード、Wi-Fi など）の起動を無効化
  - スリープ解除タイマー、自動メンテナンスによる起動を無効化
  - Fast Startup 無効
- 確認: `winctl doctor` の `Wake` 行が `LAN only`、または `powercfg /devicequery wake_armed` が Ethernet だけ。
- 設定後に [wol-verification.md](wol-verification.md) を実施する。
