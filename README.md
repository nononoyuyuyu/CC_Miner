# CC Miner V2 for Create: Astral

Create: Astral 上で、採掘タートルを「置いて設定するだけ」で矩形範囲の採掘、燃料補給、搬出、帰還、再開、遠隔監視まで行うための完成済みシステムです。

対象は **Create: Astral v2.1.5a / Minecraft 1.18.2 / Fabric / CC: Restitched 1.100.8** です。ゲーム内の表示は文字化けを避けるため英語、構築手順は日本語で記載しています。

![システム全体図](docs/images/system-overview.svg)

## 実装済み機能

- 幅 `W` × 長さ `L` × 深さ `D` の全セルを、途切れない3次元蛇行経路で採掘
- 16スロットが埋まる前、または帰還燃料が不足する前に自動帰還
- ホーム後方の搬出チェストへ全アイテムを搬出
- ホーム上方の燃料チェストから、有効な燃料だけを1個ずつ補給
- 補給後に保存済み地点へ戻り、同じジョブを継続
- 複数タートルの無線検出、一覧監視、開始・停止・帰還・中止操作
- 再起動後の状態復元、二重状態ファイル、物理動作ジャーナル
- 溶岩、保護ブロック、チェスト等のインベントリ、エンティティに対する安全停止
- オンライン導入、オフライン一括導入、設定を保持した更新、旧版バックアップ
- 既存 `startup.lua` の退避と併用

## 最短導入

最初に [必要素材とクラフト](docs/01-materials.md) と [配置と建築](docs/02-build.md) を読み、タートルの**後ろに搬出チェスト**、**上に燃料チェスト**を置いてください。

採掘タートルで実行します。

```text
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
```

拠点コンピュータで実行します。

```text
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
```

両方に同じネットワークキーを設定し、両方を再起動します。コントローラで `D` を押してタートルを検出し、`N` で採掘範囲を入力します。

HTTPを使えない環境は、リポジトリの `dist/ccminer-offline.lua` をディスク経由で各機械へコピーして導入できます。詳細は [プログラム導入](docs/03-install.md) にあります。

## 手順書

1. [概要と座標の考え方](docs/00-overview.md)
2. [必要素材・中間素材・クラフト](docs/01-materials.md)
3. [ブロック配置と採掘範囲の作り方](docs/02-build.md)
4. [オンライン／オフライン導入](docs/03-install.md)
5. [実際の操作](docs/04-operation.md)
6. [安全設計と制約](docs/05-safety.md)
7. [トラブル復旧](docs/06-troubleshooting.md)
8. [検証内容](docs/07-testing.md)
9. [調査根拠とバージョン](docs/08-sources.md)

## 必ず守ること

- ジョブ中のタートルを手で壊す、持ち上げる、押す、回す行為は禁止です。
- タートルと採掘経路のチャンクをロードした状態に保ってください。
- 搬出チェストには常に空きを作り、燃料チェストにはタートル燃料だけを入れてください。
- `blocked / recovery_required` になった場合、勝手に再開せず [復旧手順](docs/06-troubleshooting.md) に従ってください。
- Rednetのネットワークキーは誤操作防止用であり、暗号化や強固な認証ではありません。

## 主なゲーム内コマンド

```text
ccm dashboard
ccm discover
ccm status
ccm logs
ccm update

ccm start <TurtleID> <幅W> <長さL> <深さD>
ccm pause <TurtleID>
ccm resume <TurtleID>
ccm recall <TurtleID>
ccm service <TurtleID>
ccm abort <TurtleID>
ccm clear <TurtleID>
ccm rehome <TurtleID> RESET
```

## 構成

```text
install.lua                    オンライン導入・更新
manifest.lua                   バージョンと配布対象
src/ccminer/worker.lua         採掘タートル本体
src/ccminer/controller.lua     遠隔コントローラ
src/ccminer/setup.lua          初期設定
src/ccminer/boot.lua           自動起動と異常再起動
src/ccminer/command.lua        ccm コマンド
src/ccminer/lib/               状態保存・通信・採掘経路
 dist/ccminer-offline.lua      オフライン一括導入版
 docs/                         日本語手順書と配置図
 tests/                        採掘経路・共通処理テスト
 tools/                        配布生成・一括検証
```

## 検証

開発者向けの一括検証は次で実行できます。

```text
make test
```

Lua構文、全小型寸法の採掘経路、配布対象、オフライン版、文書リンク、許可されたGitHubリポジトリ以外へのURL混入を検査します。実Minecraft内での最終的な動作は、サーバ設定、チャンクロード、Create: Astral側のレシピ変更に依存するため、配置条件を手順どおり満たす必要があります。
