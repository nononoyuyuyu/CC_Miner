# 06. トラブルシューティング（V3）

最初にダッシュボードの worker 状態、preflight の項目、`ccm logs`、job report を確認します。停止理由が分からないまま `REHOME RESET` を実行すると復旧情報を失うため、wizard の案内を優先してください。

## worker が見つからない／offline

- worker と controller のネットワークキーが一致している
- Wireless Modem を装着し、別ディメンション・遮蔽・通信距離を確認
- `ccm discover` を実行し、worker 側のログでモデム起動を確認
- controller の worker timeout が短すぎない
- Wired Modem だけを接続していない（遠隔制御は Wireless Modem が必要）

チャンクロード状態を CC Miner から確認することはできません。必要な領域がロードされているかは、サーバー／Modpack の設定と管理者の手順で確認してください。

## モニター／チャンクグリッドを操作できない

- Advanced Monitor を使用し、`ccm setup controller` でタッチを有効にする
- グリッドは 1 タイル = 1 チャンク。部分セルはなく、入口は固定
- 初期状態と **ALL** は全採掘、**CLEAR** は入口以外解除、**RECT** は二点矩形だけ採掘、**INVERT** は入口固定で反転
- 小さいモニターでは行やボタンが省略されるため端末画面を使う
- GPS 未校正では相対グリッドのみ。world grid と `targetY` を選ぶには GPS CAL が必要

## preflight が失敗する

| 表示 | 種別 | 確認 |
|---|---|---|
| `offline` / `invalid` | fatal | 接続、入力値、worker ID、設定形式を確認 |
| `connectivity` | fatal | 入口から許可チャンクが連結するよう grid を選び直す |
| `capability` / `lease` | fatal | worker の対応機能と active／queued job の占有を確認 |
| `gps_required` | fatal | 4 台以上の GPS、モデム座標、通信距離、校正を確認 |
| `stock` / `fuel` / `seal` / `torch` | warning | 補給を前提にチェストと予約 slot を補充 |
| `overlap` | fatal | world active／queued job の X/Z 範囲を変える。local は指定 worker ごとの順番 |
| `assignment` | fatal | 単一 footprint の自動分割は不可。非重複な独立 job を worker ごとに登録 |

## 見積と実績が大きく違う

見積はセル数・経路・設定済みの補給だけを前提にします。水／溶岩の封鎖、保護ブロック、Mod 追加ブロック、エンティティ、仕分け機の待ち時間は含まれません。小さい範囲で BALANCED を実行し、report の fuel・seal・torch・補給回数を基に SAFE の margin を調整してください。

## `waiting_output` / 有線仕分けの誤解

controller の Wired Modem 仕分けは source inventory から valuable／bulk／seal へ push します。送出先が満杯・切断中なら残留して次 tick に再試行します。これは worker の `waiting_output` とは直結しません。worker が `waiting_output` になった場合だけ、背面搬出チェストの空きと worker 側の搬出経路を確認してください。

## `waiting_fuel`

上の燃料チェストがない、空、異物入り、燃料値が Modpack と合わない状態です。燃料だけを補充し、preflight の帰還距離＋profile margin を満たして RESUME。fuel safety は TURBO でも下がりません。

## `waiting_seal` / 水・溶岩で停止

既定の seal 側は右です。設定した seal 材チェストへ固体ブロックを補充し、反対側（既定左）の専用 torch チェストと混同しないでください。砂・砂利・可燃物・液体は拒否されます。水の連続封鎖上限、溶岩の封鎖失敗、未知の流体は `stop` と同じ安全停止です。

## `waiting_torch` / 暗所

SAFE の torch 間隔は最大 8、BALANCED は設定値（既定 10）、TURBO は 12。通常 1×1 坑道の左右 niche に保護／容器／液体／重力ブロックを避けて置きます。両側が塞がっている、専用 torch チェストが空、指定スロットが空、設置面が不適切な場合は安全停止します。custom floor fallback を設定している場合、その失敗は非致命です。

## 段階停止・アンロード後に再開しない

STOP は `pause_now`、行末、層末、帰還、中止のいずれかです。`stagedStop` が残っている間は、指定した境界に到達するまで通常採掘を続けます。搬出・燃料・seal・torch 補給中に停止した場合は `waiting_*` と checkpoint が残るため、チェストの投入結果と在庫を確認してから RESUME します。再ロード後は保存済み state から再開しますが、外部装置の二重投入を保証するものではありません。

## `recovery_required` / 復旧 wizard

1. wizard の最後の確定座標、保留操作、停止理由を記録します。
2. タートルを手動で動かした可能性がある場合は電源を切り、ドックへ戻して採掘方向を合わせます。
3. GPS 校正済みなら `ccm gps <id>` で fix を確認します。旋回中・fix 不能は自動解決しません。
4. 画面の **REHOME RESET** を確認してから実行し、GPS CAL が必要なら再校正します。
5. job を保持して RESUME するか、ABORT して report を保存します。

`REHOME RESET` は進行中 job を消去します。状態ファイルが壊れて `state_corrupt` になった場合は `.bak` と journal を保存してから、管理者またはバックアップ手順で復旧してください。

## `GPS drift` / `Boot GPS mismatch`

校正後にドックを移設した、タートルを手動移動した、GPS ホスト座標が間違っている可能性があります。元のドックへ戻して REHOME、または job を中止して setup で校正を消去し、新ドックで GPS CAL をやり直します。`targetY` は GPS world のみで使用します。

## 履歴・レポート・通知

履歴は job の要約です。report の実装 fields は `jobId`、`reason`、`time`、`elapsed`、`progress`、`stats`、`estimate`／`actual`、material counts。speaker が鳴らない場合は peripheral 名・音量・イベントを、redstone が出ない場合は接続面と設定を確認します。通知は診断用で、未通知でも採掘状態の正本は state.db です。
