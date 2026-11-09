# Mリーグ牌譜DB 属性ノート(アプリ側の知見)

配布元: konoui/m-league-game-db(MIT)。定義そのものは配布元の `TABLE.sqlite3.md`、変更は
`DB_CHANGELOG.md`、牌の表記は `PAI_FORMAT.md` が一次情報で、ここには**配布元の文書に書かれて
いない「実データで確かめた意味・値の集合・落とし穴」と、アプリでの使い方**だけを書く。

- 対象リリース: 20261001-2219(2026-10-01)。確認日 2026-10-02。
- **再検証**: 本文中の ```check ブロックは、`check-paifu-db-schema` スキルのスクリプトが最新DBに
  対して実行し、`expect` と突き合わせる(スキーマ更新のたびに、ここに書いた意味が崩れていないかを
  機械的に確かめる)。意味を1つ書き足したら、できるだけ check も1つ足す。
  書式: `sql:` は1列1行を返す SELECT、`expect:` は値そのもの、または `>0` / `>=N` / `=0`。
- 確度の表記: **[実]** = 実DBで数えて確認、**[文]** = 配布元の文書による、**[推]** = 推定。

## 全体

- 1試合 = `game`、1局 = `kyoku`、局内の出来事は `event`(13種)+ 種別ごとの詳細テーブル。
  `event.event_order` は局内の通し番号(値は全体で一意な大きい数。局内の順序比較にだけ使う)。
- イベント型は13種で固定 [実]: haipai / draw / discard / reach / pon / chi / ankan / daiminkan /
  shominkan / dora_indicator / ron / tsumo / ryukyoku。途中流局は無い(ryukyoku.reason は
  `end_kyoku` のみ [実]、CHECK 制約あり)。

```check
name: イベント型は13種
sql: SELECT COUNT(DISTINCT type) FROM event
expect: 13
```

```check
name: 流局理由は end_kyoku のみ
sql: SELECT COUNT(*) FROM ryukyoku_event WHERE reason <> 'end_kyoku'
expect: 0
```

- 識別子の引用符は 2026-10-01 から二重引用符(それ以前はバッククォート)。スキーマ差分の道具は
  両方読めるようにしてある。

## 牌の表記(PAI_FORMAT.md の補足)

- 牌1枚は `1m`〜`9m` / `1p`〜`9p` / `1s`〜`9s` / `1z`〜`7z`(東南西北白發中)、赤5は `0m` `0p` `0s`。
- **牌を複数持つ列は `,` 区切り**(2026-10-01 から。それ以前の配牌は `279m1569p…` の連結形)[文][実]:
  `haipai_event.hand`、`player_state.hand`、`player_tenpai_state.waiting_tiles`、
  `player_state_called_block.tiles`。アプリの `Tile.parse` は両方を読む。
- `agari_event.agari_tile` は**ツモのときだけ `t` 接頭辞**(`t6p`)[実]。`draw_event.tile` には付かない。
- `^`(ツモ切り)は PAI_FORMAT.md にあるが、`discard_event.tile` には現れない [実](`is_tsumogiri` 列で持つ)。
- 鳴きブロック `block` [実]: `-` が鳴いた牌(横向き)の直前に付き、**位置が鳴き元**。
  先頭=上家(`-3z3z3z`)、中=対面(`2m2m-2m`)、末尾=下家(`1s1s1s-1s`)。ポン17,863件で
  席の相対位置と全件一致 [実](先頭↔上家 5,668、中↔対面 5,878、末尾↔下家 6,317)。チーは常に先頭。
  暗槓は `_1p1p_`(両端が `_`)。加槓は `-` が2つ(`1-1-11m`、`-2-222z`)。
  数牌は `1-1-11m` のように**数字をまとめて最後に色**を書く圧縮形もある。
  アプリは `parseBlockTiles`(engine/paifu_record.dart)で両形を読む。
  `player_state_called_block.from_relative_position` は 1=下家 2=対面 3=上家 [実](上の対応と同じ)。

```check
name: ポンの '-' の位置は鳴き元(先頭=上家)と一致
sql: SELECT COUNT(*) FROM (SELECT pe.block, ((CAST(substr(kt.player_wind,1,1) AS INT) - CAST(substr(ka.player_wind,1,1) AS INT) + 4) % 4) rel FROM pon_event pe JOIN event e ON e.id = pe.event_id JOIN kyoku_player_result ka ON ka.kyoku_id = e.kyoku_id AND ka.player_id = pe.actor_player_id JOIN kyoku_player_result kt ON kt.kyoku_id = e.kyoku_id AND kt.player_id = pe.target_player_id) WHERE (instr(block, '-') = 1) <> (rel = 3)
expect: 0
```

```check
name: 配牌は13枚(カンマ区切り)
sql: SELECT COUNT(*) FROM haipai_event WHERE length(hand) - length(replace(hand, ',', '')) + 1 <> 13
expect: 0
```

```check
name: ツモ和了の agari_tile は t 接頭辞
sql: SELECT COUNT(*) FROM agari_event a JOIN event e ON e.id = a.event_id WHERE (e.type = 'tsumo') <> (substr(a.agari_tile, 1, 1) = 't')
expect: 0
```

## game / kyoku / 結果

- `game.day_game_number`(旧 match_number)= その日の何試合目か(1/2)。`stage_game_number`(旧
  round_number)= ステージ内の通し番号 [文]。`m_league_game_id` の末尾1文字が卓(A/B)[実]
  (`tableLetterOf`)。
- `kyoku.oya_player_id`(旧 parent_player_id)。`kyoku.kyotaku_count`(旧 reach_stick_count)=
  **局開始時**の供託本数 [文][実]。その局中に出たリーチ棒は含まない(和了側の `kyotaku_points`
  には含まれる)。
- `kyoku_player_result.score` は**局終了時点**の点数 [実](最終局の値が `game_player_result.score`
  と全件一致)。「局開始時の点数」は直前の局(同じ試合で id が1つ前)の行から取る
  (`zeninShugoFinals`: 南4局開始時に全員2万点台)。
- `kyoku_player_result.player_wind` は `1z`〜`4z`(その局の自風)[実]。1局目の行を `player_wind`
  順に並べると起家からの席順になる(`gamePlayers`)。
- `game_player_result.league_points`(旧 points)= 試合ポイント(順位点込みの小数)、
  `penalty_league_points` = 罰則、`team_id` あり [実]。

```check
name: 最終局の kyoku_player_result.score は試合結果の点数と一致(局終了時点)
sql: SELECT COUNT(*) FROM kyoku k JOIN kyoku_player_result r ON r.kyoku_id = k.id JOIN game_player_result g ON g.game_id = k.game_id AND g.player_id = r.player_id WHERE k.id = (SELECT MAX(id) FROM kyoku k2 WHERE k2.game_id = k.game_id) AND r.score <> g.score
expect: 0
```

```check
name: 各局に4人分の結果行
sql: SELECT COUNT(*) FROM (SELECT kyoku_id FROM kyoku_player_result GROUP BY kyoku_id HAVING COUNT(*) <> 4)
expect: 0
```

## 進行イベント

- **リーチは必ず draw → reach → 宣言打牌(discard, is_reach_declaration=1)の順** [実](全21,652件)。
  ビューアは reach で発声だけ、宣言打牌の直後に成立処理(供託)を行う。
- `reach_event.is_accepted` = 0 は宣言牌をロンされて不成立(「通らなかったリーチ」)。
- `draw_event.wall_remaining_count`(旧 wall_remaining)= ツモ後の山の残り(最大69、海底は0)[実]。
  嶺上は `is_rinshan` で区別。海底摸月の判定は「最後のツモが山0 かつ 嶺上でない」で実データと一致
  (山0ツモ116件中115件が海底摸月。残る1件は配布元の役名誤記 2019-11-07 滝沢和典、河底撈魚と記録)。
- `dora_indicator_event.dora_type` は `omote` / `ura`、`dora_indicator_tile` が表示牌、`dora_tile` が
  ドラそのもの [実]。
- 鳴き(pon/chi/daiminkan)の `furo_count` = **その鳴きを含めた副露数**(1〜4)[実]。
  `before/after_shanten_count` は鳴き前後のシャンテン数(after は打牌込みか未確認 [推])。
- `player_state.furo_count` は 0〜4 [実]。4 = 裸単騎。

```check
name: reach の直後は同じ人の宣言打牌
sql: SELECT COUNT(*) FROM event e JOIN reach_event r ON r.event_id = e.id LEFT JOIN event n ON n.kyoku_id = e.kyoku_id AND n.event_order = e.event_order + 1 LEFT JOIN discard_event d ON d.event_id = n.id AND d.actor_player_id = r.actor_player_id AND d.is_reach_declaration = 1 WHERE d.event_id IS NULL
expect: 0
```

```check
name: 山0のツモ和了は海底摸月(誤記1件を許容)
sql: SELECT COUNT(*) FROM agari_event a JOIN event e ON e.id = a.event_id WHERE e.type = 'tsumo' AND a.is_yakuman = 0 AND (SELECT d.wall_remaining_count FROM event x JOIN draw_event d ON d.event_id = x.id WHERE x.kyoku_id = e.kyoku_id AND x.event_order < e.event_order ORDER BY x.event_order DESC LIMIT 1) = 0 AND NOT EXISTS (SELECT 1 FROM agari_yaku y JOIN yaku_name n ON n.id = y.yaku_name_id WHERE y.agari_event_id = a.event_id AND n.name = '海底摸月')
expect: <=1
```

```check
name: 鳴きの furo_count は 1〜4
sql: SELECT COUNT(*) FROM (SELECT furo_count FROM pon_event UNION ALL SELECT furo_count FROM chi_event UNION ALL SELECT furo_count FROM daiminkan_event) WHERE furo_count NOT BETWEEN 1 AND 4
expect: 0
```

## 和了(agari_event / agari_yaku)

- 点数の内訳 [文][実]: `agari_points`(旧 base_points、和了点)+ `honba_points`(本場 300×n)+
  `kyotaku_points`(供託。自分のリーチ棒も含む)= `revenue_points`(**生成列**。旧 `points` と同じ値)。
  アプリの「n点」表示は `revenue_points`。
- `agari_waiting_type`(旧 winning_type)の値は 両面 / カンチャン / ペンチャン / シャンポン / 単騎
  の5種 [実](ノベタン・亜両面・複合形は聴牌状態側にはあるが和了側では5種に丸められている)。
- `is_called`=1 かつ `is_menzen`=1 が 255 件ある [実]: 暗槓のみの手(鳴いているが門前扱い)。
- `description` は「40符5飜 満貫8000」「役満」の形。アプリは `agariDescription` /
  `limitLabelFromDescription` で同じ書式を作る・読む。
- `agari_yaku`(旧 agari_yaku_event)は1和了複数行、`yaku_name_id`(旧 name_id)で `yaku_name` を引く。
  役名は45種 [実]、`is_yakuman` 列あり。アプリの役名との差分(自風/場風の風名なし、白發中の
  「役牌」なし、混全帯么九 ↔ 全帯么九)は engine/paifu_record.dart の `dbYakuName` で変換。
- 役満は `is_yakuman`=1 で `han` は 13(複合でも)[実]。Mリーグは数え役満なし・三倍満が上限なので、
  役満以外は `han` ≤ 12 … ではなく、11翻以上はすべて三倍満(「局を探す」の三倍満は `han >= 11`)。

```check
name: 生成列 revenue_points は内訳の和
sql: SELECT COUNT(*) FROM agari_event WHERE revenue_points <> agari_points + honba_points + kyotaku_points
expect: 0
```

```check
name: 本場の点は honba_count×300(配布元データの例外1件を許容)
sql: SELECT COUNT(*) FROM agari_event a JOIN event e ON e.id = a.event_id JOIN kyoku k ON k.id = e.kyoku_id WHERE a.honba_points <> k.honba_count * 300
expect: <=1
```

```check
name: 和了の待ち種別は5種
sql: SELECT COUNT(DISTINCT agari_waiting_type) FROM agari_event
expect: 5
```

```check
name: 役名は45種
sql: SELECT COUNT(*) FROM yaku_name
expect: 45
```

## 配牌(haipai_event)

- `actor_player_id`(旧 player_id)。`is_tenho_possible` / `is_chiho_possible`(旧 tenho/chiho_possible)
  は配布元が計算した**配牌テンパイ**。アプリの `calcShanten` と全95,203件で一致 [実]
  (`tool/haipai_tenpai.dart` で再検証できる)。

```check
name: 配牌テンパイのフラグは親/子で排他
sql: SELECT COUNT(*) FROM haipai_event WHERE is_tenho_possible = 1 AND is_chiho_possible = 1
expect: 0
```

## 聴牌状態(player_state / player_tenpai_state / tenpai_agari_matrix)

- **行はそのイベントの後の状態** [実](2026-10-02 に1打ずれて気づいた)。見逃した打牌の行では
  まだロンできる(`is_temporary_furiten`=0)で、次の他家の打牌の行で 1 になる。
  「見逃した牌」を求めるときは、フラグが立つ前で `waiting_tiles` に含まれる他家の最後の打牌を取る
  (`PaifuDb.missedRonAgaris`)。
- `player_tenpai_state` は 2026-10-01 から**他家の打牌・加槓の時点で聴牌している人の行も入る**
  (`is_actor`=0)。本人の行は `is_actor`=1。本人だけを集計するなら `is_actor = 1` を付ける [文][実]。
- `is_furiten` = 捨て牌(`is_discard_furiten`)・同巡内(`is_temporary_furiten`)・リーチ後
  (`is_reach_furiten`)のいずれか [文]。
- `waiting_type` は 両面 / カンチャン / ペンチャン / シャンポン / 単騎 / ノベタン / 亜両面 / 複合形
  の8種 [実]。`waiting_tiles` は `,` 区切り、`tile_type_count` は待ちの種類数。
- `tenpai_agari_matrix` は待ち牌ごとの行で、ロンとツモの行(`is_ron_agari`)が別。フリテン中は
  ロンの行が作られない(=行の有無がその時点で和了できるか)[文]。枚数(`available_tile_count` 等)
  はロン行とツモ行で同じ値が入るので合計は `DISTINCT` [文]。流局イベントにも「流局しなければ
  和了できた牌」の行がある [文]。
- `player_state.shanten_count` と標準形/七対子/国士の内訳、`player_state_called_block`(1面子1行、
  `call_type`・`from_relative_position`)は未使用。使う前に意味を1局で確認する。

```check
name: 他家の聴牌者の行がある(2026-10-01 以降の形)
sql: SELECT COUNT(*) FROM player_tenpai_state WHERE is_actor = 0
expect: >0
```

```check
name: 聴牌の待ち種別は8種
sql: SELECT COUNT(DISTINCT waiting_type) FROM player_tenpai_state
expect: 8
```

- `tenpai_agari_matrix` の枚数 [実]: `ideal_tile_count` = 4 − 自分の手牌にある枚数、
  `discarded_tile_count` = 全員の河にある枚数、`dora_indicator_tile_count` = ドラ表示牌で見えている枚数、
  **`available_tile_count` = 山に残る真の枚数(他家の手の中まで差し引いた神視点)**。
  本人から見える残りは `ideal − discarded − dora_indicator` で、available とは別物
  (2026-10-02 日向藍子の南単騎: 見える残り3、available 1=浅見真紀が2枚所持。ユーザー指摘)。
  他家の副露に含まれる枚数はどの列にも入っていないので、鳴きイベントの `block` から数える
  (アプリは `PaifuDb.hellTankiRiichiPairs` で `parseBlockTiles` を使って数える。副露も場に見えて
  いる牌なので省かない=ユーザー方針)。「地獄単騎リーチの和了」は宣言打牌の行(`is_actor`=1、
  `waiting_type`='単騎')で、副露込みの見える残りが 1。

```check
name: available は見える残り(ideal-discarded-dora)以下(神視点なので他家の手の分だけ小さい)
sql: SELECT COUNT(*) FROM tenpai_agari_matrix WHERE available_tile_count > ideal_tile_count - discarded_tile_count - dora_indicator_tile_count
expect: 0
```

```check
name: available が見える残りより小さい行がある(他家の手の中を差し引いている証拠)
sql: SELECT COUNT(*) FROM tenpai_agari_matrix WHERE available_tile_count < ideal_tile_count - discarded_tile_count - dora_indicator_tile_count
expect: >0
```

```check
name: 単騎待ちのリーチで見える残り1枚(地獄)がある
sql: SELECT COUNT(*) FROM event ev JOIN discard_event d ON d.event_id = ev.id JOIN player_tenpai_state ts ON ts.event_id = ev.id AND ts.player_id = d.actor_player_id AND ts.is_actor = 1 WHERE d.is_reach_declaration = 1 AND ts.waiting_type = '単騎' AND (SELECT MIN(ideal_tile_count - discarded_tile_count - dora_indicator_tile_count) FROM tenpai_agari_matrix mx WHERE mx.event_id = ev.id AND mx.player_id = d.actor_player_id) = 1
expect: >0
```

```check
name: 見逃し(同巡内フリテン)は本人以外の行で立つ
sql: SELECT COUNT(*) FROM player_tenpai_state WHERE is_temporary_furiten = 1 AND is_actor = 0
expect: >0
```

## 流局(ryukyoku_player)

- `tenpai_points`(旧 points)= ノーテン罰符の受け払い(+3000/+1500/+1000/0/-1000/-1500/-3000)[実]。

```check
name: 流局の受け払いは±3000以内で合計0
sql: SELECT COUNT(*) FROM (SELECT ryukyoku_event_id FROM ryukyoku_player GROUP BY ryukyoku_event_id HAVING SUM(tenpai_points) <> 0 OR MAX(abs(tenpai_points)) > 3000)
expect: 0
```

## 反則(foul_play)

- `foul_type` [実]: ノーテンリーチ / 多牌 / 少牌 / 誤チー / 誤ツモ / 誤ポン / 誤ロン。`is_restarted` は
  局をやり直したか(誤ロンで2件)。`penalty_league_points`(旧 penalty_points)。
  アプリは反則を起こせない設計なので読まない(局の除外にも使っていない)。

## 選手・チーム

- `player.joined_season_year`、`player_team`(joined/left_season_year)で移籍・復帰を表す [実]
  (朝倉康心 2018–2021 と 2026 再加入 等)。`team.joined_season_year` あり。
- `league_season.start_year`(2018〜)、`season_stage.stage` は regular / semifinal / final [実]。

## 配布元データの既知の癖(アプリ側では直さない)

- 2019-11-07 第2試合 東4局 滝沢和典のツモ和了に「河底撈魚」(本来は海底摸月)[実]。
- 本場の点が honba_count×300 と合わない和了が1件 [実](未調査)。
- 山を再構成できない局が1局(配牌欠損)[実](ゴースト・ベンチは飛ばす)。
- 配布元 README: リーチ宣言の数え方に不具合があり得る、との注記 [文]。

## 関連

- スナップショット(定義): docs/paifu-db-schema.sql(スキルが更新)
- 改名への追従の仕組み: lib/paifu/db_schema.dart(`DbSchema`)、docs/manual-paifu-design.md 追補
- 失敗談: docs/failure-log.md 2026-10-02(改名で壊れた・誤判定・1打ずれ)
