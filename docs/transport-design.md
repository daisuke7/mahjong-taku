# 通信経路の設計メモ — BLE追加の検討と共通整形層

2026-09-12 の検討をまとめたもの。整形層(§4)と BLE リンク(§3)は同日に実装済み。
**BLE の実機での相互接続は未検証**(手持ち実機が Pixel 6 の1台のみ。卓役の広告開始までは
Pixel 6 で確認済み、参加側と混合構成は偽マネージャによるテストのみ)。
→ **2026-11-09 追記: iPhone 12 Pro ⇔ Pixel 6 の両方向で入室・1局完走・退出からの再接続を実機確認。**
その過程で見つかった iOS 卓・Android 卓それぞれの不具合と修正は feature-proposals.md の同日の追記を参照。
Wi-Fi Aware は参考情報のみで当面検討しない。

## 1. 方針(ユーザー決定)

- 通信経路を増やすこと自体がこのプロジェクトの実験の一部。
  **既存の経路はビルド不能になるまで保持し続ける。** 非推奨化を理由にした
  撤去・一本化は行わない。
- Wi-Fi がある場所では既存機能(WebSocket)で足りる。BLEの目的は
  **「外出先・友人宅など Wi-Fi が無い場所で、iOS/Android 混合でも成立する」**
  経路を持つこと。
- Wi-Fi Aware は新しすぎる(iOS 26+・相互接続未検証・Flutterパッケージ無し)ため
  当面検討しない。

## 2. 現状の経路

通信路は `lib/net/transport.dart` の `MessageChannel`(JSON文字列を送受)で
抽象化されており、ホストは複数経路を同時に待ち受ける。

| 経路 | 実装 | 制約 |
|---|---|---|
| WebSocket | `WsLink`(dart:io)+ 整形層 `FramedChannel`、bonsoir でmDNS発見 | 同一 Wi-Fi またはテザリングが必要 |
| 近距離P2P | `lib/net/nearby_transport.dart`(nearby_service) | iOS同士=Multipeer Connectivity(複数可)。Android同士=Wi-Fi Direct(ホストが受けられるのは1人)。**iOS⇔Android直結は不可** |

### Multipeer Connectivity の非推奨(事実確認済み)

- Apple 技術ノート TN3213 に「Xcode 27 deprecates the entire Multipeer
  Connectivity framework」と明記。フレームワーク参照も全プラットフォームで
  Deprecated 表示。移行先は Network framework(および Wi-Fi Aware)。
- 削除時期は未公表。非推奨=当面は動くが今後直らない。
- 影響: nearby_service の iOS 側はこの上に載っている。実際にビルドが通らなく
  なるのはパッケージが新Xcodeに追従しなくなった時点で、兆候は pub.dev の
  更新状況で先に分かる。**それまでは保持する(§1)。**

## 3. BLE の実現性

### 結論

可能。独自のネイティブ実装は不要。BLE は標準の GATT プロトコルなので
iOS/Android 混合で問題なく通信できる。

**実装済み(2026-09-12)**: `lib/net/ble_transport.dart`
(`BleLink` / `BleHost` / `BleBrowser` / `bleProfileFor`、UUID 3個を定数化)。
ホストは既存2経路と並列に BLE を待ち受け、参加画面には BLE の部屋が
「BLE接続(Wi-Fi不要・iPhone/Android混合可)」として並ぶ。
プラグインには PeripheralManager / CentralManager のインタフェース経由で触るので、
テスト(`test/ble_transport_test.dart`)は偽マネージャで「空中」をつないで
ロビー入室→対局開始→局面配信・切断・2人同時入室を検証している(実機不要)。
参加者→卓は write with response(1件ごとに ATT 応答を待つ=確実側)、
卓→参加者は notify(iOS の通知キュー満杯はプラグインが isReady を待って再送)。

### 構成

- 1台が「卓」(ペリフェラル=GATTサーバ)として広告し、残りがセントラルとして
  接続する星型。iOS(CoreBluetooth)も Android(BluetoothGattServer)も
  両ロール対応なので卓役はどちらのOSでも務まる。
