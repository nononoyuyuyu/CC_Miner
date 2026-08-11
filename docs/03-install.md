# 03. インストール

## オンライン

ワーカー:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
```

コントローラー:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
```

GPSホスト:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua gps
```

GPSホストは4台以上で同じコマンドを実行し、それぞれ固有のワールド座標を入力します。

## オフライン

`dist/ccminer-offline.lua` と `dist/ccminer-offline.parts/` ディレクトリを同じ親ディレクトリへ転送し、次のいずれかを実行します。分割ファイルはローダーが順番に結合するため、名前・内容・配置を変更しないでください。

```lua
ccminer-offline.lua worker
ccminer-offline.lua controller
ccminer-offline.lua gps
```

コマンドは2つの配布物を置いた親ディレクトリで実行します。初回セットアップが途中で終了した場合は、表示された `/ccminer/setup.lua <role>` を実行して設定を再開し、完了後に `reboot` します。

既存環境の更新:

```lua
ccminer-offline.lua update
```

## セットアップ項目

### ワーカー

- ネットワークキー
- ワーカー名
- 目標燃料
- 予約空きスロット
- 溶岩動作 `seal` / `stop`
- 封鎖材チェスト側と補給量
- GPSの有効化・必須化
- エンティティ攻撃の可否

### コントローラー

- ワーカーと同じネットワークキー
- コントローラー名
- モニター文字倍率
- タッチ操作の有効化

### GPSホスト

- ホスト名
- 無線モデムブロックのワールドX/Y/Z

## 更新時に保持するデータ

- `/ccminer/config.db` とバックアップ
- `/ccminer/data/state.db` とバックアップ
- ログとローテーション済みログ

新しいLuaファイルは一時ディレクトリで構文検査してから入れ替えます。旧ファイルは `/ccminer.backup` に残ります。
