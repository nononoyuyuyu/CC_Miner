# 1. 必要素材・中間素材・クラフト

## 最初に確認すること

Create: AstralはKubeJS等で多数のレシピを変更しています。そのため、このページでは次の二段階で素材を確定します。

1. 下表の**ComputerCraft標準レシピ基準**で、必要になる部品と最低規模を把握する。
2. 実際のCreate: Astral v2.1.5a内でREIを開き、表示されたレシピと中間素材を最終値として採用する。

バージョン違い、サーバ独自スクリプト、コンフィグ変更がある場合は、必ずゲーム内REIが優先です。

## REIで中間素材まで調べる操作

1. インベントリを開き、右側のREI検索欄に英語名の一部を入力します。
2. 対象アイテムにカーソルを合わせて `R` を押し、作成レシピを表示します。
3. レシピ内の中間素材にカーソルを合わせ、再び `R` を押します。
4. 用途を逆引きしたい場合は `U` を押します。
5. Createの加工カテゴリが表示された場合は、必要な機械、回転速度、液体、加熱条件も確認します。
6. 同じ名前のアイテムが複数MODにある場合は、詳細表示でアイテムIDを確認します。

確認対象は次です。

```text
Advanced Computer
Advanced Turtle
Diamond Pickaxe
Wireless Modem
Chest
任意: Advanced Monitor
任意: Disk Drive / Floppy Disk
```

## 1ワーカー＋1コントローラの必須完成品

| 完成品 | 数 | 使用場所 |
|---|---:|---|
| つるはし付きAdvanced Turtle | 1 | 採掘ワーカー本体 |
| Wireless Modem | 2 | ワーカー1、コントローラ1 |
| Advanced Computer | 1 | コントローラ本体 |
| Chestまたは対応する汎用インベントリ | 2 | ワーカー後方の搬出、上方の燃料 |
| 有効なタートル燃料 | 十分量 | 燃料チェスト |
| 任意: Advanced Monitor | 1ブロック以上 | 大画面表示 |

ワーカー内部のAdvanced Turtleを作る過程でもAdvanced Computerを1個使うため、Advanced Computerの総作成数は2個です。

## 標準レシピ基準の原料合計

Create: AstralのREIで変更がない場合、1ワーカー＋1コントローラの基準量は次です。搬出・燃料用チェスト2個と、Advanced Turtleの材料になるチェスト1個を含みます。

| 原料 | 基準量 | 内訳 |
|---|---:|---|
| Gold Ingot | 21 | Advanced Computer 2台分14、Advanced Turtle外装7 |
| Redstone Dust | 2 | Advanced Computer 2台分 |
| Glass Pane | 2 | Advanced Computer 2台分 |
| Stone | 16 | Wireless Modem 2個分 |
| Ender Pearl | 2 | Wireless Modem 2個分 |
| Diamond | 3 | Diamond Pickaxe |
| Wooden Planks | 26以上 | Chest 3個に24、Stick作成に2 |
| Sand | 6 | 標準のGlass Pane 1回分。16枚でき、余り14枚 |
| Cobblestone | 16 | Stoneを精錬で用意する場合 |
| 精錬燃料 | 22個の精錬に足りる量 | Glass 6、Stone 16。既に素材があれば不要 |

木材は既存の作業台を使うなら、標準換算で原木7個から板材28枚を作れば足ります。作業台も新しく作る場合は原木8個を用意すると不足しません。

## 標準レシピ基準の作成順

以下は部品関係を理解するための順序です。各段階で必ずREIのCreate: Astralレシピを確認してください。

### A. ガラス板

1. Sand 6個を精錬し、Glass 6個にします。
2. Glass 6個を横2段に並べ、Glass Pane 16枚を作ります。
3. Advanced Computer 2台に2枚使います。

### B. 石

1. Cobblestone 16個を精錬し、Stone 16個にします。
2. Wireless Modem 2個に使います。

