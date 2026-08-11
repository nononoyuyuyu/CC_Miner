# Changelog

## 4.0.0

- 通常ボタンを青地の白文字へ変更し、左右に色付きの余白を追加しました。黒い画面と文字が同化しにくくなります。
- 状態通知のたびに燃料判定でインベントリ選択枠が動いていた問題を修正しました。高さに余裕のあるモニターでは、ボタンと一覧項目を上下にも離して表示します。
- 帰還時の持ち物整理を修正し、穴埋め材とたいまつを必要数だけ残して余剰分を搬出するようにしました。専用枠が空の場合にも材料をまとめます。
- 管理画面の `MORE → ITEMS` から、現在の持ち物を見ながら自動排出の対象を選べるようにしました。鉱石・原石・燃料・たいまつは引き続き保護されます。
- よく使う操作だけを最初の画面に残し、低頻度の操作を `MORE` にまとめました。モニター用の配色も明るくしました。

- 初回のworker/controller/gpsインストールも、1 MiBのCCコンピューターへ確実に収まる検証付き一ファイル方式へ変更。途中停止時は同じ初回コマンドで再開し、完了後にセットアップを自動起動
- CC:Tweakedの標準端末で日本語が`?`になる問題を防ぐため、ゲーム内セットアップ画面をASCIIだけの短い英語へ統一。詳しい日本語説明はHTMLマニュアルに維持
- 遠隔コンソールを追加。新規セットアップは同じnetworkKeyのコントローラーへ読み取りallowlistだけを既定許可し、既存設定の更新時は自動で有効化しない。任意シェルは既定OFFかつcontrollerId固定必須。採掘停止・ドック確認、セッション時間／出力上限／監査件数を実行時に適用
- キューのバックグラウンド開始が画面編集中のdraftを消し、controller.assembled.luaでnil参照になる問題を修正。編集中データの退避復元と描画時の安全復帰を追加
- エラー詳細が自動で全画面を占有し続ける動作を廃止。赤い固定通知と任意のLAST ERR表示へ変更し、通信待ち／GPS待ちでCtrl+Tが飲み込まれる問題を修正
- 通常の1台採掘がドック設定の向き情報だけでグループ割当と誤判定され、GPSなし環境で拒否される問題を修正。GPSは絶対Y座標・ワールド範囲・複数ワーカー時のみ必須
- START拒否理由をOK操作まで消えない全画面表示に変更し、LAST ERRから再確認可能にした。START直前の再プレフライトとGPS校正／現在位置の個別確認も追加
- 1台だけの通常採掘にグループ用IDを誤送信してワーカーがSTARTを安全拒否する問題と、拒否後の仮予約が残って次のSTARTが灰色になる問題を修正
- 古いCC環境でHTTP取得はバイナリ、保存はテキストになっていた不一致を解消。十分な空き容量があるのに `common.lua` の保存確認が数バイト差で失敗する問題を修正
- 通常更新で一時コピーの空き容量が足りず、`common.lua` が途中までしか書けない場合を検出。必要量・書込量を表示し、省容量更新へ自動で切り替えるよう修正
- 右側のピッケルを残し、持ち物1番の無線モデムを `turtle.equipLeft()` で左側へ装備・確認する手順を初心者向けマニュアルへ追加
- マニュアルを初心者向けの手順書として全面改稿。読む順番を「ブロック配置→プログラム導入→小規模試運転」に変更し、独立したクイックスタートと設定項目別の説明書を追加
- コマンド欄の文字色、固定幅の帰還図、モバイル表示を修正。すべてのブロック面配置を「上面／左面・正面・右面／背面・底面」の共通3×3図に統一
- worker、controller、checkpoint、preflight、dock、group等を本文では日本語中心に言い換え、実画面で必要な場合だけ英語を併記

- 日本語マニュアルを `docs/index.html` 入口の静的 HTML へ全面再構成。共通目次、パンくず、前後リンク、モバイル／印刷／キーボード／high contrast／`prefers-reduced-motion` に対応
- GPS 塔、座標軸、ワーカー装備、単一／複数 bay、controller、chunk grid、DFS 帰還経路を semantic HTML + CSS grid/flex の図へ移行（画像・SVG・canvas なし）
- P0/P1/P2、group partition、discard policy、throughput、絶対 BOTTOM Y、chunk load 非対応、low-space update の運用手順を追加
- V4.0.0 / schema 4 の role 別オンライン・オフライン配布（worker／controller／gps loader と 2 桁連番・12,000 B 以下の各 parts、互換 dispatcher）、loader の parts 自動削除、role／config.role 検証、オンライン role 自動判定 update、`version/role/next/phase` marker と `.tmp`／`.bak` atomic fallback 再開を追記
- controller CLI の `dock/bay/group register`、workerBays／workerDocks map、group-job touch 画面、bay chunk/floor/orientation/forward-footprint preflight、own assignment の経路分離、REASSIGN resume を追記
- `optimizedWalk` は計算結果・見積互換として保持し、runtime の実行順は復旧可能な DFS `walk`、補給・帰還の `shortestServiceRoute` だけ BFS とする境界を明記
- 旧 Markdown 文書と `docs/images/*.svg` を削除し、README は GitHub landing と HTML マニュアルへのリンクに整理

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
- 通常 serpentine の高速化、除外時 DFS／グラフ計算の高速化、adaptive service、render cache、stack compression を追加。`optimizedWalk` は物理実行順には採用しない
- ACK/status の保持と再試行、補助 journal（maxEntries／size rotate／checkpoint）を追加。journal は state.db の代替ではない
- チャンクロード状態の取得・表示・自動化、管理者機能、単一フットプリントの自動分割は提供しない
- setup が生成する startup marker の改行欠落による line 4 構文エラーを修正し、回帰テストを追加
- preflight で LIGHT OFF、local GPS、十分な fuel を不要な warning ではなく OK と表示
- controller DB の leases alias／永続化 draft と worker chunk plan の共有 table 参照で CC serializer が失敗する問題を修正し、CC 互換回帰テストを追加

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
