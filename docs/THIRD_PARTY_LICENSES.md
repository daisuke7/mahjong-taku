# 第三者素材・データのライセンス表示

本リポジトリとアプリが利用している第三者の素材・データと、その許諾条件。

## Mリーグ牌譜データベース(konoui/m-league-game-db)

- 配布元: https://github.com/konoui/m-league-game-db
- 利用箇所: アプリが実行時に配布元リリースの `database.zip` をダウンロードして読む。
  本リポジトリにはデータ本体を同梱せず、スキーマのスナップショット
  [paifu-db-schema.sql](paifu-db-schema.sql) と、列の意味のメモ [paifu-db-notes.md](paifu-db-notes.md) を置く。
- ライセンス: MIT License(配布元 LICENSE より。以下は MIT License の全文)

```
MIT License

Copyright (c) 2025 konoui

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 牌画像(麻雀豆腐)

- 配布元: https://majandofu.com/mahjong-images
- 利用箇所: `assets/tiles/`(アプリ内の牌の描画)。**PNG はリポジトリに同梱しない**。ビルドする人が
  `tool/fetch_tiles.dart` で配布元から取得して配置する(手順: assets/tiles/README.md)。
- 条件(2026-11-09 確認): 配布ページに「個人・商用 ご自由にご利用いただけます」「画像の加工は可能です」
  「著作権は放棄致しません」「出典表示をして頂けると幸いです」。一方、利用規約(majandofu.com/terms)は
  「コンテンツ等の複製、改変、頒布、転載、再利用、使用許諾または営利を目的とする使用等の行為は、当サイトによる
  事前許諾がない限り禁止します」。アプリへの組み込み利用は明示的に可、素材ファイル自体の頒布(リポジトリ同梱)は
  事前許諾が要ると読めるため同梱を見送った。公開後に編集部へ「公開中のリポジトリに直接同梱(再配布)したい」旨を
  問い合わせ、許諾が得られれば同梱に戻す予定(ユーザー決定 2026-11-09)。
- クレジット: アプリ内のガイドとホーム画面、README に表示(配布元は任意としているが表示する)。

## アプリアイコン(AI 生成)

- `assets/icon/` の 4 点と、そこから生成した iOS / Android 用アイコン。
- 生成: Muse(Meta AI)。コンセプト(卓=ネットワーク、データ感のある「中」の牌)の提示と案の採否は作者。
- 判断(2026-11-09): Meta AI 利用規約(日本語版、2026-05-13 施行)に生成物の商用利用・再配布を禁じる
  条項は見当たらず、権利帰属の明文も無い。一般的なモチーフで特定の既存作品に依拠していないため、
  オープンソースとして同梱して公開する分には問題ないと作者が判断。著作物性(日本法)は確実ではないので、
  第三者による類似利用を止める手段としては期待しない。出所表示として README に 1 行記載。

## Mリーグ競技規定(m-league.jp)

- 参照元: https://m-league.jp/about/
- 利用箇所: ルール実装の照合。条文を引用した照合記録(docs/mleague-rule-review.md)は規定本文の
  引用を多く含むため公開対象外とし、リポジトリには含めていない(2026-11-09 決定)。レビュー用の
  参照ファイルは条番号と要旨のみ(2026-09-15 決定、[failure-log.md](failure-log.md) 参照)。
