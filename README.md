# CC Miner V3

CC: Restitched / CC:Tweaked 向けの、復旧可能な遠隔クアリーです。Advanced Mining Turtle と Advanced Computer を使い、1 タイル = 1 チャンクのタッチ式グリッド、採掘前 preflight、補給・帰還、ジョブキュー、レポートをまとめて扱います。

![V3 のコントローラー、GPS、ワーカー、ドック、採掘領域の関係](docs/images/system-overview.svg)

## V3 の要点

- タッチ／クリックでチャンクを **個別 / RECT / ALL / CLEAR / INVERT** 操作。初期状態と ALL は全採掘、CLEAR は入口以外を解除、RECT は二点で囲んだ矩形だけを採掘対象にします。入口は固定され、チャンクの一部だけを選ぶことはありません。進捗色で入口・対象・済み・進行中・停止を区別します。
- 採掘前に preflight（接続、入力、連結性、能力、lease、GPS 条件、範囲重複）と見積を確認します。燃料・封鎖材・たいまつなどの在庫不足は補給前提の警告、offline／invalid／connectivity／capability／lease は致命的エラーです。
- **SAFE / BALANCED / TURBO**、ジョブプリセット、キュー、ジョブ履歴、完了レポートを利用できます。単一フットプリントを分割して複数 worker へ割り当てる機能は安全上無効です。複数 worker は、指定 worker ごとの非重複な独立 queue job を dashboard 稼働中に並列 dispatch します。
- たいまつ自動照明、採掘石の封鎖材への再利用、水／溶岩の封鎖（または停止）、段階停止、復旧 wizard に対応します。
- 通常の蛇行経路は高速化し、除外時は DFS とグラフ計算、補給判断、描画キャッシュ、スタック圧縮を高速化します。経路を省略して安全確認を飛ばす `optimizedWalk` は使用しません。
- speaker／redstone 通知と、任意の controller 側 Wired Modem 仕分け（source から valuable／bulk／seal へ push）に対応します。仕分け先が満杯なら残留して次 tick に再試行します。

チャンクのロード状態を取得・表示したり、チャンクローダーを自動操作したりはしません。必要なロード範囲はサーバー／Modpack 側で用意してください。

## 対応と前提

- Minecraft 1.18.2、CC: Restitched / CC:Tweaked 1.100.x 系
- Advanced Mining Turtle + Wireless Modem、Advanced Computer + Wireless Modem
- タッチ操作を使う場合は Advanced Monitor（端末のクリックだけでも可）
- GPS は任意。ただしワールド座標チャンク、GPS 必須設定、world queue の重複検査、電源断の自動復旧には 4 台以上の GPS ホストが必要です。
- 管理者権限、認証基盤、チャンクロード管理は提供しません。ネットワークキーは暗号化ではなく、信頼できるネットワークで使用してください。

## ドック

![V3 ドック上面図](docs/images/base-layout-top.svg)

後ろに搬出、上に燃料、seal 材チェストと torch チェストを seal 側の反対側へ置きます。既定は **seal=右、torch=左** で、左右の専用チェストを使用します。通常の 1×1 坑道では、保護／容器／液体／重力ブロックを避け、左右どちらかの 1 ブロック niche に torch を置きます。両側が使えない場合は安全停止します。custom の床置き fallback は任意で、失敗しても致命的ではありません。

詳細は [必要資材](docs/01-materials.md) と [建築と配置](docs/02-build.md) を確認してください。

## 導入

ワーカー:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
```

コントローラー:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
```

GPS ホスト（必要な場合に 4 台以上）:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua gps
```

HTTP を使えない場合は [`dist/ccminer-offline.lua`](dist/ccminer-offline.lua) と隣接する [`dist/ccminer-offline.parts/`](dist/ccminer-offline.parts/) をセットで転送します。既存環境の更新は `ccminer-offline.lua update` です。詳しい設定は [インストール](docs/03-install.md) を参照してください。

## 初回運転（最短手順）

1. ワーカーとコントローラーを同じネットワークキーでセットアップし、搬出・燃料・seal 材・torch チェストを補充します。
2. GPS を使う場合は 4 台以上のホストを起動し、ドックで **GPS CAL** を実行します。正面 1 ブロックを空けてください。
3. `ccm dashboard` を開き、対象 worker の **NEW JOB** で寸法と SAFE/BALANCED/TURBO を選びます。GPS world queue の `targetY` は `depth = homeY - targetY + 1`、local queue は入力した depth を使います。
4. チャンクグリッドで個別／RECT／ALL／CLEAR／INVERT を行い、入口が残っていることを確認します。
5. preflight と見積を読み、**START** または QUEUE を押します。通知や仕分けを使う場合は開始前に設定します。

![入口を残し中央を除外したチャンクグリッドの例](docs/images/chunk-mask.svg)

## よく使うコマンド

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

段階停止、キュー操作、ジョブ履歴／レポート、復旧 wizard はダッシュボードから行います。controller は ACK/status を保持して再試行しますが、電源断や外部仕分けの二重処理を完全には保証しません。`ccm rehome RESET` は物理的にドックへ戻して正面を合わせた後だけ実行してください。

## 制約と安全上の注意

- SAFE の torch 間隔は最大 8、BALANCED の既定は 10、TURBO は 12。1×1 坑道の左右 niche が両方塞がっている、torch 不足、設置失敗は安全停止します。custom floor fallback の失敗は非致命的です。
- 設定した固体ブロック、液体名、torch、保護ブロック以外の Mod 追加要素は自動判定できないことがあります。まず小さい試験区画で確認してください。
- GPS 必須設定では fix が得られない間は開始・復帰を行いません。GPS 任意設定ではローカル座標へフォールバックしますが、world queue や world 重複検査は使えません。
- 水／溶岩を封鎖する材料が不足した場合は停止または補給帰還します。砂・砂利・可燃物・液体を封鎖材に登録しないでください。
- 稼働中のタートルを手動で移動・回転させないでください。復旧 wizard の指示に従い、必要ならドックで REHOME します。

## 詳細文書

- [全体設計](docs/00-overview.md)
- [必要資材](docs/01-materials.md)
- [建築と配置](docs/02-build.md)
- [インストール](docs/03-install.md)
- [操作方法](docs/04-operation.md)
- [安全設計](docs/05-safety.md)
- [トラブルシューティング](docs/06-troubleshooting.md)
- [検証](docs/07-testing.md)
- [参照資料](docs/08-sources.md)

V3 の検証方法と、Lua 実行環境がない場合の扱いは [検証](docs/07-testing.md) に記載しています。