- 対局進行は GameEngine が卓役の端末で動き、参加端末は操作を送って局面を
  受け取るだけ(既存のホスト/クライアント構造と同じ)。
- 既存経路と**並列**に待ち受ける(置き換えない)。

### パッケージ(2026-09-12 pub.dev で確認)

| パッケージ | 役割 | 状況 |
|---|---|---|
| bluetooth_low_energy 6.2.1 | セントラル+ペリフェラル両対応(iOS/Android/macOS/Windows) | 160pts・MIT。**第一候補**(1パッケージで両ロール) |
| flutter_blue_plus 2.3.12 | セントラルのみ | 最普及だがペリフェラル不可。商用は有償ライセンス |
| flutter_ble_peripheral 3.1.0 | ペリフェラルのみ(GATTサーバ・TX/RX特性) | flutter_blue_plus と組み合わせる案。API差の吸収が余計 |

独自実装(MethodChannel で CoreBluetooth / Android BLE を直叩き)が要るのは
上記が壊れた・保守停止した場合のみ。

### 信頼性(パケット取りこぼしについて)

- 接続後の GATT はリンク層に CRC と再送(ACK)があり、**接続が生きている限り
  順序と欠落なしが保証される**(TCPと同じ感覚)。シーケンス番号・抜け検出・
  再送要求を自作する必要はない。
- **唯一の取りこぼしポイントは送信側の詰まり。** 通知の送信キューが満杯の
  ときに送ると黙って捨てられる。iOS は送信関数が失敗を返し「準備完了」
  イベントを待つ、Android は「送信完了」コールバックを待ってから次を送る。
  → **1チャンク送る→完了を待つ→次を送る、の直列化を守れば発生しない。**
- 接続が切れると組み立て途中のメッセージは不完全になる → 捨てて、
  再接続時にホストが現在の局面を送り直す(既存の再接続経路を流用)。

### UUID

- 独自サービスは **128bit UUID を自前で生成して固定する**だけ。登録・申請は
  不要(16bit の短い UUID は Bluetooth SIG 割り当てで会員登録が要るため使わない)。
- 決めるのは3つ: サービスUUID(広告に載せ、参加側のスキャン絞り込みに使う)、
  TX特性(通知: 卓→参加者、局面配信)、RX特性(書き込み: 参加者→卓、操作)。
- **一度決めたら変えない**(UUID=バージョン間互換そのもの)。プロトコル改定は
  メッセージ内のバージョン番号で扱う。iOS は GATT 構成をキャッシュするので、
  UUID据え置きで特性の並びを変えると混乱し得る。

### 制約・注意

- iOS の MTU は実質 185 バイト程度 → 分割が必要(§4)。
- BLE の実効速度は片方向数KB/s → 局面JSON(数KB)は圧縮して流す(§4)。
- iOS の広告データは名前+サービスUUIDのみ(約10バイト)。詳細は接続後に交換。
- 対局中はフォアグラウンド維持が必須(wakelock_plus は導入済み)。
- 権限: Android 12+ は BLUETOOTH_SCAN/CONNECT/ADVERTISE、iOS は
  NSBluetoothAlwaysUsageDescription。
- **BLE はシミュレータで動かない → 検証は全て実機。** iPhone実機と Pixel 6 が
  揃えば「iOS卓×Android参加」「Android卓×iOS参加」の1対1を確認できる。
  3人以上の同時接続は台数が揃うまで未検証扱い(2026-09-15時点で手持ちの実機は Pixel 6 のみ)。
- Android ベンダーごとの癖(Pixel は素直)は実使用でしか分からない。

## 4. 共通整形層(分割・圧縮)— 全経路が必ず通る1枚の層

**実装済み(2026-09-12)**: `lib/net/framing.dart`(`LinkProfile` / `ByteLink` /
`encodeFrames` / `FrameAssembler` / `FramedChannel` / テスト用 `InMemoryLink`)。
テストは `test/framing_test.dart`。既存2経路の乗せ替えも完了(下記「既存経路の改修」)。

