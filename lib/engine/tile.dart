/// 牌種は 0..33 の整数で表す。
/// 0-8: 萬子1-9 / 9-17: 筒子1-9 / 18-26: 索子1-9
/// 27-33: 東 南 西 北 白 發 中
/// 34-36: 赤5萬・赤5筒・赤5索(Mリーグルール。判定時は normalize で通常牌に潰す)
library;

class Tile {
  static const int east = 27;
  static const int south = 28;
  static const int west = 29;
  static const int north = 30;
  static const int haku = 31;
  static const int hatsu = 32;
  static const int chun = 33;

  static const int red5m = 34;
  static const int red5p = 35;
  static const int red5s = 36;

  static const int kindCount = 34;

  static bool isRed(int t) => t >= red5m;

  /// 赤牌を通常牌種(0..33)に正規化する
  static int normalize(int t) => switch (t) {
    red5m => 4, // 5萬
    red5p => 13, // 5筒
    red5s => 22, // 5索
    _ => t,
  };

  /// 手牌ソート用(赤は同じ5の直後に並ぶ)
  static int sortKey(int t) => normalize(t) * 2 + (isRed(t) ? 1 : 0);

  /// スート: 0=萬 1=筒 2=索 3=字
  static int suit(int t) {
    final n = normalize(t);
    return n >= 27 ? 3 : n ~/ 9;
  }

  /// 数牌の数字 1..9(字牌は 0)
  static int number(int t) {
    final n = normalize(t);
    return n >= 27 ? 0 : n % 9 + 1;
  }

  static bool isHonor(int t) => normalize(t) >= 27;

  static bool isWind(int t) => t >= east && t <= north;

  static bool isDragon(int t) => t >= haku && t <= chun;

  static bool isTerminal(int t) =>
      !isHonor(t) && (number(t) == 1 || number(t) == 9);

  static bool isTerminalOrHonor(int t) => isHonor(t) || isTerminal(t);

  static bool isSimple(int t) => !isTerminalOrHonor(t);

  /// ドラ表示牌 → ドラ(表示牌が赤でも通常の次牌)
  static int doraFromIndicator(int indicator) {
    final ind = normalize(indicator);
    if (ind < 27) {
      final base = (ind ~/ 9) * 9;
      return base + (ind - base + 1) % 9;
    }
    if (ind >= east && ind <= north) {
      return east + (ind - east + 1) % 4;
    }
    return haku + (ind - haku + 1) % 3;
  }

  /// ドラ表示牌のリストから、ドラの牌種集合(正規化済)を作る
  static Set<int> doraKinds(List<int> indicators) => {
    for (final ind in indicators) doraFromIndicator(ind),
  };

  static const List<String> _honorNames = ['東', '南', '西', '北', '白', '發', '中'];

  static String name(int t) {
    final n = normalize(t);
    if (n >= 27) return _honorNames[n - 27];
    const suits = ['m', 'p', 's'];
    return '${isRed(t) ? 'r' : ''}${number(t)}${suits[suit(t)]}';
  }

  /// 表示用(1萬 / 2筒 / 3索 / 東)
  static String displayName(int t) {
    final n = normalize(t);
    if (n >= 27) return _honorNames[n - 27];
    const suits = ['萬', '筒', '索'];
    return '${isRed(t) ? '赤' : ''}${number(t)}${suits[suit(t)]}';
  }

  /// 全136枚の山を生成(Mリーグルール: 各色の5を1枚ずつ赤に差し替え)
  static List<int> fullWall() {
    final wall = <int>[];
    for (var k = 0; k < kindCount; k++) {
      for (var i = 0; i < 4; i++) {
        wall.add(k);
      }
    }
    wall[wall.indexOf(4)] = red5m;
    wall[wall.indexOf(13)] = red5p;
    wall[wall.indexOf(22)] = red5s;
    return wall;
  }

  /// Mリーグ牌譜DB(konoui/m-league-game-db)と同じ1牌表記。
  /// 例: '5m' / 赤5='0m'・'0p'・'0s' / 字牌='1z'〜'7z'(東南西北白發中)。
  /// 中断データのストレージ保存など、外部形式に合わせる場面でのみ使う。
  static String dbNotation(int t) {
    if (isRed(t)) return '0${'mps'[suit(t)]}';
    final n = normalize(t);
    if (n >= 27) return '${n - 26}z';
    return '${n % 9 + 1}${'mps'[n ~/ 9]}';
  }

  /// [dbNotation] の逆変換(1牌)
  static int fromDbNotation(String s) => parse(s).single;

  /// 記法から牌リストを作る。例: '123m456p789s11z' / '0m'=赤5萬
  /// z: 1=東 2=南 3=西 4=北 5=白 6=發 7=中
  /// 牌譜DBの 2026-10-01 リリース以降は手牌が ',' 区切り('2m,7m,9m,…')になった
  /// (配布元 DB_CHANGELOG「牌の並べ方をそろえた」)。区切り文字と空白は読み飛ばし、
  /// 連結形と ',' 区切り形の両方を同じ結果にする。
  static List<int> parse(String notation) {
    final result = <int>[];
    final buffer = <int>[];
    for (final ch in notation.split('')) {
      if (ch == ',' || ch == ' ') continue;
      if (ch == 'm' || ch == 'p' || ch == 's') {
        final base = {'m': 0, 'p': 9, 's': 18}[ch]!;
        final red = {'m': red5m, 'p': red5p, 's': red5s}[ch]!;
        result.addAll(buffer.map((n) => n == 0 ? red : base + n - 1));
        buffer.clear();
      } else if (ch == 'z') {
        result.addAll(buffer.map((n) => 26 + n));
        buffer.clear();
      } else {
        buffer.add(int.parse(ch));
      }
    }
    return result;
  }
}

/// 風(0=東 1=南 2=西 3=北)→ 対応する字牌
int windTile(int wind) => Tile.east + wind;

const List<String> windNames = ['東', '南', '西', '北'];
