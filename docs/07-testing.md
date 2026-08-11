# 07. 検証（V3）

この文書は検証手順です。テスト、リンク検証、SVG レンダリング検証はリリース確認時に実行してください。

## 一括検査

Python 3.10 以降と Lua 5.2 互換の `texlua`、`lua5.2`、`lua` のいずれかが必要です。別の実行ファイルを使う場合は `CCMINER_LUA` にパスを設定します。

```text
python tools/check.py
```

生成物の差分を指摘された場合は、先に次を実行します。

```text
python tools/build_offline_bundle.py
```

Lua が見つからない場合も非 Lua 検査まで実行されますが、全検証完了とはみなしません。

## 静的検査項目

1. 全 Lua ファイルの構文読み込み
2. 通常 serpentine 経路とチャンク DFS の隣接・重複なし
3. 1 タイル = 1 チャンクの grid、入口固定、個別／RECT／ALL／CLEAR／INVERT
4. 負座標を含む GPS 座標変換、world `targetY`（`depth = homeY - targetY + 1`）、local depth
5. world active／queued 範囲重複拒否、local 指定 worker 順、単一 footprint 分割の拒否
6. preflight の warning（stock）と fatal（offline／invalid／connectivity／capability／lease）
7. SAFE/BALANCED/TURBO の実効値（torch、fuel margin、空き slot、stack 整理、continuous seal）
8. たいまつ自動照明、専用左右チェスト、採掘石の封鎖材再利用、水／溶岩封鎖
9. 段階停止、アンロード中断、再ロード後の checkpoint と復旧 wizard
10. state.db の原子的入れ替え、`.bak` 復旧、補助 journal の maxEntries／rotate／checkpoint
11. ACK/status の保持・再試行（外部装置の二重処理保証ではない）
12. speaker／redstone 通知と controller source→valuable／bulk／seal push の切断・満杯（次 tick retry）
13. report の `jobId`、`reason`、`time`、`elapsed`、`progress`、`stats`、`estimate`／`actual`、material counts
14. manifest、オンラインインストーラー、オフラインビルダーの収録一致
15. Markdown 相対リンク、SVG の宣言グリッド整合、代替テキスト
16. 分割オフライン配布物の連番・サイズ・再結合後 Lua 構文
17. Rednet のバージョン、payload 型、送信元・宛先一致

チャンクロード状態の取得・表示・自動化を実装していないことも確認します。ロードが必要な試験では、サーバー／Modpack 管理者が外部のロード設定を用意し、CC Miner の結果と混同しないでください。

## 実機受け入れ試験

### ジョブ作成・grid

- 小さい寸法で preflight が成功し、stock 不足が warning、fatal 項目が開始拒否になる
- 初期状態／ALL、CLEAR、個別、二点 RECT、INVERT が入口を固定して反映される
- 入口除外、分断領域、world active／queued の範囲重複が拒否される
- world の `targetY` は GPS のみ、local は入力 depth になる

### profile・queue・dispatch

- SAFE（空き slot +2、fuel 1.5x、torch 最大8、stack16、seal cap8）、BALANCED（既定 torch10／compact32／seal32）、TURBO（空き slot -1 最低1、fuel safety維持、torch12、stack64、seal cap64）を確認する
- 明示した `waterMode`／`lighting.mode` が profile で上書きされない
- 単一 footprint 分割が拒否され、非重複な独立 job を指定 worker ごとに dashboard 稼働中並列 dispatch できる
- world queue の重複拒否と local queue の指定 worker 順を確認

### 照明・素材・液体

- seal=右／torch=左の専用チェストへ補給する
- 通常 1×1 坑道の左右 niche、保護／容器／液体／重力ブロック回避、両側不可の安全停止を確認
- custom floor fallback の失敗が非致命であることを確認
- 許可された採掘石だけが seal 材へ再利用され、保持上限超過は搬出または待機になる
- 水／溶岩の seal、stop、`min(worker絶対上限, profile cap)` を確認

### 停止・電源断・復旧

- 即時、行末、層末、帰還、中止が指定境界で停止する
- 搬出・燃料・seal・torch 補給中に停止または電源断し、再ロード後に保存済み state から再開する
- 移動中の電源断は GPS で前後を判定し、旋回中・fix 不能は wizard を表示する
- 手動移動後は GPS drift を検出し、REHOME RESET まで採掘しない

### 通知・仕分け

- speaker の完了／停止／待機音と redstone 信号を確認
- controller source→valuable／bulk／seal の送出、満杯残留、次 tick retry を確認
- wired 仕分けが worker `waiting_output` と直結しないことを確認

実機試験では必ずバックアップしたワールドと小さい保護区画を使い、サーバーの管理者がロード範囲を用意してください。
