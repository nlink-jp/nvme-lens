# nvme-lens

NVMe SSD の**温度**と**寿命**を常時監視し、履歴を記録して、閾値超過を通知する
macOS メニューバーアプリ。

温度は性能を左右し（サーマルスロットリング）、寿命指標はデータ安全性に直結します。
どちらも同じ NVMe SMART / Health Information ログから取れますが、macOS 標準の手段では
どちらも継続的に見られません。`diskutil` は Verified / Not Supported の二値だけ、
`smartctl` は履歴の残らないスナップショットです。

> **状態: v0.1.0。** 上記はすべて動作します。設計は
> [RFP](docs/ja/nvme-lens-rfp.ja.md)、検証内容は
> [CHANGELOG](CHANGELOG.md) を参照してください。

## インストール前に: 監視できるドライブ

| 接続形態 | 監視 | 理由 |
|---|---|---|
| 内蔵 NVMe | ✅ | |
| Thunderbolt / USB4 (PCIe) 接続の NVMe | ✅ | ネイティブ NVMe として認識される |
| **USB 筐体の NVMe / SATA** | ❌ | **macOS では原理的に不可**（下記） |
| SATA SSD / HDD | ❌ | 対象外 |

**USB 接続のドライブは監視できません。これはソフトウェアで解決できる問題ではありません。**
Darwin には USB Mass Storage への SCSI/ATA pass-through 経路が存在せず、SMART コマンドが
ドライブに届きません。本ツールの機能不足ではなく OS の制約です。PCIe をトンネリングする
Thunderbolt/USB4 筐体に入れ替えれば、そのまま読めるようになります。

nvme-lens は監視できないドライブも**理由付きで一覧に出します**。黙って隠すことはしません。

## `Temperature:` を読むだけでは足りない理由

NVMe が報告する Composite Temperature はホットスポットを低く見せます。
USB4 筐体に収めた WD_BLACK SN770 での実測値:

| 状態 | Composite | Sensor 1 |
|---|---|---|
| アイドル | 52℃ | 69℃ |
| 連続読み出し 4 分後 | 61℃ | **82℃** |

ドライブ自身の警告閾値（WCTEMP 84℃）は Composite に対するものなので、ホットスポットが
上限の 2℃ 手前にあっても `Warning Comp. Temperature Time` は 0 分のままでした。
**ドライブが「正常」と報告しながら実際は熱い**状態が成立します。nvme-lens は
Temperature Sensor 1..8 を個別に読み、最大値で判定します。

## 使い方

```
nvme-lens                                   メニューバーアプリを起動
nvme-lens list [--format json|table]        ドライブ一覧（監視不可のものも表示）
nvme-lens status [--device <serial>]        現在値のスナップショット
nvme-lens sample [--format json|table]      1 回計測して記録し、アラートを報告
nvme-lens history --device <serial> --since <期間> [--metric temp|wear]
                                            期間: 30m, 12h, 7d, 4w
nvme-lens --version                         版数を表示
nvme-lens --help                            このメッセージを表示
```

出力は JSON 既定で、`json-to-table` や `data-analyzer` にそのまま渡せる形です。

ドライブの指定は `/dev/diskN` ではなく**シリアル番号**で行います。BSD 名も IOService
パスも再接続で変わるためです。

## 通知する対象

1. **温度** — センサー個別の最大値が閾値を**一定時間継続して**超えたとき（瞬間的な
   ピークでは鳴りません）
2. **寿命** — Percentage Used の増加、Available Spare が Available Spare Threshold を
   下回る
3. **メディアエラー** — Media and Data Integrity Errors の増分
4. **Power Cycles / Unsafe Shutdowns** — 異常な増加。筐体や電源管理の問題を暴きます

## 設定

`~/.config/nvme-lens/config.toml`（sectioned TOML）。閾値、サンプリング間隔、保持期間、
通知の有効/無効。

## 動作要件

- macOS 14 以降、Apple Silicon
- **root 不要。** 特権ヘルパーも daemon も使いません
- **外部依存なし。** SMART は IOKit を直接呼んで取得します
  （[ADR-0001](docs/ja/adr/0001-iokit-direct-smart-access.md)）

## ビルド

```sh
make build      # swift build -c release
make test       # 単体テスト。デバイスも smartmontools も不要
make build-app  # dist/NvmeLens.app を組み立てて署名
make package    # notarize してリリース用 zip を作成
```

> macOS 向けリリースは **Developer ID 署名 + Apple notarize 済み**（stapled）です。
> Gatekeeper の警告なしに起動でき、オフラインでも動作します。

## ドキュメント

- [RFP](docs/ja/nvme-lens-rfp.ja.md) — 問題定義、仕様、開発計画
- [ADR-0001](docs/ja/adr/0001-iokit-direct-smart-access.md) — SMART の取得に
  `smartctl` を使わず IOKit を直接呼ぶ理由

## ライセンス

MIT
