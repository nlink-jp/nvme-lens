# RFP: nvme-lens

> Generated: 2026-08-17
> Status: Draft

## 1. Problem Statement

macOS には NVMe SSD の温度と寿命を**継続的に**監視する手段が事実上ない。`diskutil` は
SMART Status を Verified / Not Supported の二値でしか出さず、`smartctl` は都度実行の
スナップショットで履歴を残さない。さらに NVMe が報告する Composite Temperature は
ホットスポットを 17〜21℃ 低く見せるため、ドライブ自身の警告閾値（WCTEMP 84℃）に
頼ると実温度 82℃ を見逃す。寿命側も Percentage Used / Available Spare /
Media and Data Integrity Errors は月単位でしか動かず、単発観測では劣化の開始点を
捉えられない。**nvme-lens は、内蔵および Thunderbolt/USB4 接続の NVMe を常駐監視し、
センサー個別の温度と寿命指標を継続記録し、閾値超過を通知する macOS メニューバー
アプリ**である。対象利用者は外付け NVMe を常用し、性能劣化とデータ安全性の双方を
気にする開発者。

温度は performance に直結し（サーマルスロットリング）、寿命指標はデータ安全性に
直結する。この 2 つは同じデータ源（NVMe SMART / Health Information Log 0x02）から
取れるにもかかわらず、macOS 標準の手段ではどちらも継続的に見られない。

## 2. Functional Specification

### Commands / API Surface

単一バイナリに GUI と CLI を同居させる（組織方針）。

| コマンド | 用途 |
|---|---|
| `nvme-lens`（引数なし） | メニューバー常駐 GUI を起動 |
| `nvme-lens list` | 検出ドライブ一覧。**監視不可のものも理由付きで列挙する** |
| `nvme-lens status [--device <serial>]` | 現在値のスナップショット |
| `nvme-lens history --device <serial> --since <期間> [--metric temp\|wear]` | 履歴の取り出し |
| `nvme-lens --version` | 版数を返す（Homebrew の `brew test` が叩くため必須） |

### Input / Output

- 入力なし（デバイスから直接読む）
- 出力は **JSON 既定**。`json-to-table` / `data-analyzer` にそのまま渡せる形にする
- `--format table` で人間向け整形

温度は Composite ではなく **Temperature Sensor 1..8 を個別に保持し、最大値を別フィールドで
提供する**。Composite も併記するが、判定には使わない。

### Configuration

- sectioned TOML、`~/.config/nvme-lens/config.toml`
- 項目: 閾値（温度・持続時間、寿命指標）、サンプリング間隔、保持期間、通知の有効/無効

既定値:

| 項目 | 既定 | 根拠 |
|---|---|---|
| 温度サンプリング間隔 | 60 秒 | 実測で負荷投入 20 秒後に +9℃ 動いた。ピークを取り逃さない粒度 |
| 寿命サンプリング間隔 | 1 時間 | 月単位でしか動かない指標のため |
| 温度履歴の保持 | 90 日（30 日超は 10 分平均に間引き） | |
| 寿命履歴の保持 | 無期限 | 総量が小さく、長期傾向がこの指標の価値そのもの |

> **変更 (2026-08-17)。** 上記の TOML 設定ファイルはリリース前に廃止した。
> そこに置く予定だった設定はいずれも「常駐アプリが何をするか」を決める値で、
> 閾値は「いつ通知するか」を決め、通知を出せるのはアプリだけである。共有ファイルに
> 置いた結果、設定ウィンドウが表示できても変更できない行になっていた。設定はアプリが
> 持ち、すべて編集可能。CLI は判定せず、記録と読み出しに徹する。

### Storage

SQLite。温度は分単位、寿命指標は日単位と粒度が混在し、「直近 1 週間のピーク」
「先月 10 日との差」といった問いが中核になるため、集計クエリと間引きを自前実装せずに
済ませる。

