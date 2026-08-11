# Changelog

## 3.0.0

- 1 タイル = 1 チャンクのタッチ式グリッドを追加。個別、RECT（二点矩形）、ALL、CLEAR、INVERT、入口固定、進捗色を提供
- 初期状態と ALL は全採掘、CLEAR は入口以外を解除、RECT は指定矩形だけを採掘対象にする仕様へ整理（部分セルなし）
- 採掘前 preflight と見積を追加。stock 不足は補給前提 warning、offline／invalid／connectivity／capability／lease は fatal として開始を止める
- SAFE / BALANCED / TURBO プロファイル、ジョブプリセット、キュー、ジョブ履歴、完了レポートを追加
- 単一フットプリントを複数 worker へ分割する機能は安全上無効化。指定 worker ごとの非重複な独立 queue job を dashboard 稼働中に並列 dispatch
- world queue は active／queued 範囲の重複を拒否し、local queue は指定 worker ごとの順番で処理
- たいまつ自動照明を追加。seal 材チェストの反対側に専用 torch チェスト（既定 seal=右／torch=左）を置き、1×1 坑道の左右 niche を使用。両側不可は安全停止、custom floor fallback は任意・非致命
- 採掘石の封鎖材再利用、水／溶岩封鎖、連続封鎖上限、段階停止、復旧 wizard、アンロード中断からの再ロード復帰を追加
- speaker／redstone 通知と、controller の任意 Wired Modem source→valuable／bulk／seal 仕分けを追加。満杯時は残留して次 tick に再試行
- 通常 serpentine の高速化、除外時 DFS／グラフ計算の高速化、adaptive service、render cache、stack compression を追加。未使用の optimizedWalk は採用しない
- ACK/status の保持と再試行、補助 journal（maxEntries／size rotate／checkpoint）を追加。journal は state.db の代替ではない
- チャンクロード状態の取得・表示・自動化、管理者機能、単一フットプリントの自動分割は提供しない

## 2.1.0

- Advanced Monitor と端末マウスのタッチ／クリック UI を追加
- 数字キーパッド付き採掘ジョブ作成とチャンク除外マスクを追加
- GPS ホスト役割、ワーカー GPS 校正、定期位置検証、電源断移動判定を追加
- 溶岩への固体ブロック設置、自動封鎖材補給、封鎖材不足時の安全帰還を追加
- 除外チャンクを避ける連結 DFS 経路と補給時の親経路帰還を追加
- ドック図のブロックを整数グリッドへ再配置し、SVG 座標検査を追加
- スキーマを 3、バージョンを 2.1.0 へ更新

## 2.0.0

- 自律クアリー、遠隔コントローラー、自動搬出・燃料補給、状態復旧、オンライン／オフライン導入を初回実装
