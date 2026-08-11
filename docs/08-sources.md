# 08. 参照資料

実装・試験時に参照する一次資料です。

- CC:Tweaked GPS API: <https://tweaked.cc/module/gps.html>
- CC:Tweaked GPS setup guide: <https://tweaked.cc/guide/gps_setup.html>
- CC:Tweaked Turtle API: <https://tweaked.cc/module/turtle.html>
- CC:Tweaked Monitor peripheral: <https://tweaked.cc/peripheral/monitor.html>
- CC:Tweaked events（`monitor_touch`、`mouse_click`、`rednet_message`）: <https://tweaked.cc/event/monitor_touch.html>
- CC:Tweaked Rednet API: <https://tweaked.cc/module/rednet.html>
- CC:Tweaked Speaker peripheral: <https://tweaked.cc/peripheral/speaker.html>
- CC:Tweaked Redstone API: <https://tweaked.cc/module/redstone.html>
- CC:Tweaked Wired Modem peripheral: <https://tweaked.cc/peripheral/modem.html>

対象 Modpack は CC: Restitched または互換実装の API 差分を確認してください。特に GPS 通信距離、HTTP 許可、燃料値、追加流体、追加インベントリ、speaker の音源、仕分け機の接続名、たいまつ・封鎖材のアイテム ID はサーバー設定で変わります。

## V3 の境界

CC Miner はチャンクをロードする仕組みを持ちません。チャンクロード状態を取得・表示・自動化せず、ロード範囲はサーバー／Modpack 管理者が別途用意します。管理者権限、認証、強い暗号化、外部仕分けプロトコルの保証も提供しません。

文書中の SAFE/BALANCED/TURBO、preflight の見積、段階停止、復旧 wizard、履歴／レポートは CC Miner のローカル状態を対象とします。Mod 追加ブロックや未知の液体の安全性を一次資料から推測せず、保護リストと小さい試験ジョブで明示してください。