テーブル: `devices` / `samples`（温度）/ `wear_snapshots`（寿命）

### Device Identity

**Serial Number をキーにする。** BSD 名（`/dev/diskN`）も IOService パスも再接続で
変わる。加えて `smartctl --scan` 系の自動列挙は目的のデバイスを返す保証がない
（本 RFP の調査中に、接続中の対象 2 台を 1 台も列挙せず無関係な空筐体を返す事象を
実際に踏んだ）。列挙結果は必ず Serial Number で照合してから使う。

### Alerting

通知対象は 4 種:

1. **温度閾値超過** — Sensor 個別の最大値が閾値を**一定時間継続して**超えたとき。
   瞬間的なピークでは鳴らさない
2. **寿命指標の悪化** — Percentage Used の増加、Available Spare が
   Available Spare Threshold を下回る
3. **メディアエラーの発生** — Media and Data Integrity Errors の増分。
   増分そのものが事象なので閾値不要
4. **Power Cycles / Unsafe Shutdowns の異常増加** — 筐体や電源管理の問題を暴く

温度アラートは**固定閾値 + 持続時間条件**とする。ベースライン学習は採らない。
理由は §3 を参照。

### External Dependencies

なし。IOKit のみを使い、外部バイナリにも外部サービスにも依存しない。

**開発時に限り** `smartctl` をパーサ検証の参照実装（テストオラクル）として使うが、
**製品コードからは一切呼ばない**。利用者に smartmontools の導入を求めることはなく、
smartmontools が無い環境でも単体テストは全て通る（[ADR-0001](adr/0001-iokit-direct-smart-access.md) Decision 5）。

## 3. Design Decisions

### 言語 / フレームワーク: Swift / AppKit メニューバー

`sensor-lens-gui` / `active-lens-gui` / `claude-usage-lens-gui` と同構成。IOKit を
直接叩くため Swift が最短距離で、既存のメニューバー GUI の知見（NSPopover の
`makeKey()`、通知の trigger 設計、`MenuBarExtra` の制約など）がそのまま使える。
Go + Wails はクロスプラットフォーム性が利点だが、本ツールは macOS の IOKit に
完全依存するため利点がなく、CGO 経由で IOKit を叩く分だけ複雑になる。

### SMART 取得: IOKit `IONVMeSMARTInterface` 直叩き（ADR 対象）

`GetLogPage(0x02)`（SMART / Health Information）と `GetIdentifyData` を直接呼ぶ。
これは smartmontools の Darwin backend が使っている実証済みの経路である。

`smartctl` を呼んで出力をパースする案は採らない:

- 利用者に `smartmontools` の導入を要求することになり、「利用者が準備できるか」で
  採否が決まるという原則に抵触する
- smartmontools は GPL であり同梱が煩雑
- 出力書式は版ごとに変わりうるため、パーサが drift リスクを背負う

IOKit 直叩きなら外部依存ゼロで `.app` 単体で完結し、署名・notarize も単純になる。

→ [ADR-0001: SMART の取得は smartctl 経由ではなく IOKit を直接呼ぶ](adr/0001-iokit-direct-smart-access.md)

### 読み取り専用に徹する

self-test の実行、ファームウェア操作、その他ドライブの状態を変える操作は一切持たない。
監視ツールが対象を壊す経路を原理的に断つ。

### 温度アラートはベースライン学習を採らない

実測で、アイドル時点で既に Sensor 1 が 69℃ に達していた（Composite は 52℃）。
素朴な固定閾値は鳴りっぱなしになるため持続時間条件を組み合わせるが、ベースライン
学習型は採らない。「なぜ鳴ったか」が説明できなくなり、実装と検証の双方が重くなる。
閾値は利用者が実測を見て調整できる形にする。

### 補完する既存ツール

- `sensor-lens` — 常駐収集 + メニューバー表示の実装パターンの移植元
- `json-to-table` / `data-analyzer` — JSON 出力の受け手
- `claude-usage-lens-gui` — メニューバー UI パターン