Silk Touch、Createの石生成、別の精錬設備でStoneを直接用意できる場合、Cobblestoneと通常精錬は不要です。

### C. チェストと棒

1. Wooden Planks 8枚を外周に並べ、Chestを作ります。これを3回行います。
2. Wooden Planks 2枚を縦に並べ、Stick 4本を作ります。
3. Stick 2本をDiamond Pickaxeに使い、2本余ります。

Chest 3個の用途は次のとおりです。

- 1個: Advanced Turtleの中間素材
- 1個: 搬出チェスト
- 1個: 燃料チェスト

### D. Advanced Computerを2台

標準レシピ基準では、1台につき次を使います。

- Gold Ingot 7
- Redstone Dust 1
- Glass Pane 1

合計2台作ります。1台はワーカーの中間素材、もう1台はコントローラです。

### E. Advanced Turtle

標準レシピ基準では次を組み合わせます。

- Advanced Computer 1
- Gold Ingot 7
- Chest 1

### F. Diamond Pickaxe

- Diamond 3
- Stick 2

Advanced TurtleとDiamond Pickaxeをクラフトし、採掘アップグレードを付けます。

### G. Wireless Modemを2個

標準レシピ基準では、1個につき次を使います。

- Stone 8
- Ender Pearl 1

1個はワーカーの空いているアップグレード側へ、1個はコントローラに隣接して置きます。

### H. ワーカーの最終組み立て

1. Advanced TurtleにDiamond Pickaxeを付けます。
2. 空いている反対側にWireless Modemを付けます。
3. 完成品に、つるはしと無線モデムの両方が表示されることを確認します。

アップグレードの左右はどちらでも構いません。プログラムは接続されている無線モデムを自動検出します。

## 燃料の準備

燃料チェストには、`turtle.refuel(0)` で有効と判定されるアイテムだけを入れます。初期設定の補給目標は `12000` fuelです。

- プログラムは1個ずつ吸い込み、実際の増加量を使って自動判定します。
- Create: Astralやサーバ設定で燃焼値が変わっても、個数を固定せず目標値まで補給します。
- 非燃料を1個でも吸うと、安全のため `waiting_fuel` で停止し、そのアイテムを箱へ返します。
- 燃料箱を複数種類の倉庫や自動搬送へ接続する場合も、タートル側へ非燃料が流れないフィルタを設定します。

## 複数ワーカーの標準素材計算

ワーカー数を `N` とし、コントローラは1台を共有する場合の基準式です。

| 原料 | 計算式 |
|---|---:|
| Gold Ingot | `7 + 14 × N` |
| Redstone Dust | `1 + N` |
| Glass Pane | `1 + N` |
| Stone | `8 + 8 × N` |
| Ender Pearl | `1 + N` |
| Diamond | `3 × N` |
| Chest | `3 × N` |
| Wooden Planks | Chest用 `24 × N` ＋ Stick `2 × N` 本を作れる量 |

例としてワーカー4台なら、標準基準でGold Ingot 63、Redstone 5、Glass Pane 5、Stone 40、Ender Pearl 5、Diamond 12、Chest 12個です。

## 任意設備

### Advanced Monitor

コントローラ横へ置くと一覧画面を複製表示します。操作はコントローラ本体のキーボードで行います。複数ブロックを接続すると大画面になります。正確なレシピと1回の出力個数はREIで確認してください。

### オフライン導入用ディスク

HTTPを使えない場合は、Disk DriveとFloppy Disk、またはサーバ管理者によるコンピュータ領域へのファイル配置が必要です。1枚のディスクを各機械へ順番に移して使用できます。正確なレシピはREIで確認してください。

### Create搬出物流

搬出チェストから先は任意です。Funnel、Chute、Belt、Item Vault、フィルタ等で倉庫へ送れます。これらはCreate: Astralの進行段階とカスタムレシピの影響が大きいため、必須BOMには含めていません。
