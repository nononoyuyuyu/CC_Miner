# 05. 安全設計（V3）

V3 は「開始前に拒否し、実行中は状態を保存し、判断できないときは停止する」方針です。Modpack 固有のブロック、流体、仕分け機、チャンクロードは自動で安全だと仮定しません。

## preflight と範囲重複

ジョブ開始・キュー投入・worker dispatch の各時点で、次を検査します。

- 接続（offline でない）、入力値（invalid でない）、許可チャンクの connectivity
- worker capability、lease、GPS 条件、ドック向き、保護ブロック
- 既存の active／queued world job と X/Z 範囲が重ならないこと

fuel、seal 材、torch などの stock 不足は補給前提 warning です。offline／invalid／connectivity／capability／lease は fatal で開始しません。local queue は指定 worker ごとの順番で処理し、world queue は重複を拒否します。単一 footprint を複数 worker へ自動分割する機能は安全上無効です。複数 worker は非重複な独立 queue job のみ並列 dispatch します。

GPS がない場合の相対座標は、その worker の local queue 内でのみ比較できます。異なるドックの相対範囲を重複なしとみなすことはできません。外部 job や手動採掘による重複は検知できません。

## チャンクグリッドと除外経路

グリッドは 1 タイル = 1 チャンクで、部分セルはありません。初期状態と ALL は全採掘、CLEAR は入口以外解除、RECT は二点の矩形だけ採掘、INVERT は入口固定で反転、個別タッチは一タイルを切り替えます。

除外 job は許可チャンクの隣接グラフを作り、入口を根とした DFS で全許可チャンクへ到達できる場合だけ開始します。

- 採掘: 許可チャンク内部の蛇行
- チャンク間移動: 親子アンカー間の許可辺のみ
- 補給帰還: 現在チャンクから DFS 親を逆にたどる
- 作業復帰: 入口からチェックポイントまで親経路をたどる

経路の再計算に失敗したり現在位置がどのチャンクにも属さない場合は `blocked` として停止します。チャンクロード状態を読み取って経路を変えることはありません。

## 液体封鎖

`lavaMode=seal`、`waterMode=seal` では、進行方向・上・下の水／溶岩を設定済みの固体ブロックで封鎖します。continuous seal の実効上限は `min(worker の絶対上限, profile cap)`（SAFE=8、BALANCED=32、TURBO=64）です。

- 砂・砂利・TNT・バケツ・可燃物・液体を封鎖材にしない
- `turtle.place*` が失敗したら液体へ移動しない
- 封鎖材不足、許可リスト外、チェスト空、上限超過は `waiting_seal` または wizard
- Mod 追加流体の名前判定や流れ方は実環境で確認する

## たいまつと採掘石の再利用

Torch チェストは seal 側の反対側に専用で置きます（既定 seal=右／torch=左）。SAFE は間隔最大 8、BALANCED は設定値（既定 10）、TURBO は 12 です。通常の 1×1 坑道では保護／容器／液体／重力ブロックを避け、左右どちらかの 1 ブロック niche に torch を置きます。両側が使えない場合は安全停止します。custom floor fallback は任意で、失敗しても致命的ではありません。

採掘石の再利用は、設定したブロック名だけを seal 材として予約します。保持上限、予約スロット、圧縮／仕分け先を設定しない場合は搬出または停止へフォールバックします。再利用したブロックを燃料や貴重資源と誤認しないよう、許可リストを狭く保ってください。

## GPS と電源断

GPS は位置を測れますが向きを直接測れません。校正済みなら移動・採掘・設置の保留操作を前後座標から判定し、旋回・GPS 校正中・fix 不能は復旧 wizard を要求します。

GPS 必須設定では fix が得られない間、開始・帰還・復帰を行いません。world queue の `targetY` も GPS world のみで、`depth = homeY - targetY + 1`。local queue は入力した depth を使います。GPS の取得には各ホストと採掘地点がロードされている必要がありますが、その状態の取得・表示・自動化は CC Miner の責務ではありません。

## 段階停止と状態 journal

停止要求は操作境界で処理します。即時停止でも物理操作の途中ではタートルを動かし続け、確定後に停止します。行末・層末・帰還・中止は未完了セルを飛ばしません。

状態ファイル（`state.db`）が正で、journal と checkpoint は補助です。journal は `maxEntries`／size rotate と checkpoint を使います。アンロード中の停止は `waiting_*` とチェックポイントを保存し、次回ロードでチェストと在庫を再確認します。状態が壊れた、または journal と姿勢が矛盾する場合は空の job として再開せず停止します。

## 燃料・在庫・保護ブロック

補給判断は、通常 job では高速 serpentine のドック距離、除外 job では DFS 親経路、さらに profile の fuel margin を使います。SAFE は 1.5 倍、BALANCED は設定値、TURBO は safety を下げません。Mod 追加の迂回、液体封鎖、他エンティティの押し出しは見積外なので、最初は BALANCED 以下で確認してください。

Bedrock、Portal 類、Computer／Turtle 類、設定済みの保護ブロック、インベントリを持つブロックは掘りません。Mod 追加の重要ブロックは `protectedBlocks` へ追加します。搬出チェスト満杯、燃料切れ、seal 材・torch 切れはそれぞれ待機状態にし、無理な前進をしません。

## 通知・有線仕分け

speaker と redstone は完了、停止、待機、復旧要求を知らせるだけです。信号を受けた装置が危険な動作をしないよう、ドア・ピストン・ポンプ・チャンクローダーを直接連動させないでください。

有線仕分けは controller の source inventory から valuable／bulk／seal へ push します。送出先が満杯・切断中なら残留して次 tick に再試行し、worker の `waiting_output` とは連動しません。

## 手動操作と管理上の制約

稼働中のタートルをピストン、レンチ、プレイヤー操作で移動・回転させないでください。GPS 不一致、未知の流体、範囲外、管理者による外部コマンドは安全停止の対象です。CC Miner には管理者権限、認証、監査ログ、チャンクロード管理はありません。
