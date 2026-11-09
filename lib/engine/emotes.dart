/// 顔文字キャストの絵文字定義(iOS/Android共通で表情がすぐ分かる9種)。
/// インデックスはネットワークでもやり取りするので固定。UI表示・CPU選択で共有。
library;

/// 3x3 パレットの表情(見たらすぐ分かるもの)。
const List<String> emoteFaces = [
  '😄', // 0 うれしい / 楽しい
  '😆', // 1 大笑い
  '😎', // 2 ドヤ / 余裕
  '😏', // 3 ニヤリ
  '😲', // 4 ビックリ
  '😭', // 5 くやしい / 号泣
  '😢', // 6 しょんぼり
  '😡', // 7 おこってる
  '😅', // 8 あせり / 苦笑い
];

const int emoteCount = 9;

/// CPU が場面ごとに使う候補(表情の意味づけ)
const List<int> emoteHappy = [0, 1, 2]; // 和了
const List<int> emoteRegret = [5, 6, 8]; // 放銃
const List<int> emoteRiichi = [2, 3]; // リーチ(ドヤ・ニヤリ)
