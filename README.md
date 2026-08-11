# CC Miner V4

CC: Restitched / CC:Tweaked 向けの CC Miner V4.0.0（schema 4）です。復旧可能な遠隔クアリーとして、Advanced Mining Turtle と Advanced Computer で 1 タイル = 1 チャンクの grid、preflight、補給・帰還、queue、group、GPS、report を扱います。

## マニュアル

導入から GPS 塔、単一／複数 bay、controller、group / discard、絶対 BOTTOM Y、性能、安全、復旧、検証までを日本語でまとめています。

**[CC Miner V4 マニュアルを開く](docs/index.html)**

## 最短の導入

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
```

GPS を使う場合は 4 台以上の host を追加します。

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua gps
```

HTTP が使えない場合は、`dist/ccminer-offline-worker.lua` + `dist/ccminer-offline-worker.parts/`、`dist/ccminer-offline-controller.lua` + `dist/ccminer-offline-controller.parts/`、`dist/ccminer-offline-gps.lua` + `dist/ccminer-offline-gps.parts/` を役割ごとに対で転送してください。loader は組立・検証後に自身の parts を削除するため、原本は PC／外部媒体に保持します。互換 dispatcher `dist/ccminer-offline.lua` も利用できます。

role loader は role 名（または省略）で導入し、`update`／`update-low-space` は既存 `config.role` と一致する場合だけ実行します。オンラインの `install.lua update` は role を自動判定し、marker は失敗位置から再開します。

チャンクロード管理、管理者権限、認証基盤、強い暗号化は提供しません。対応環境・構成・安全境界はマニュアルを確認してください。

## 変更履歴

[CHANGELOG.md](CHANGELOG.md) を参照してください。