### Out of Scope

- **USB 接続ドライブ** — 原理的に監視不可（§7 参照）
- SATA SSD / HDD
- Windows / Linux
- 空き容量・ディスク使用量の監視（別問題であり、既存手段が豊富）
- ドライブの状態を変えるあらゆる操作

## 4. Development Plan

### Phase 1: Core

- IOKit による NVMe 列挙と、Serial Number をキーとしたデバイス識別
- `GetLogPage(0x02)` のパース（Sensor 個別温度、寿命指標一式）
- 監視不可デバイスの検出と理由の分類（USB 接続 / 非対応バス など）
- CLI: `list` / `status` / `--version`
- テスト: 既知バイト列 → 期待値のパース単体テスト、および実機 E2E

**単体で価値が完結する。** 従来 `smartctl` で得ていた値を自前で取得できることの
証明になり、以降の Phase の前提を実機で検証したことになる。独立レビュー可能。

### Phase 2: Features

- SQLite ストアと常駐収集
- 4 種の閾値判定と通知
- CLI: `history`
- 間引きと保持期間の実装
- メニューバー GUI（ドライブ一覧、温度・寿命の表示、**監視不可デバイスの理由表示**）

GUI をここに置くのは、`-lens` 系においてメニューバー GUI が製品本体であり、
Phase 3 では遅すぎるため。ただし Phase 2 が厚いため、着手時に
「収集 + 通知」と「GUI」で分割する余地を残す。

### Phase 3: Release

- README.md / README.ja.md
- CHANGELOG.md
- 署名・notarize
- Homebrew tap への登録
- リリース前の実データ E2E と実機シミュレーション

## 5. Required API Scopes / Permissions

外部サービスへの依存はないため、API スコープ・OAuth・IAM ロールは **None**。

macOS 側の権限:

- **通知許可のみ**（`UNUserNotificationCenter`）

**root 権限は不要。** 調査中に `smartctl -a` を sudo なしで実行し、内蔵・
Thunderbolt 接続外付けの双方から全項目を取得できることを実機で確認済み。
特権ヘルパーツールも常駐 daemon も必要ない。

## 6. Series Placement

Series: **util-series**

Reason: `sensor-lens` / `active-lens` / `claude-usage-lens` と同じ「ローカルの状態を
収集して可視化する macOS 常駐ツール」の系列であり、命名（`-lens`）・構成・配布形態が
既存群と揃う。外部サービス連携がないため cli-series ではなく、セキュリティ用途でも
実験でもない。

## 7. External Platform Constraints

### USB 接続ドライブは原理的に監視不可

Darwin には USB Mass Storage への SCSI/ATA pass-through 経路が存在しない
（smartmontools の Darwin 実装でも SCSI デバイスは未サポートで、該当関数が 0 を返す）。
加えて NVMe-over-USB の SMART 取得には標準仕様自体がなく、ブリッジごとの
ベンダー独自コマンド頼みである。

対象は **内蔵 NVMe** と **Thunderbolt/USB4 で PCIe 接続された NVMe** に限られる。
外付け SSD の多くは USB 筐体であるため、これは採否を左右する制約である。
UI では監視不可デバイスも一覧に出し、理由と解決策（Thunderbolt 筐体なら取得可能）を
明示する。無言で消すと「壊れている」「認識されていない」と誤解される。

### Composite Temperature はホットスポットを低く見せる

実測値（WD_BLACK SN770 1TB、USB4/TB エンクロージャ収容）:

| 状態 | Composite | Sensor 1 | Sensor 2 |
|---|---|---|---|
| アイドル定常 | 52℃ | 69℃ | 52℃ |
| 連続読み出し 4 分後（ピーク） | 61℃ | **82℃** | 61℃ |

乖離は常時 17〜21℃。Composite だけを監視する実装は実際の熱状態を隠す。

### ドライブ自身の警告は当てにならない