**方針(ユーザー決定): 見通しを良くするため、どの通信経路でも整形層を通す。**
ただし「圧縮するか」「分割が必要か」は整形層が決めるのではなく、
**下の通信経路(リンク)が自分の性質として宣言する**。整形層は宣言に従って
動くだけで、経路ごとの分岐を持たない。

```
アプリ ─ MessageChannel(JSON文字列)  ← 上位(host/client)から見えるのはこれだけ
           │
        整形層(1実装のみ): [圧縮] → [分割] / 再結合 → [伸長]
           │  ※ [ ] の工程はリンクの宣言で ON/OFF
        バイトリンク(経路ごとに1実装) + 能力宣言
           ├ WebSocket リンク   … 上限なし・圧縮なし
           ├ 近距離P2P リンク    … 上限なし・圧縮なし(テキストのみ)
           ├ BLE リンク          … 上限 = 交渉したMTU・圧縮あり
           └ プロセス内リンク(テスト用) … 任意の宣言を注入できる
```

### リンクの能力宣言

| 宣言項目 | 意味 | 整形層の挙動 |
|---|---|---|
| 1件あたりの上限サイズ(無制限も可) | そのリンクが一度に運べるバイト数 | 上限ありなら分割、無制限なら1チャンク |
| 圧縮の要否 | 帯域が細い経路か | 要なら zlib 圧縮/伸長、不要なら素通し |
| バイナリ可否 | テキストしか運べない経路か | 不可なら base64 で包む |

ヘッダ(メッセージID・総チャンク数・通し番号・圧縮フラグ)は**全経路で常に付く**。
1チャンクのときも付けることで、受け側の再結合器は経路を知らずに同じ道を通る。
オーバーヘッドは数バイトで無視できる。

### 構成要素

- **エンコード(純粋関数)**: 文字列 + 能力宣言 → チャンク列。
- **再結合器(純粋な状態機械)**: チャンクを受け取るたびに状態を進め、揃ったら
  文字列を返す。ヘッダの圧縮フラグで伸長の要否を判断(受け側は宣言に依存しない)。
  切断通知で未完成分を捨てる。
- **アダプタ(1実装)**: バイトリンクを受け取り `MessageChannel` に見せる。
  送信は直列化し「1件送って完了を待つ」を全経路で守る。

### 既存経路の改修(この方針の帰結・実施済み)

以前は `WsChannel` と近距離P2Pのチャネルがそれぞれ直接 `MessageChannel` を
実装していた。これを**バイトリンク実装に格下げ**し、`MessageChannel` は
アダプタ経由でのみ生成する形に改めた。

| 対象 | 変更 |
|---|---|
| `WsLink`(lib/net/transport.dart、旧 `WsChannel`) | WebSocket をバイトリンク化(バイナリフレーム使用)。宣言: 上限なし・圧縮なし・バイナリ可 |
| `NearbyLink`(lib/net/nearby_transport.dart、旧 `NearbyMessageChannel`) | nearby_service のテキスト送信をバイトリンク化。宣言: 上限なし・圧縮なし・テキストのみ |
| `InMemoryChannel.pair()`(テスト用) | プロセス内バイトリンク+整形層の組に置き換え、宣言を注入可能。既存のホスト/クライアントのテストはすべて整形層を通って走る |
| host.dart / client.dart | 経路ごとの生成箇所で「リンク → アダプタ」に差し替えただけ。メッセージ処理は不変 |

ワイヤ上の形式(ヘッダ付与)が変わったため、**改修前後のアプリ同士は通信できない**。
全端末を同時に更新する前提(個人利用)なので許容し、`protocolVersion`(=2)を
hello に載せてロビーで検出し、違えば「アプリのバージョンが違います」で弾く。

整形層の `close()` は送信待ちを流し切ってから閉じる(kick の最後の1通を落とさない)。

### テストで固めたこと(実機不要、test/framing_test.dart)

- 宣言の全組み合わせ(上限あり/なし × 圧縮あり/なし × バイナリ/テキスト)での
  ラウンドトリップ(1文字〜数十KB、マルチバイト含む)
