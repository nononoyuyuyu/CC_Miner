# 3. プログラム導入

## 導入前確認

- ワーカーは、Diamond PickaxeとWireless Modemを装備したAdvanced Turtleであること
- コントローラはAdvanced Computerで、Wireless Modemが隣接していること
- [配置と建築](02-build.md) が完了していること
- オンライン導入ではComputerCraftのHTTP APIと、`raw.githubusercontent.com` への接続が許可されていること

同じ採掘システムに所属する機械には、同じネットワークキーを設定します。キーは英数字、`-`、`_` のみ、8～40文字です。

例:

```text
ASTRAL-MINE-01
```

## A. オンライン導入

### ワーカー

タートルを右クリックして端末を開き、次を1行で入力します。

```text
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
```

質問には次のように答えます。

| 質問 | 推奨値 | 説明 |
|---|---|---|
| Network key | `ASTRAL-MINE-01` 等 | コントローラと完全一致させる |
| Worker name | `Miner-A` | 一覧で識別する名前 |
| Fuel target | `12000` | ホームで補給する目標値 |
| Reserved empty inventory slots | `3` | 満杯前に帰還する余裕 |
| Stop before lava | `Y` | 溶岩を検出したら停止 |
| Attack entities blocking movement | `N` | 生物を攻撃せず安全停止 |

完了後、次を実行します。

```text
reboot
```

再起動後、画面に `CC Miner V2 Worker` とIDが表示されます。`No wireless modem found` と出た場合は、タートルのアップグレードを直してください。

### コントローラ

Advanced Computerを開き、次を入力します。

```text
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
```

設定:

| 質問 | 推奨値 | 説明 |
|---|---|---|
| Network key | ワーカーと同じ | 1文字でも違うと検出不能 |
| Controller name | `Mine-Control` | コンピュータのラベル |
| Monitor text scale | `0.5` | モニタなしでもそのままでよい |

完了後:

```text
reboot
```

コントローラ画面が開きます。`D` を押すとワーカーを再検出します。

## B. オフライン導入

HTTPを使用できない場合、`dist/ccminer-offline.lua` は全実行ファイルを内包した単一ファイルです。

### ファイルをゲーム内へ持ち込む方法

次のいずれかを使います。

1. HTTPが使える別のComputerCraftコンピュータでファイルを取得し、Floppy Diskへコピーする。
2. シングルプレイのComputerCraftコンピュータ保存領域へ、ホストOS側からファイルを配置する。
3. サーバ管理者に、Disk Driveまたは対象Computer IDの保存領域へファイルを配置してもらう。

他のGitHubリポジトリやPastebin版は使用せず、このリポジトリの配布ファイルだけを使ってください。

### ディスクからワーカーへ

Disk Driveをタートルに隣接させ、ファイル入りディスクを入れます。端末で次を実行します。

```text
copy /disk/ccminer-offline.lua /ccminer-offline.lua
ccminer-offline worker
reboot
```

### ディスクからコントローラへ

```text
copy /disk/ccminer-offline.lua /ccminer-offline.lua
ccminer-offline controller
reboot
```

質問内容はオンライン導入と同じです。

## 導入後の確認

### ワーカー側

```text
ccm status
```

次を確認します。

- `Role: worker`
- `Status: idle / home`
- `Pose: x=0 y=0 z=0`
- 設定したWorker name

### コントローラ側

```text
ccm discover
```

ワーカーID、名前、状態が1行以上表示されれば通信成功です。

一覧が出ない場合は [トラブル復旧](06-troubleshooting.md#ワーカーが見つからない) を確認します。

## 自動起動の扱い

インストーラは `/startup.lua` をCC Miner起動用に設定します。既存の `/startup.lua` があった場合、その内容を `/startup.user.lua` へ保存し、先に実行します。

既存startupが永久ループする、入力待ちを続ける、またはエラー停止する場合、CC Minerまで処理が到達しません。その場合は既存startupを修正するか、一時的に `/startup.user.lua` を別名へ変更します。

## 更新

### オンライン

ワーカーとコントローラでそれぞれ実行します。

```text
ccm update
reboot
```

設定、状態、ログは保持されます。旧コードは `/ccminer.backup` に残ります。

ジョブ中の更新は避け、先に `recall` でホームへ戻してから行ってください。

### オフライン

最新版の `ccminer-offline.lua` をディスクへ入れ直し、各機械で次を実行します。

```text
ccminer-offline update
reboot
```

## 再設定

役割を保ったまま名前、キー、燃料目標等を変更する場合:

```text
ccm setup
reboot
```

ネットワークキーを変更する場合は、同じシステムの全ワーカーとコントローラを同じ値へ変更してください。
