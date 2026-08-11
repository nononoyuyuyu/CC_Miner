# 04. 操作方法（V3）

## ダッシュボード

`ccm dashboard` で開きます。端末と接続中の Advanced Monitor へ同じ画面を描画し、端末のマウスクリックと `monitor_touch` を同じボタン処理へ渡します。

ワーカー行をタッチ／クリックして選択し、状態色・進捗・現在層・燃料・seal 材・torch・待機理由を確認します。チャンクロード状態は表示しません。

| 画面／ボタン | 動作 |
|---|---|
| DISCOVER | ワーカーを再探索 |
| NEW JOB | 寸法、プロファイル、液体、照明、チャンクグリッドを設定 |
| PRESET | SAFE / BALANCED / TURBO、保存済みジョブプリセットを読み込み／保存 |
| QUEUE | preflight 済みの独立 job を指定 worker 順に保持・dispatch |
| HISTORY / REPORT | ジョブ履歴と実装済みフィールドのレポートを表示／出力 |
| INFO | GPS、経路、燃料、在庫、seal 材、torch、journal を表示 |
| PAUSE / RESUME | 既定の安全境界で停止／再開 |
| STOP | 停止地点（即時、行末、層末、帰還、中止）を選択 |
| RECALL / SERVICE | 帰還して搬出・燃料・seal 材・torch を補給 |
| ABORT | 帰還後に job を中止し、レポートを残す |
| CLEAR | ホームで完了／中止記録を消去 |
| RECOVER | 復旧 wizard を開き、電源断・アンロード停止・位置不一致を案内 |
| GPS CAL | ドックで正面へ 1 ブロック往復して校正 |

キーボードの既存ショートカット（`D/N/P/R/H/S/X/C/I/G/L/Q`、上下キー）も利用できます。小さいモニターではボタンや行が減るため、端末または大きいモニターで操作してください。

## 新規 job とプリセット

### 寸法・運転プロファイル

幅（右）、長さ（前）、深さ（下）を入力し、次のプロファイルから選びます。明示した `waterMode` と `lighting.mode` はプロファイルで上書きされません。

| プロファイル | 実効設定 | 注意 |
|---|---|---|
| SAFE | 空き slot 設定値 +2、fuel margin 1.5 倍、torch 間隔最大 8、stack 整理最大 16 moves、continuous seal 上限 `min(worker設定の絶対上限, 8)` | 補給回数と所要時間が増える |
| BALANCED | 設定値（既定 torch 10、compact 32、continuous seal 32） | 最初の試験に推奨 |
| TURBO | 空き slot 設定値 -1（最低 1）、fuel safety は下げない、torch 間隔 12、stack 整理 64 moves、continuous seal 上限 `min(worker設定の絶対上限, 64)` | worker 絶対上限（既定 32）を超えない |

プリセットは寸法、チャンク選択、液体動作、照明、再利用、通知をまとめます。サーバーや Modpack ごとに燃料値・掘削速度が違うため、保存値と実効値の両方を preflight で確認してください。

### タッチ式チャンクグリッド

グリッドは **1 タイル = 1 チャンク** で、部分セルはありません。

1. 初期状態と **ALL** は全チャンクを採掘対象にします。
2. **CLEAR** は入口チャンクだけを残して解除します。
3. **個別** はタイルをタッチして採掘／解除を切り替えます。
4. **RECT** は始点と終点の二点で指定した矩形だけを採掘対象にします。
5. **INVERT** は入口を固定したまま対象を反転します。

色は入口（変更不可）、採掘対象、除外、採掘済み、現在進行中、停止／エラーを示します。GPS 校正済みならワールドチャンク、未校正なら採掘原点基準の相対チャンクです。入口除外、連結性喪失、既存 job との重複は開始または QUEUE で拒否されます。

world queue の `targetY` は GPS world のみで有効で、`depth = homeY - targetY + 1` です。local queue は入力した depth を使います。

## preflight と見積

`PREVIEW` → `PREFLIGHT` の順で確認します。

- 接続、入力値、チャンク連結性、worker capability、lease、GPS 条件、既存 active／queued world 範囲の重複
- ドック向き、保護ブロック、fuel／空き slot、seal／torch のチェスト、通知、wired source
- `waterMode` / `lavaMode`、封鎖材の許可リスト、照明、再利用の設定

