# CC Miner V2

CC: Restitched / CC:Tweaked 向けの、復旧可能な遠隔クアリーシステムです。Advanced Mining Turtle を複数台管理し、タッチ操作、任意GPS、溶岩の自動封鎖、チャンク単位の採掘除外、自動補給・搬出、電源断復旧を一つの配布物で扱います。

![システム全体図](docs/images/system-overview.svg)

## V2.1 の主な機能

- **タッチ／クリック操作**: Advanced Monitor の `monitor_touch` とコントローラー画面のマウスクリックに対応。ワーカー選択、採掘寸法入力、数字キーパッド、チャンクマスク、GPS校正、帰還・中止・復旧まで画面内で操作できます。
- **任意GPS**: 4基以上のGPSホストを同じ配布物から構築できます。ワーカーはドック位置と正面方向を1ブロック往復で校正し、定期的な位置検証と、電源断中の移動が成功したかどうかの判定に利用します。GPSなしでも従来どおり動作します。
- **溶岩封鎖**: 進行方向の溶岩を検知すると、専用チェストから補給した固体ブロックを設置して流体を置換し、そのブロックを掘って進みます。封鎖材が少なくなると安全経路で自動帰還します。
- **チャンク除外**: タッチ画面でチャンクを個別に採掘対象外へ設定できます。GPS校正済みならワールドチャンク、未校正なら採掘原点基準の16×16区画を使用します。除外後の領域が入口から連結していないジョブは開始前に拒否されます。
- **安全な補給経路**: 除外ジョブでは許可済みチャンクのDFS親経路を使って帰還・復帰するため、補給中も除外チャンクへ入りません。
- **耐電源断状態保存**: 移動・旋回・採掘・設置の直前に保留アクションを永続化します。GPSが利用できる移動／採掘／設置は起動時に自動判定し、旋回など判定不能な操作だけ手動REHOMEを要求します。

## 対応構成

- Minecraft 1.18.2 系の CC: Restitched / CC:Tweaked 1.100.x API
- Advanced Mining Turtle + Wireless Modem
- Advanced Computer + Wireless Modem
- 任意: Advanced Monitor
- 任意: GPSホスト用 Computer + Wireless Modem ×4以上
- ドック用チェスト: 搬出（後ろ）、燃料（上）、溶岩封鎖材（右、設定で左へ変更可）

## 配置

![採掘ドック上面図](docs/images/base-layout-top.svg)

![採掘ドック側面図](docs/images/dock-side.svg)

図中の色付きブロックは、SVGのマス目と同じ整数グリッド座標へ揃えています。1マスが1ブロックです。

## オンライン導入

採掘タートル:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua worker
```

タッチコントローラー:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua controller
```

GPSホスト（4台以上でそれぞれ実行）:

```lua
wget run https://raw.githubusercontent.com/nononoyuyuyu/CC_Miner/main/install.lua gps
```

HTTPを使えない環境では、[`dist/ccminer-offline.lua`](dist/ccminer-offline.lua) と隣接する [`dist/ccminer-offline.parts/`](dist/ccminer-offline.parts/) ディレクトリをセットで各コンピューターへ転送し、`worker`、`controller`、`gps` のいずれかを指定します。分割ファイルの名前や配置は変更しないでください。

## 最初の運転

1. すべてのワーカーとコントローラーへ同じネットワークキーを設定します。
2. 搬出・燃料・封鎖材チェストを図どおりに置きます。
3. GPSを使う場合は4台以上のホストを起動し、コントローラーの **GPS CAL** を押します。タートル正面1ブロックは空けてください。
4. **NEW JOB** から幅・長さ・深さを入力します。
5. **CHUNK MASK** で除外対象を切り替えます。入口チャンクは安全上ロックされています。
6. **START** で開始します。

![チャンク除外例](docs/images/chunk-mask.svg)

## 主要コマンド

```text
ccm dashboard
ccm discover
ccm status
ccm logs
ccm update
ccm start <id> <width> <length> <depth>
ccm pause|resume|recall|service|abort|clear <id>
ccm gps <id>
ccm calibrate <id>
ccm rehome <id> RESET
```

タートルを物理的にドックへ戻した場合のローカル復旧は `ccm rehome RESET` です。GPS校正済みの場合、ドック座標と一致しなければリセットを拒否します。

## 文書

- [全体設計](docs/00-overview.md)
- [必要資材](docs/01-materials.md)
- [建築と配置](docs/02-build.md)
- [インストール](docs/03-install.md)
- [操作方法](docs/04-operation.md)
- [安全設計](docs/05-safety.md)
- [トラブルシューティング](docs/06-troubleshooting.md)
- [検証](docs/07-testing.md)
- [参照資料](docs/08-sources.md)

## 検証

リポジトリのルートで次を実行します。

```bash
python3 tools/check.py
```

Lua構文、通常蛇行経路、GPS座標変換、除外チャンクの連結性とDFS経路、状態ファイル復旧、インストーラーの収録漏れ、Markdownリンク、SVGグリッド整合、オフライン配布物を検査します。
