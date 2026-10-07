# BIOS (Alienware m17 R3)

起動時に `F2` で BIOS Setup。項目名は BIOS バージョンによって異なる。**必要なものだけ**有効にする（product.txt §10）。

| 項目 | 設定 | 理由 |
| --- | --- | --- |
| Wake on LAN / WLAN | **LAN Only** | 内蔵 RJ45 からの magic packet で起動する |
| Deep Sleep Control | **Disabled** | 有効だと S4/S5 で NIC の電源が切れ、WoL が届かない |
| USB Wake Support | Disabled | USB Ethernet は使わない。不要な Wake を増やさない |
| AC Wake / Auto Power On | Disabled（まず） | 定時起動は不要。WoL が使えない場合の代替として検討する |
| Block Sleep | Disabled | Sleep (S3 / Modern Standby) へのフォールバックに必要 |

- AC アダプタを接続したまま運用する（バッテリー駆動時は WoL が無効になる機種が多い）。
- Windows 側の設定（magic packet で起動、Fast Startup 無効）は `installer/steps/91-wake-on-lan.ps1` が行う。
- 設定後に [wol-verification.md](wol-verification.md) を実施する。
