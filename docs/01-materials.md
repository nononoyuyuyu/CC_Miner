# 01. 必要資材（V3）

数量はワーカー 1 台あたりの目安です。Modpack のレシピ、燃料値、インベントリ容量、仕分け機の仕様で変わるため、preflight の見積と小さい試験ジョブを優先してください。

## 最小構成

| 用途 | 数量 | 内容・条件 |
|---|---:|---|
| 採掘 | 1 以上 | Advanced Mining Turtle |
| ワーカー通信 | ワーカーごとに 1 | Wireless Modem |
| 管理 | 1 | Advanced Computer |
| 管理通信 | 1 | Wireless Modem |
| 搬出 | ワーカーごとに 1 | Chest / Barrel 等。空き容量を確保 |
| 燃料 | ワーカーごとに 1 | Chest / Barrel 等。燃料以外を混ぜない |
| Seal 材 | ワーカーごとに 1 | 設定した側の Chest / Barrel。既定は右 |
| 封鎖ブロック | 継続補給 | 設定済みの固体・非重力・非燃焼ブロック |
| Torch 材 | ジョブ・間隔次第 | 専用チェスト（seal 側の反対。既定は左）に通常 Torch / Soul Torch など設定したアイテム |

Seal 材の既定候補は Cobblestone、Cobbled Deepslate、Stone、Netherrack、Dirt です。Seal チェストと Torch チェストは必ず左右を分け、seal 側の反対側へ置きます（既定 seal=右／torch=左）。砂、砂利、TNT、バケツ、可燃ブロック、液体、貴重ブロックは登録しないでください。

採掘石の再利用を有効にすると、許可リストに一致する採掘物を搬出へ送らず、封鎖材スロットへ保持します。保持上限を超えた分は搬出へ回すか、設定に従って待機します。再利用はブロック名の一致に依存し、圧縮レシピや Mod 追加ブロックを自動推測しません。

## タッチ・通知・仕分け（任意）

| 用途 | 数量 | 内容・制約 |
|---|---:|---|
| 表示・タッチ | 1 以上 | Advanced Monitor。端末の `mouse_click` も利用可 |
| 音声通知 | 0 または 1 | speaker peripheral。音量・音源は設定依存 |
| レッドストーン通知 | 0 または 1 | redstone 接続面。完了／停止／待機の出力のみ |
| 有線仕分け | 0 または必要数 | Controller の Wired Modem + source inventory と valuable／bulk／seal の送出先 |

仕分け連携を使わなくても背面の搬出チェストだけで運転できます。controller は source から各送出先へ push し、満杯時は残留して次 tick に再試行します。worker の `waiting_output` とは直結しません。通知装置は命令の認証や採掘許可には使われません。

## GPS 構成

| 用途 | 数量 | 内容 |
|---|---:|---|
| GPS ホスト | 4 以上 | Computer / Advanced Computer |
| GPS 通信 | ホストごとに 1 | Wireless Modem |

4 台を同一平面に並べず、高さを変えて立体配置します。登録するのはコンピューター本体ではなく、距離測定に使われる無線モデムブロックのワールド座標です。GPS は任意ですが、ワールドチャンク表示、GPS 必須設定、電源断移動の自動解決に必要です。GPS がない環境では相対チャンクと手動復旧を使用します。

![GPS ホストの立体配置例](images/gps-layout.svg)

## ドック占有範囲

ワーカー 1 台につき、少なくとも次を空けます。

- タートル本体 1 ブロックと、正面の採掘入口
- 後ろの搬出チェスト、上の燃料チェスト
- Seal チェストと、seal 側の反対側（既定左）の専用 Torch チェスト
- 通常の 1×1 坑道で左右 niche を使える空間。両側が塞がる場合は安全停止
- GPS CAL 用に正面 1 ブロックを一時的に空けられること
- speaker、redstone、Wired Modem を追加する場合はケーブルと保守用の足場

## 事前に決める設定

- 運転プロファイル: SAFE（予備多め・照明優先）、BALANCED（既定）、TURBO（補給回数を抑える）
- `lavaMode` と `waterMode`: `seal` または `stop`（水は環境により `ignore` も可）
- たいまつの種類、使用スロット、専用チェスト側。SAFE は間隔最大 8、BALANCED は設定値（既定 10）、TURBO は 12。1×1 坑道では左右 niche を優先し、custom floor fallback は任意・失敗非致命
- 封鎖材の種類、保持上限、採掘石の再利用、予約スロット
- 有線仕分け先、speaker、redstone 面、通知イベント

preflight では seal／torch／燃料などの stock 不足は「補給前提」の warning として示し、補給を前提に続行できます。offline、invalid、connectivity、capability、lease は fatal で開始できません。管理者権限やサーバー側のチャンクロード機能は資材に含まれません。
