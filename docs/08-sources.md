# 8. 調査根拠と対象バージョン

調査日: **2026-08-11**

## Create: Astral

- [Create: Astral v2.1.5a — CurseForge](https://www.curseforge.com/minecraft/modpacks/create-astral/files/8611716)
- 対象ファイル: `Create-Astral-CurseForge-v2.1.5a.zip`
- Minecraft: `1.18.2`
- Loader: `Fabric`
- 公開日: `2026-08-09`

公式ページは、Create: Astralが多数のMODをカスタムレシピで統合するパックであることを明記しています。このため、ComputerCraft標準レシピだけで確定せず、ゲーム内REIを最終根拠にしています。

## CC: Restitched

- [CC: Restitched 1.100.8 for Minecraft 1.18.2 — Modrinth](https://modrinth.com/mod/cc-restitched/version/1.100.8%2B1.18.2)
- CC: RestitchedはFabric向けのComputerCraft Tweaked移植です。
- 本実装はCC:Tweaked/CC: Restitched 1.100.xで使える基本APIへ限定しています。

## ComputerCraft API・仕様

- [Turtle API](https://tweaked.cc/module/turtle.html)
- [Wireless Modem](https://tweaked.cc/peripheral/modem.html)
- [Rednet API](https://tweaked.cc/module/rednet.html)
- [Generic Inventory Peripheral](https://tweaked.cc/generic_peripheral/inventory.html)

実装で使用する主な仕様:

- タートルは16スロットを持つ
- 移動は燃料を消費する
- `turtle.refuel(0)` で、選択アイテムが燃料か消費せず検査できる
- タートルには2つのアップグレードを付けられる
- 無線モデムはRednet通信に使える
- Rednetは強固なセキュリティを保証しない
- 汎用Inventory Peripheralを使い、搬出先がインベントリか確認できる

## 正確なCreate: AstralレシピをREI最終確認とした理由

2026-07-16以降、CurseForge CDNの直接ファイル取得はAPIキー認証が必須です。

- [Introducing API Key Authentication for CurseForge File Downloads — CurseForge Blog](https://blog.curseforge.com/introducing-api-key-authentication-for-curseforge-file-downloads/)

今回の調査では公式ファイルページ、対象バージョン、構成MODとAPI仕様を確認しました。一方、認証情報を使用せずに配布ZIP内部の全KubeJSレシピを機械的に展開することは行っていません。そのため素材表は、標準レシピ基準で原料と中間素材を展開し、Create: Astral内のREI表示を最終確定値とする構成です。

## 運用上の優先順位

レシピや仕様が食い違う場合は、次の順で判断します。

1. 実際に接続するサーバのREI表示とサーバ設定
2. 同サーバのCreate: Astralバージョン
3. この手順書が対象とするv2.1.5a
4. ComputerCraft標準レシピ基準

コード側は、レシピそのものには依存しません。完成したAdvanced Turtle、Diamond Pickaxe、Wireless Modem、Advanced Computer、2つのインベントリがあれば動作します。