- 上限 20/32/185・無制限 × 圧縮あり/なし × バイナリ/テキストの全組み合わせで境界がずれないこと(複数メッセージ連続)
- 途中切断で未完成分が捨てられ、次のメッセージが正常に組み上がること
- 「キュー満杯だと黙って捨てる」偽リンクで、直列送信を守らないと落ちるテスト
- 既存のホスト/クライアント一式のテストが、プロセス内リンク経由で従来どおり通ること
  (=改修の回帰チェック)。BLE相当(上限185・圧縮あり)の宣言でもロビー→対局開始が通る
- バージョン違いの hello が弾かれること
- 局面相当JSONでの圧縮率の実測例(1局面 622B→352B、8局面連結 4904B→389B。アサーションは 2/3未満・1/4未満)

## 5. Wi-Fi Aware(参考・当面検討しない)

- 規格(Wi-Fi Alliance NAN)自体が2段構え: **発見**(同期した発見ウィンドウで
  publish/subscribe、サービス名マッチング、付帯データ、接続前の小メッセージ
  =BLEに似た部分)と**データパス**(NDP上に **IPv6リンクローカル**=通常のTCP/UDP)。
  Android でも同じ構造。
- iOS(26+、iPhone 12以降)は Network framework の NWConnection で包み、IPアドレスや
  ソケットを直接見せない → dart:io への橋渡しに Swift 側の中継が要る。
  Android(8.0+、チップ依存)は Network と IPv6 リンクローカルが得られ、通常の
  ソケットを開ける。
- 規格上 IPv6 のみ(既存の WebSocket 接続先解決は IPv4 優先なので、乗せるなら要変更)。
- ペアリングは Wi-Fi Aware 4.0 の機能で Android 16 / iOS 26 から。相互接続には
  この版の一致が前提で、実機での相互接続報告は少ない。
- Flutter に両OS対応の成熟パッケージは無く、両OS分のネイティブ実装が必要。
- 位置づけ: 接続後は普通のIPリンクになるため BLE より筋は良いが、対応端末の
  下限と未成熟さから「1〜2年後にパッケージが整えば候補」。

## 6. 着手する場合の順序(未着手)

1. ~~§4 の整形層とプロセス内リンクをテスト付きで実装~~(済 2026-09-12)。
2. ~~既存2経路をバイトリンクに改修し、host/client をアダプタ経由に差し替え~~(済)。
   実機確認済(2026-09-12): iOSシミュレータ⇔Pixel 6 実機で、Pixel→iOSホスト入室・
   iOS→Pixelホスト入室・対局開始・配牌(GameView)配信の両方向が整形層経由で動作。
   このとき使っていた Wi-Fi はたまたま端末間隔離(ping不通)の特殊な環境だったため、
   USB の adb reverse/forward で 127.0.0.1 をポート転送して接続した(アプリの
   WebSocket 経路そのものは本番と同じ)。普段の環境では端末同士が直接見えるので
   通常どおり mDNS / IP 入力で接続できる。
   自動操作用に `--dart-define=AUTO_HOST=true` / `AUTO_JOIN=true` /
   `AUTO_JOIN_IP=<host>` を追加(home_screen で読み取り、join_screen に autoConnectHost として渡す)。
3. ~~bluetooth_low_energy で BLE バイトリンクを実装~~(済 2026-09-12。権限設定込み)。
4. ~~ホストの待ち受けに BLE を追加、参加画面に BLE 部屋を表示~~(済)。
5. **実機検証(未実施・実機2台以上が揃ってから)**: iOS卓×Android参加 /
   Android卓×iOS参加 で接続+1局、切断→再接続、テザリング(WebSocket)との共存。
   Pixel 6 単体では卓役の GATT サービス登録と広告開始まで確認済み。

## 出典

- TN3213: Moving from Multipeer Connectivity to Network framework
  https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- Multipeer Connectivity(Deprecated 表示)
  https://developer.apple.com/documentation/multipeerconnectivity
- pub.dev: bluetooth_low_energy / flutter_blue_plus / flutter_ble_peripheral(2026-09-12 時点)