WCTEMP（84℃）/ CCTEMP（88℃）は **Composite に対する閾値**である。上記の実測で
ホットスポットが 82℃ に達しても Composite は 61℃ にとどまり、
`Warning Comp. Temperature Time` は 0 分のまま増えなかった。**ドライブが「正常」と
報告しているのに実際は熱い**状態が正常に成立する。自前で閾値を持つ必然性はここにある。

### IOKit の提供範囲

`IONVMeSMARTInterface` が提供するのは `GetIdentifyData` と `GetLogPage` のみ。
self-test の実行や任意の Admin コマンド送出はできない。§3 の「読み取り専用に徹する」
方針とは矛盾しない。

### その他

- 通知許可プロンプトが未回答のままプロセスを kill すると、以後 denied で固定され
  システム設定からしか復旧できない。スモークテストの設計に影響する
- macOS 26 (Tahoe) で外付け NVMe が自動切断されるという報告が Apple 開発者
  フォーラムに 1 件ある（原因未特定、再現条件不明）。要監視だが現時点で本ツールの
  設計を変える根拠はない

---

## Discussion Log

**発端** — USB 接続の外付け SSD から SMART 情報を読む方法を調査した過程で、macOS では
原理的に取得できないことが判明。Thunderbolt/USB4 の PCIe 直結エンクロージャに交換して
解決し、その過程で得た実測値が本 RFP の前提のほぼ全てを供給している。

**ツール名** — `nvme-lens` を採用。`disk-lens` / `ssd-lens` も検討したが、USB・SATA が
原理的に対象外である以上、名前で対象を限定するほうが過大な期待を与えないと判断した。
命名そのものが制約の説明を兼ねる。

**監視モデル** — 「常駐 + 履歴蓄積 + 閾値通知」を採用。温度のピークはサンプリング
しなければ捉えられず（実測でも負荷走行中にしか 82℃ は観測されなかった）、
Percentage Used は月単位でしか動かないため、スナップショット取得のみでは
温度・寿命どちらの目的も果たせないと判断した。

**監視不可デバイスの扱い** — 一覧に出して理由を明示する方式を採用。無言で隠す案は、
利用者が自分のドライブが対象外である事実にも解決策があることにも気づけないため却下。
「意図的に何もしない状態は UI で名乗らせる」という既存方針にも沿う。

**履歴ストア** — SQLite を採用。CSV（`sensor-lens` の冪等 import パターン）と JSONL も
検討したが、温度（分単位）と寿命（日単位）で粒度が混在し、期間集計が中核の問いに
なるため、集計と間引きを自前実装しなくて済む点を重視した。

**温度アラート方式** — 固定閾値 + 持続時間条件を採用。アイドルで既に 69℃ という
実測があるため単純な固定閾値では鳴りっぱなしになるが、ベースライン学習型は
「なぜ鳴ったか」の説明可能性を失い実装・検証とも重くなるため見送った。

**SMART 取得方式** — IOKit 直叩きを採用。`smartctl` 呼び出し案は実装が最短である一方、
利用者に `smartmontools` の導入を要求する点が「採否は利用者が準備できるかで決まる」
原則に抵触するため却下。併用案は二重の実装と検証を招き Phase 1 が膨らむため見送った。
**この判断は ADR を切る対象とする。**

**言語** — Swift / AppKit。Go + Wails はクロスプラットフォーム性が利点だが、
IOKit 完全依存の本ツールでは利点が立たず、CGO 経由の分だけ複雑になる。

**デバイス識別子** — Serial Number をキーとする。調査中に、自動列挙が接続中の対象
2 台を 1 台も列挙せず無関係な空筐体を返す事象を実際に踏んだことが根拠。列挙結果は
独立した識別子で照合してから使う。

**Phase 分割の未決事項** — GUI を Phase 2 に置いたが Phase 2 が厚い。着手時に
「収集 + 通知」と「GUI」へ分割する余地を残してある。
