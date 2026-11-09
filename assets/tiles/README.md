# 牌画像(このフォルダの PNG はリポジトリに含めていません)

牌画像は [麻雀豆腐](https://majandofu.com/mahjong-images) の無料素材(個人・商用利用可、著作権は配布元に帰属)を
使っています。配布元の利用規約では素材の頒布・転載に事前許諾が必要なため、PNG はリポジトリに同梱せず、
ビルドする人が配布元から取得してここに置きます。

## 取得手順

```sh
fvm dart run tool/fetch_tiles.dart
```

配布元の zip(`https://majandofu.com/docs/mahjong-images/pai-images.zip`)をダウンロードして展開し、
アプリの命名に変換してこのフォルダに 37 ファイルを置きます。既にダウンロード済みの zip があれば
`fvm dart run tool/fetch_tiles.dart /path/to/pai-images.zip` でも可。

## ファイル名の規約(アプリ側)

| ファイル | 内容 |
|---|---|
| `man1.png` … `man9.png` | 萬子 1〜9 |
| `pin1.png` … `pin9.png` | 筒子 1〜9 |
| `sou1.png` … `sou9.png` | 索子 1〜9 |
| `ji1.png` … `ji7.png` | 字牌: 東 南 西 北 發 白 中 の順(發が 5、白が 6) |
| `aka1.png` `aka2.png` `aka3.png` | 赤5筒・赤5索・赤5萬 |

採用デザインは配布元 zip の `<名前>-66-90-l.png`(L 版・プレーン・縦向き、66x90 px)。配布元のファイル名から `-66-90-l` を外したものがアプリ側の名前。裏牌は素材に無いためアプリがコードで描画します。