fuel、seal 材、torch などの stock 不足は「補給前提」の warning です。offline、invalid、connectivity、capability、lease は fatal で、解消するまで START／QUEUE を有効にしません。

見積は採掘セル数、移動・旋回数、体積、想定補給回数、seal／torch 予備、概算燃料を示します。液体の分岐、保護ブロック、詰まり、Mod 追加の迂回、実際の仕分け速度は含まれない場合があります。

## キューと worker dispatch

単一 footprint を複数 worker へ分割する機能は安全上無効です。複数 worker を使う場合は、指定 worker ごとに非重複な独立 queue job を登録し、dashboard が稼働している間だけ並列 dispatch します。world queue は active／queued の X/Z 範囲重複を拒否し、local queue は指定 worker ごとの登録順に処理します。

controller は送信した job の ACK/status を保持し、応答がない場合に再試行します。これは通信の再送制御であり、外部チェストや仕分け機の二重処理を完全には保証しません。

## 照明・液体・封鎖材

- SAFE の torch 間隔は最大 8、BALANCED は設定値（既定 10）、TURBO は 12。通常の 1×1 坑道では保護／容器／液体／重力ブロックを避け、左右どちらかの 1 ブロック niche に置きます。両側が使えない場合は安全停止します。custom floor fallback は任意で、失敗しても致命的ではありません。
- Torch チェストは seal 側の反対側に専用で置きます（既定 seal=右／torch=左）。
- 採掘石のうち許可リストにある固体ブロックは seal 材として保持できます。保持上限を超えた分は搬出、または設定に従って待機します。
- 水／溶岩は `seal` なら seal 材を置いて置換し、`stop` ならその場で停止します。continuous seal の実効上限は worker の絶対上限と profile cap の小さい方です。
- seal 材が足りない場合は無理に液体へ入らず、帰還できる経路で補給します。

## 段階停止とアンロード再開

STOP の停止地点は次のとおりです。

- **即時**: 現在の物理操作を確定できる安全境界で一時停止
- **行末**: 現在の蛇行行を終えて停止
- **層末**: 現在層を終えて停止
- **帰還**: 補給・搬出後、job を保持してホームで停止
- **中止**: 帰還・補給後に job を中止してレポートを保存

搬出・燃料・seal・torch 補給中に電源断または停止した場合、`unloading`／`waiting_*` とアンロード境界を保存します。次回ロード時にチェストと在庫を再確認し、保存済み状態から処理を再開します。曖昧な旋回や GPS 不一致は自動で進めず、復旧 wizard を要求します。

## 復旧 wizard

1. 表示された停止理由（GPS、journal、液体、在庫、アンロード）と最後の確定座標を読む。
2. タートルを手動で動かした場合は、電源を切ったままドックへ戻し、採掘方向へ向ける。
3. チェスト、燃料、seal 材、torch、ケーブルを確認し、`REHOME` または wizard の **RESET** を実行する。
4. GPS 校正済みなら fix とドック座標を確認します。fix がない旋回・校正中断は手動確認が必要です。
5. `RESUME`（job 保持）または `ABORT`（レポートを残して中止）を選びます。

`REHOME RESET` は進行中の job を消去します。状態ファイル破損、範囲外の物理移動は自動復旧できません。

## 履歴とレポート

ジョブ履歴は job の存在と状態を確認するための要約です。REPORT の実装フィールドは `jobId`、`reason`、`time`、`elapsed`、`progress`、`stats`、`estimate`／`actual`、material counts です。開始・停止・復旧の全イベントを詳細な監査履歴として保存する機能ではありません。

## コマンドライン

```text
ccm dashboard
ccm discover
ccm status
ccm logs
ccm start <id> <width> <length> <depth>
ccm pause|resume|recall|service|abort|clear <id>
ccm gps <id>
ccm calibrate <id>
ccm rehome <id> RESET
```

CLI の `start` は既定の local 範囲を作る簡易入口です。チャンク操作、profile、queue、段階停止、履歴／report は dashboard で設定してください。
