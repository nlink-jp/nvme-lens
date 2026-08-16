# ADR-0001: SMART の取得は smartctl 経由ではなく IOKit を直接呼ぶ

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-08-17 |
| Binds | nvme-lens |
| Decision makers | nlink-jp maintainers |
| Triggered by | RFP §3 — NVMe SMART の取得経路として smartmontools への外部依存と IOKit 直叩きのいずれを採るか |

## Context

nvme-lens は NVMe の SMART / Health Information ログ（Log 0x02）を **60 秒間隔で
常時サンプリングする常駐アプリ**である。取得経路は macOS 上で 2 つある。

**経路 A: `smartctl` を子プロセスとして起動し、出力をパースする。** 実装量は最小で、
NVMe の仕様書を読む必要がない。ただし利用者に `brew install smartmontools` を
要求する。当組織では、ツールの採否は機能ではなく**利用者が準備できるかどうか**で
決まるという原則を採っており、外部バイナリの事前導入はこの原則に正面から抵触する。
加えて smartmontools は GPL であり、`.app` への同梱は配布形態を複雑にする。
出力書式は版ごとに変わりうるため、パーサは恒久的に drift リスクを背負う。

さらに本ツールに固有の事情として、**一発叩きの CLI と、60 秒ごとにサンプリングする
常駐プロセスとでは、子プロセス起動のコストと壊れ方が質的に異なる**。ドライブ台数 ×
1440 回/日のプロセス起動が定常的に走り、そのすべてが `PATH` の状態・Homebrew の
更新・バイナリの署名状態に依存する。監視ツール自身の可用性を外部環境に預けることになる。

**経路 B: IOKit の `IONVMeSMARTInterface` を直接呼ぶ。** `GetIdentifyData` と
`GetLogPage` が使える。これは smartctl の Darwin backend 自身が使っている経路であり、
新規の未検証な手段ではない。

調査時に以下を実機で確認した。

- **root 権限は不要。** `smartctl -a` を sudo なしで実行し、内蔵 NVMe と
  Thunderbolt 接続の外付け NVMe の双方から全項目を取得できた。したがって特権
  ヘルパーツールも root daemon も設計に入れる必要がない
- Darwin には USB Mass Storage への SCSI/ATA pass-through 経路が存在せず、
  `-d sat` 等は 1 バイトも送らずに拒否される。これは経路 A・B のどちらを選んでも
  同じ制約であり、経路の選択理由にはならない

## Decision

**IOKit の `IONVMeSMARTInterface` を直接呼ぶ（経路 B）。外部バイナリには一切
依存しない。**

具体的には:

1. `GetIdentifyData` で Identify Controller を取得し、**Serial Number を
   デバイス識別子とする**。BSD 名も IOService パスも再接続で変わるため、
   これらを永続的なキーに使わない
2. `GetLogPage(0x02)` で SMART / Health Information ログを取得し、構造を
   NVMe 仕様に従って自前でパースする
3. 温度は Composite ではなく **Temperature Sensor 1..8 を個別に読み、最大値で
   判定する**（RFP §7 のとおり Composite はホットスポットを 17〜21℃ 低く見せる）
4. パーサは既知バイト列を入力とする単体テストで担保する。実デバイスを必要としない
   テストが成立する設計にする
5. **`smartctl` はテストの参照実装（オラクル）としてのみ使い、製品コードからは
   一切呼ばない。** 境界は否定形でも明示しておく:
   - 製品バイナリは `smartctl` を起動しない。その存在を前提にせず、`PATH` も探索しない
   - smartmontools は**開発環境のツール**であり、実行時依存でも配布物の一部でもない。
     利用者に導入を求めない
   - `smartctl` を必要とするクロスチェックは**開発機でのみ走る別スイート**に隔離し、
     通常の単体テストスイートからは分離する。smartmontools が無い環境でも
     単体テストは全て通る

## Consequences

**得られるもの:**

- 外部依存ゼロ。利用者の準備は不要で、`.app` 単体で完結する
- GPL との関係が発生せず、配布形態が単純になる
- 出力書式の drift リスクが消える。読むのは仕様で固定されたバイナリ構造になる
- サンプリングごとの子プロセス起動が無くなる
- root 不要（実機確認済み）。特権ヘルパーも daemon も不要

**引き受けるコスト:**

- **ログページのパースは自前の責任になる。** 仕様の読み違いは自分のバグである。
  既知バイト列に対する単体テストで担保するが、テストの期待値そのものを間違える
  可能性は残る。その期待値を `smartctl` の出力で検証する（Decision 5）。
  **これはテスト側だけの話で、実行時依存は発生しない**
- `IONVMeSMARTInterface` が提供するのは `GetIdentifyData` と `GetLogPage` のみ。
  self-test の実行や任意の Admin コマンド送出はできない。RFP §3 の「読み取り専用に
  徹する」方針とは矛盾しないが、**将来 self-test 実行機能を持たせる道は塞がる**
- NVMe 以外は到達できない。これは既に scope 外である
- Apple が `IONVMeSMARTInterface` を変更・廃止した場合、代替手段がない。
  ただし**この点で経路 A が優位なわけではない** — smartctl も同じインタフェースを
  使っているため、同時に壊れる。「smartctl ならフォールバックになる」という
  期待は成立しない

## Alternatives considered

**1. `smartctl` を起動して出力をパースする。** 実装は最短。却下理由は Context に
述べたとおり、利用者への導入要求が採否原則に抵触すること、GPL 同梱の煩雑さ、
出力書式の drift、および常駐サンプリングにおける子プロセス起動の定常コストと
外部環境への依存。

**2. IOKit 主・`smartctl` フォールバックの併用。** 網羅性は上がるように見えるが、
実際には二重の実装と二重の検証が必要になり Phase 1 が膨らむ。しかも上記のとおり
両者は同一インタフェースを使うため、**フォールバックとして機能する故障モードが
ほとんど存在しない**。冗長性の実体がないまま複雑性だけを買うことになる。

**3. smartmontools のバイナリを同梱する。** 利用者の準備は不要になるが、GPL の
配布義務、署名・notarize 対象の増加、上流更新への追随義務を負う。得られるものは
経路 B と同じ「外部依存なし」であり、コストだけが高い。

## References

- [RFP: nvme-lens](../nvme-lens-rfp.ja.md) — §3 Design Decisions / §7 External Platform Constraints
- smartmontools `os_darwin.cpp` — Darwin backend が `IOATASMARTInterface` と
  `IONVMeSMARTInterface` のみを扱い、SCSI を未サポートとしていること
- NVM Express Base Specification — SMART / Health Information Log (Log Identifier 02h) の構造
