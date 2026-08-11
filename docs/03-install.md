# 03. インストール（V3）

## オンライン導入

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

同じネットワークキーをワーカーとコントローラーへ設定し、GPS ホストにはそれぞれ固有の無線モデム座標を入力します。HTTP の許可や URL の範囲はサーバー設定に依存します。

## オフライン導入・更新

`dist/ccminer-offline.lua` と隣接する `dist/ccminer-offline.parts/` ディレクトリを同じ親ディレクトリへ転送します。分割ファイルの名前・内容・配置は変更しないでください。

```lua
ccminer-offline.lua worker
ccminer-offline.lua controller
ccminer-offline.lua gps
ccminer-offline.lua update
```

初回セットアップが中断した場合は画面に表示された `/ccminer/setup.lua <role>` を実行し、完了後に `reboot` します。更新前の設定、状態、journal、ログは旧環境のバックアップを残してから入れ替えます。

## セットアップ項目

### ワーカー

- ネットワークキー、ワーカー名、GPS の有効化／必須化、fix タイムアウト
- `SAFE` / `BALANCED` / `TURBO` の既定プロファイルと、燃料目標・帰還バッファ・空きスロット
- `lavaMode` と `waterMode`（`seal` / `stop`、水は設定により `ignore`）。明示した `waterMode` と `lighting.mode` はプロファイルで上書きしない
- 封鎖材の許可リスト、seal 材チェスト側、seal 側の反対側に置く専用 torch チェスト、補給量・予約スロット
- たいまつ種類、照明間隔、明るさ判定、採掘石の封鎖材再利用と保持上限。SAFE は間隔最大 8、BALANCED は設定値（既定 10）、TURBO は 12
- 保護ブロック、エンティティ攻撃、移動リトライ、状態 journal のパス・checkpoint 間隔
- speaker、redstone 面、通知イベント、有線仕分けの接続先（任意）

### コントローラー

- ワーカーと同じネットワークキー、コントローラー名、モニター倍率、タッチ有効化
- ジョブプリセット、ジョブ履歴、キュー上限。単一 footprint の worker 分割は安全上無効で、指定 worker ごとの独立非重複 job の並列 dispatch のみ許可
- 通知の既定（speaker / redstone）、範囲重複をワールド座標で検査するか（GPS 必須）

### GPS ホスト

- ホスト名
- 無線モデムブロックのワールド X/Y/Z

GPS は任意です。ワールドチャンクグリッド、GPS 必須モード、world queue の重複検査を有効にする場合は、4 台以上のホストを起動してから CAL してください。単一範囲の自動分割は行いません。

## 初回設定後のチェック

1. `ccm discover` でワーカーが見えることを確認します。
2. ドックの搬出・燃料・seal 材・反対側の専用 torch を設定どおりに置きます。
3. GPS を使う場合は GPS CAL を実行し、fix とドック座標を確認します。
4. 小さい NEW JOB を作り、preflight の警告・見積・プロファイルを確認します。
5. speaker／redstone／有線仕分けを使う場合は、停止通知と source→valuable／bulk／seal の push を試験します。

## 更新時に保持するデータ

- `/ccminer/config.db` とバックアップ
- `/ccminer/data/state.db`、`.bak`、checkpoint、journal
- ジョブ履歴、`jobId`・`reason`・`time`・`elapsed`・`progress`・`stats`・`estimate`／`actual`・material counts のレポート、ログとローテーション済みログ

GPS 校正やキューを消去する更新では、画面の案内を確認してから実行してください。

## 制約

インストールはワールド管理者権限を取得しません。CC Miner はチャンクロード状態を取得・表示・自動化せず、HTTP、GPS 通信距離、Mod 追加インベントリ、仕分けプロトコル、燃料値は環境依存です。
