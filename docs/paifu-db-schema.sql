-- Mリーグ牌譜DB(konoui/m-league-game-db, MIT License, Copyright (c) 2025 konoui。許諾文は docs/THIRD_PARTY_LICENSES.md)のスキーマのスナップショット。check-paifu-db-schema スキルが差分検出の基準に使う。
-- release: 20261001-2219-d157d710  verified: 2026-10-02
CREATE UNIQUE INDEX "foul_play_kyoku_id_unique" ON "foul_play" ("kyoku_id");
CREATE UNIQUE INDEX "game_m_league_game_id_unique" ON "game" ("m_league_game_id");
CREATE INDEX "idx_agari_event_actor_player_id" ON "agari_event" ("actor_player_id");
CREATE INDEX "idx_agari_event_target_player_id" ON "agari_event" ("target_player_id");
CREATE INDEX "idx_agari_yaku_yaku_name_id" ON "agari_yaku" ("yaku_name_id");
CREATE INDEX "idx_ankan_event_actor_player_id" ON "ankan_event" ("actor_player_id");
CREATE INDEX "idx_chi_event_actor_player_id" ON "chi_event" ("actor_player_id");
CREATE INDEX "idx_chi_event_target_player_id" ON "chi_event" ("target_player_id");
CREATE INDEX "idx_daiminkan_event_actor_player_id" ON "daiminkan_event" ("actor_player_id");
CREATE INDEX "idx_discard_event_actor_player_id_is_reach_declaration" ON "discard_event" ("actor_player_id","is_reach_declaration");
CREATE INDEX "idx_draw_event_actor_player_id" ON "draw_event" ("actor_player_id");
CREATE UNIQUE INDEX "idx_event_kyoku_id_event_order" ON "event" ("kyoku_id","event_order");
CREATE INDEX "idx_event_kyoku_id_type" ON "event" ("kyoku_id","type");
CREATE INDEX "idx_event_type" ON "event" ("type");
CREATE INDEX "idx_foul_play_actor_player_id" ON "foul_play" ("actor_player_id");
CREATE INDEX "idx_game_player_result_player_id" ON "game_player_result" ("player_id");
CREATE INDEX "idx_game_player_result_team_id" ON "game_player_result" ("team_id");
CREATE UNIQUE INDEX "idx_game_season_stage_id_stage_game_number" ON "game" ("season_stage_id","stage_game_number");
CREATE INDEX "idx_haipai_event_actor_player_id" ON "haipai_event" ("actor_player_id");
CREATE UNIQUE INDEX "idx_kyoku_game_id_round_honba_count" ON "kyoku" ("game_id","round","honba_count");
CREATE INDEX "idx_kyoku_oya_player_id" ON "kyoku" ("oya_player_id");
CREATE INDEX "idx_kyoku_player_result_player_id" ON "kyoku_player_result" ("player_id");
CREATE INDEX "idx_player_name_furigana" ON "player" ("name_furigana");
CREATE INDEX "idx_player_state_player_id" ON "player_state" ("player_id");
CREATE INDEX "idx_player_team_player_id_joined_season_year_left_season_year" ON "player_team" ("player_id","joined_season_year","left_season_year");
CREATE INDEX "idx_player_tenpai_state_player_id" ON "player_tenpai_state" ("player_id");
CREATE INDEX "idx_pon_event_actor_player_id" ON "pon_event" ("actor_player_id");
CREATE INDEX "idx_pon_event_target_player_id" ON "pon_event" ("target_player_id");
CREATE INDEX "idx_reach_event_actor_player_id" ON "reach_event" ("actor_player_id");
CREATE INDEX "idx_ryukyoku_player_player_id_is_tenpai" ON "ryukyoku_player" ("player_id","is_tenpai");
CREATE UNIQUE INDEX "idx_season_stage_league_season_id_stage" ON "season_stage" ("league_season_id","stage");
CREATE INDEX "idx_shominkan_event_actor_player_id" ON "shominkan_event" ("actor_player_id");
CREATE UNIQUE INDEX "idx_tenpai_agari_matrix_event_id_player_id_waiting_tile_is_ron_agari" ON "tenpai_agari_matrix" ("event_id","player_id","waiting_tile","is_ron_agari");
CREATE INDEX "idx_tenpai_yaku_yaku_name_id" ON "tenpai_yaku" ("yaku_name_id");
CREATE UNIQUE INDEX "league_season_end_year_unique" ON "league_season" ("end_year");
CREATE UNIQUE INDEX "league_season_start_year_unique" ON "league_season" ("start_year");
CREATE UNIQUE INDEX "player_name_unique" ON "player" ("name");
CREATE UNIQUE INDEX "team_name_unique" ON "team" ("name");
CREATE UNIQUE INDEX "yaku_name_name_furigana_unique" ON "yaku_name" ("name_furigana");
CREATE UNIQUE INDEX "yaku_name_name_unique" ON "yaku_name" ("name");
CREATE TABLE "agari_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"target_player_id" integer,
	"agari_points" integer NOT NULL,
	"honba_points" integer NOT NULL,
	"kyotaku_points" integer NOT NULL,
	"revenue_points" integer GENERATED ALWAYS AS (agari_points + honba_points + kyotaku_points) VIRTUAL NOT NULL,
	"agari_tile" text(255) NOT NULL,
	"agari_waiting_type" text(255) NOT NULL,
	"fu" integer NOT NULL,
	"han" integer NOT NULL,
	"is_called" integer NOT NULL,
	"is_menzen" integer NOT NULL,
	"is_yakuman" integer NOT NULL,
	"description" text(255) NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("target_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_agari_event_agari_waiting_type" CHECK(agari_waiting_type IN ('単騎', '両面', 'ペンチャン', 'カンチャン', 'シャンポン')),
	CONSTRAINT "check_agari_event_han" CHECK("agari_event"."han" >= 1),
	CONSTRAINT "check_agari_event_fu" CHECK("agari_event"."fu" >= 0),
	CONSTRAINT "check_agari_event_agari_points" CHECK("agari_event"."agari_points" > 0),
	CONSTRAINT "check_agari_event_honba_points" CHECK("agari_event"."honba_points" >= 0),
	CONSTRAINT "check_agari_event_kyotaku_points" CHECK("agari_event"."kyotaku_points" >= 0),
	CONSTRAINT "check_agari_event_is_called" CHECK("agari_event"."is_called" IN (0, 1)),
	CONSTRAINT "check_agari_event_is_menzen" CHECK("agari_event"."is_menzen" IN (0, 1)),
	CONSTRAINT "check_agari_event_is_yakuman" CHECK("agari_event"."is_yakuman" IN (0, 1))
);
CREATE TABLE "agari_yaku" (
	"agari_event_id" integer NOT NULL,
	"yaku_name_id" integer NOT NULL,
	"han" integer NOT NULL,
	PRIMARY KEY("agari_event_id", "yaku_name_id"),
	FOREIGN KEY ("agari_event_id") REFERENCES "agari_event"("event_id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("yaku_name_id") REFERENCES "yaku_name"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_agari_yaku_han" CHECK("agari_yaku"."han" >= 1)
);
CREATE TABLE "ankan_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"tile" text(10) NOT NULL,
	"block" text(255) NOT NULL,
	"before_shanten_count" integer NOT NULL,
	"after_shanten_count" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_ankan_event_before_shanten_count" CHECK("ankan_event"."before_shanten_count" >= 0),
	CONSTRAINT "check_ankan_event_after_shanten_count" CHECK("ankan_event"."after_shanten_count" >= -1)
);
CREATE TABLE "chi_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"target_player_id" integer NOT NULL,
	"tile" text(10) NOT NULL,
	"block" text(255) NOT NULL,
	"furo_count" integer NOT NULL,
	"before_shanten_count" integer NOT NULL,
	"after_shanten_count" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("target_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_chi_event_furo_count" CHECK("chi_event"."furo_count" BETWEEN 1 AND 4),
	CONSTRAINT "check_chi_event_before_shanten_count" CHECK("chi_event"."before_shanten_count" >= 0),
	CONSTRAINT "check_chi_event_after_shanten_count" CHECK("chi_event"."after_shanten_count" >= -1)
);
CREATE TABLE "daiminkan_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"target_player_id" integer NOT NULL,
	"tile" text(10) NOT NULL,
	"block" text(255) NOT NULL,
	"furo_count" integer NOT NULL,
	"before_shanten_count" integer NOT NULL,
	"after_shanten_count" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("target_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_daiminkan_event_furo_count" CHECK("daiminkan_event"."furo_count" BETWEEN 1 AND 4),
	CONSTRAINT "check_daiminkan_event_before_shanten_count" CHECK("daiminkan_event"."before_shanten_count" >= 0),
	CONSTRAINT "check_daiminkan_event_after_shanten_count" CHECK("daiminkan_event"."after_shanten_count" >= -1)
);
CREATE TABLE "discard_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"tile" text(10) NOT NULL,
	"is_reach_declaration" integer NOT NULL,
	"is_tsumogiri" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_discard_event_is_reach_declaration" CHECK("discard_event"."is_reach_declaration" IN (0, 1)),
	CONSTRAINT "check_discard_event_is_tsumogiri" CHECK("discard_event"."is_tsumogiri" IN (0, 1))
);
CREATE TABLE "dora_indicator_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"dora_type" text NOT NULL,
	"dora_indicator_tile" text(10) NOT NULL,
	"dora_tile" text(10) NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_dora_indicator_event_dora_type" CHECK(dora_type IN ('omote', 'ura'))
);
CREATE TABLE "draw_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"tile" text(10) NOT NULL,
	"is_rinshan" integer NOT NULL,
	"wall_remaining_count" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_draw_event_is_rinshan" CHECK("draw_event"."is_rinshan" IN (0, 1)),
	CONSTRAINT "check_draw_event_wall_remaining_count" CHECK("draw_event"."wall_remaining_count" BETWEEN 0 AND 69)
);
CREATE TABLE "event" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"kyoku_id" integer NOT NULL,
	"type" text NOT NULL,
	"event_order" integer NOT NULL,
	FOREIGN KEY ("kyoku_id") REFERENCES "kyoku"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_event_type" CHECK(type IN ('haipai', 'draw', 'discard', 'ron', 'tsumo', 'reach', 'pon', 'chi', 'daiminkan', 'shominkan', 'ankan', 'dora_indicator', 'ryukyoku')),
	CONSTRAINT "check_event_event_order" CHECK("event"."event_order" >= 1)
);
CREATE TABLE "foul_play" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"kyoku_id" integer NOT NULL,
	"actor_player_id" integer NOT NULL,
	"penalty_league_points" real NOT NULL,
	"description" text(255) NOT NULL,
	"foul_type" text(255) NOT NULL,
	"is_restarted" integer NOT NULL,
	FOREIGN KEY ("kyoku_id") REFERENCES "kyoku"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_foul_play_foul_type" CHECK(foul_type IN ('ノーテンリーチ', '誤ポン', '誤チー', '少牌', '多牌', '誤ツモ', '誤ロン')),
	CONSTRAINT "check_foul_play_is_restarted" CHECK("foul_play"."is_restarted" IN (0, 1))
);
CREATE TABLE "game" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"season_stage_id" integer NOT NULL,
	"date" text NOT NULL,
	"day_game_number" integer NOT NULL,
	"stage_game_number" integer NOT NULL,
	"m_league_game_id" text(50) NOT NULL,
	FOREIGN KEY ("season_stage_id") REFERENCES "season_stage"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_game_date" CHECK("game"."date" = date("game"."date")),
	CONSTRAINT "check_game_day_game_number" CHECK("game"."day_game_number" >= 1),
	CONSTRAINT "check_game_stage_game_number" CHECK("game"."stage_game_number" >= 1)
);
CREATE TABLE "game_player_result" (
	"game_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"team_id" integer NOT NULL,
	"score" integer NOT NULL,
	"league_points" real NOT NULL,
	"penalty_league_points" real NOT NULL,
	"rank" integer NOT NULL,
	PRIMARY KEY("game_id", "player_id"),
	FOREIGN KEY ("game_id") REFERENCES "game"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("team_id") REFERENCES "team"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_game_player_result_rank" CHECK("game_player_result"."rank" in (1, 2, 3, 4))
);
CREATE TABLE "haipai_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"hand" text(255) NOT NULL,
	"is_tenho_possible" integer NOT NULL,
	"is_chiho_possible" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_haipai_event_is_tenho_possible" CHECK("haipai_event"."is_tenho_possible" IN (0, 1)),
	CONSTRAINT "check_haipai_event_is_chiho_possible" CHECK("haipai_event"."is_chiho_possible" IN (0, 1))
);
CREATE TABLE "kyoku" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"game_id" integer NOT NULL,
	"oya_player_id" integer NOT NULL,
	"round" text NOT NULL,
	"honba_count" integer NOT NULL,
	"kyotaku_count" integer NOT NULL,
	FOREIGN KEY ("game_id") REFERENCES "game"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("oya_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_kyoku_round" CHECK(round IN ('1z1', '1z2', '1z3', '1z4', '2z1', '2z2', '2z3', '2z4', '3z1', '3z2', '3z3', '3z4', '4z1', '4z2', '4z3', '4z4')),
	CONSTRAINT "check_kyoku_honba_count" CHECK("kyoku"."honba_count" >= 0),
	CONSTRAINT "check_kyoku_kyotaku_count" CHECK("kyoku"."kyotaku_count" >= 0)
);
CREATE TABLE "kyoku_player_result" (
	"kyoku_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"score" integer NOT NULL,
	"player_wind" text NOT NULL,
	"rank" integer NOT NULL,
	PRIMARY KEY("kyoku_id", "player_id"),
	FOREIGN KEY ("kyoku_id") REFERENCES "kyoku"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_kyoku_player_result_player_wind" CHECK(player_wind IN ('1z', '2z', '3z', '4z')),
	CONSTRAINT "check_kyoku_player_result_rank" CHECK("kyoku_player_result"."rank" in (1, 2, 3, 4))
);
CREATE TABLE "league_season" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"start_year" integer NOT NULL,
	"end_year" integer NOT NULL,
	CONSTRAINT "check_league_season_end_year_start_year" CHECK("league_season"."end_year" = "league_season"."start_year" + 1)
);
CREATE TABLE "player" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"name" text(100) NOT NULL,
	"name_furigana" text(100) NOT NULL,
	"joined_season_year" integer NOT NULL
);
CREATE TABLE "player_state" (
	"event_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"turn_number" integer NOT NULL,
	"hand" text(255) NOT NULL,
	"called_blocks" text(255) NOT NULL,
	"shanten_count" integer NOT NULL,
	"standard_type_shanten_count" integer NOT NULL,
	"seven_pairs_shanten_count" integer,
	"thirteen_orphans_shanten_count" integer,
	"call_count" integer NOT NULL,
	"furo_count" integer NOT NULL,
	"is_menzen" integer NOT NULL,
	PRIMARY KEY("event_id", "player_id"),
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_player_state_turn_number" CHECK("player_state"."turn_number" >= 0),
	CONSTRAINT "check_player_state_shanten_count" CHECK("player_state"."shanten_count" >= -1),
	CONSTRAINT "check_player_state_standard_type_shanten_count" CHECK("player_state"."standard_type_shanten_count" >= -1),
	CONSTRAINT "check_player_state_seven_pairs_shanten_count" CHECK("player_state"."seven_pairs_shanten_count" IS NULL OR "player_state"."seven_pairs_shanten_count" >= -1),
	CONSTRAINT "check_player_state_thirteen_orphans_shanten_count" CHECK("player_state"."thirteen_orphans_shanten_count" IS NULL OR "player_state"."thirteen_orphans_shanten_count" >= -1),
	CONSTRAINT "check_player_state_call_count" CHECK("player_state"."call_count" BETWEEN 0 AND 4),
	CONSTRAINT "check_player_state_furo_count_call_count" CHECK("player_state"."furo_count" BETWEEN 0 AND "player_state"."call_count"),
	CONSTRAINT "check_player_state_is_menzen" CHECK("player_state"."is_menzen" IN (0, 1))
);
CREATE TABLE "player_state_called_block" (
	"event_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"block_number" integer NOT NULL,
	"call_type" text(255) NOT NULL,
	"tiles" text(255) NOT NULL,
	"called_tile" text(255),
	"from_relative_position" integer,
	PRIMARY KEY("event_id", "player_id", "block_number"),
	FOREIGN KEY ("event_id","player_id") REFERENCES "player_state"("event_id","player_id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_player_state_called_block_block_number" CHECK("player_state_called_block"."block_number" BETWEEN 1 AND 4),
	CONSTRAINT "check_player_state_called_block_call_type" CHECK(call_type IN ('chi', 'pon', 'daiminkan', 'shominkan', 'ankan')),
	CONSTRAINT "check_player_state_called_block_called_tile_from_relative_position" CHECK(("player_state_called_block"."called_tile" IS NULL) = ("player_state_called_block"."from_relative_position" IS NULL)),
	CONSTRAINT "check_player_state_called_block_from_relative_position" CHECK("player_state_called_block"."from_relative_position" IS NULL OR "player_state_called_block"."from_relative_position" BETWEEN 1 AND 3)
);
CREATE TABLE "player_team" (
	"player_id" integer NOT NULL,
	"team_id" integer NOT NULL,
	"joined_season_year" integer NOT NULL,
	"left_season_year" integer NOT NULL,
	PRIMARY KEY("team_id", "player_id", "joined_season_year"),
	FOREIGN KEY ("player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("team_id") REFERENCES "team"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_player_team_left_season_year_joined_season_year" CHECK("player_team"."left_season_year" >= "player_team"."joined_season_year")
);
CREATE TABLE "player_tenpai_state" (
	"event_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"waiting_type" text(255) NOT NULL,
	"waiting_tiles" text(255) NOT NULL,
	"tile_type_count" integer NOT NULL,
	"ideal_tile_count" integer NOT NULL,
	"available_tile_count" integer NOT NULL,
	"discarded_tile_count" integer NOT NULL,
	"dora_indicator_tile_count" integer NOT NULL,
	"is_actor" integer NOT NULL,
	"is_reached" integer NOT NULL,
	"is_furiten" integer NOT NULL,
	"is_discard_furiten" integer NOT NULL,
	"is_temporary_furiten" integer NOT NULL,
	"is_reach_furiten" integer NOT NULL,
	PRIMARY KEY("event_id", "player_id"),
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_player_tenpai_state_waiting_type" CHECK(waiting_type IN ('単騎', '両面', 'ペンチャン', 'カンチャン', 'シャンポン', '亜両面', 'ノベタン', '複合形')),
	CONSTRAINT "check_player_tenpai_state_tile_type_count" CHECK("player_tenpai_state"."tile_type_count" >= 1),
	CONSTRAINT "check_player_tenpai_state_available_tile_count" CHECK("player_tenpai_state"."available_tile_count" >= 0),
	CONSTRAINT "check_player_tenpai_state_discarded_tile_count" CHECK("player_tenpai_state"."discarded_tile_count" >= 0),
	CONSTRAINT "check_player_tenpai_state_dora_indicator_tile_count" CHECK("player_tenpai_state"."dora_indicator_tile_count" >= 0),
	CONSTRAINT "check_player_tenpai_state_is_actor" CHECK("player_tenpai_state"."is_actor" IN (0, 1)),
	CONSTRAINT "check_player_tenpai_state_is_reached" CHECK("player_tenpai_state"."is_reached" IN (0, 1)),
	CONSTRAINT "check_player_tenpai_state_is_furiten" CHECK("player_tenpai_state"."is_furiten" IN (0, 1)),
	CONSTRAINT "check_player_tenpai_state_is_discard_furiten" CHECK("player_tenpai_state"."is_discard_furiten" IN (0, 1)),
	CONSTRAINT "check_player_tenpai_state_is_temporary_furiten" CHECK("player_tenpai_state"."is_temporary_furiten" IN (0, 1)),
	CONSTRAINT "check_player_tenpai_state_is_reach_furiten" CHECK("player_tenpai_state"."is_reach_furiten" IN (0, 1)),
	CONSTRAINT "check_player_tenpai_state_is_furiten_is_discard_furiten_is_temporary_furiten_is_reach_furiten" CHECK("player_tenpai_state"."is_furiten" = (CASE WHEN "player_tenpai_state"."is_discard_furiten" + "player_tenpai_state"."is_temporary_furiten" + "player_tenpai_state"."is_reach_furiten" > 0 THEN 1 ELSE 0 END)),
	CONSTRAINT "check_player_tenpai_state_is_temporary_furiten_is_reached" CHECK("player_tenpai_state"."is_temporary_furiten" = 0 OR "player_tenpai_state"."is_reached" = 0),
	CONSTRAINT "check_player_tenpai_state_is_reach_furiten_is_reached" CHECK("player_tenpai_state"."is_reach_furiten" = 0 OR "player_tenpai_state"."is_reached" = 1)
);
CREATE TABLE "pon_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"target_player_id" integer NOT NULL,
	"block" text(255) NOT NULL,
	"tile" text(10) NOT NULL,
	"furo_count" integer NOT NULL,
	"before_shanten_count" integer NOT NULL,
	"after_shanten_count" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("target_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_pon_event_furo_count" CHECK("pon_event"."furo_count" BETWEEN 1 AND 4),
	CONSTRAINT "check_pon_event_before_shanten_count" CHECK("pon_event"."before_shanten_count" >= 0),
	CONSTRAINT "check_pon_event_after_shanten_count" CHECK("pon_event"."after_shanten_count" >= -1)
);
CREATE TABLE "reach_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"is_accepted" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_reach_event_is_accepted" CHECK("reach_event"."is_accepted" IN (0, 1))
);
CREATE TABLE "ryukyoku_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"reason" text NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_ryukyoku_event_reason" CHECK(reason IN ('end_kyoku'))
);
CREATE TABLE "ryukyoku_player" (
	"ryukyoku_event_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"is_tenpai" integer NOT NULL,
	"tenpai_points" integer NOT NULL,
	PRIMARY KEY("ryukyoku_event_id", "player_id"),
	FOREIGN KEY ("ryukyoku_event_id") REFERENCES "ryukyoku_event"("event_id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_ryukyoku_player_is_tenpai" CHECK("ryukyoku_player"."is_tenpai" IN (0, 1)),
	CONSTRAINT "check_ryukyoku_player_tenpai_points" CHECK(tenpai_points IN (0, 1000, 1500, 3000, -1000, -1500, -3000))
);
CREATE TABLE "season_stage" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"league_season_id" integer NOT NULL,
	"stage" text NOT NULL,
	FOREIGN KEY ("league_season_id") REFERENCES "league_season"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_season_stage_stage" CHECK(stage IN ('regular', 'semifinal', 'final'))
);
CREATE TABLE "shominkan_event" (
	"event_id" integer PRIMARY KEY NOT NULL,
	"actor_player_id" integer NOT NULL,
	"tile" text(10) NOT NULL,
	"block" text(255) NOT NULL,
	"before_shanten_count" integer NOT NULL,
	"after_shanten_count" integer NOT NULL,
	FOREIGN KEY ("event_id") REFERENCES "event"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("actor_player_id") REFERENCES "player"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_shominkan_event_before_shanten_count" CHECK("shominkan_event"."before_shanten_count" >= 0),
	CONSTRAINT "check_shominkan_event_after_shanten_count" CHECK("shominkan_event"."after_shanten_count" >= -1)
);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE "team" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"name" text(100) NOT NULL,
	"joined_season_year" integer NOT NULL
);
CREATE TABLE "tenpai_agari_matrix" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"event_id" integer NOT NULL,
	"player_id" integer NOT NULL,
	"waiting_tile" text(255) NOT NULL,
	"available_tile_count" integer NOT NULL,
	"ideal_tile_count" integer NOT NULL,
	"discarded_tile_count" integer NOT NULL,
	"dora_indicator_tile_count" integer NOT NULL,
	"is_ron_agari" integer NOT NULL,
	FOREIGN KEY ("event_id","player_id") REFERENCES "player_tenpai_state"("event_id","player_id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_tenpai_agari_matrix_available_tile_count" CHECK("tenpai_agari_matrix"."available_tile_count" BETWEEN 0 AND 4),
	CONSTRAINT "check_tenpai_agari_matrix_ideal_tile_count" CHECK("tenpai_agari_matrix"."ideal_tile_count" BETWEEN 1 AND 4),
	CONSTRAINT "check_tenpai_agari_matrix_discarded_tile_count" CHECK("tenpai_agari_matrix"."discarded_tile_count" BETWEEN 0 AND 4),
	CONSTRAINT "check_tenpai_agari_matrix_dora_indicator_tile_count" CHECK("tenpai_agari_matrix"."dora_indicator_tile_count" BETWEEN 0 AND 4),
	CONSTRAINT "check_tenpai_agari_matrix_is_ron_agari" CHECK("tenpai_agari_matrix"."is_ron_agari" IN (0, 1))
);
CREATE TABLE "tenpai_yaku" (
	"tenpai_agari_matrix_id" integer NOT NULL,
	"yaku_name_id" integer NOT NULL,
	"han" integer NOT NULL,
	PRIMARY KEY("tenpai_agari_matrix_id", "yaku_name_id"),
	FOREIGN KEY ("tenpai_agari_matrix_id") REFERENCES "tenpai_agari_matrix"("id") ON UPDATE no action ON DELETE no action,
	FOREIGN KEY ("yaku_name_id") REFERENCES "yaku_name"("id") ON UPDATE no action ON DELETE no action,
	CONSTRAINT "check_tenpai_yaku_han" CHECK("tenpai_yaku"."han" >= 1)
);
CREATE TABLE "yaku_name" (
	"id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	"name" text(255) NOT NULL,
	"name_furigana" text(255) NOT NULL,
	"is_yakuman" integer NOT NULL,
	CONSTRAINT "check_yaku_name_is_yakuman" CHECK("yaku_name"."is_yakuman" IN (0, 1))
);
CREATE VIEW "player_season_stage_stats" AS select "season_start_year" as "season_start_year", "stage" as "stage", "player_name" as "player_name", "team_name" as "team_name", "total_game_count" as "total_game_count", ROUND("agari_count" * 100.0 / "total_kyoku_count", 2) as "agari_per_kyoku_percent", ROUND(CASE WHEN "agari_count" > 0 THEN "tsumo_agari_count" * 100.0 / "agari_count" ELSE 0 END, 2) as "tsumo_agari_per_agari_percent", ROUND(CASE WHEN "agari_count" > 0 THEN "reach_agari_count" * 100.0 / "agari_count" ELSE 0 END, 2) as "reach_agari_per_agari_percent", ROUND(CASE WHEN "agari_count" > 0 THEN "furo_agari_count" * 100.0 / "agari_count" ELSE 0 END, 2) as "furo_agari_per_agari_percent", ROUND(CASE WHEN "agari_count" > 0 THEN ("agari_count" - "reach_agari_count" - "furo_agari_count") * 100.0 / "agari_count" ELSE 0 END, 2) as "dama_agari_per_agari_percent", ROUND("dealin_count" * 100.0 / "total_kyoku_count", 2) as "dealin_per_kyoku_percent", ROUND("hitsumo_count" * 100.0 / "total_kyoku_count", 2) as "hitsumo_per_kyoku_percent", ROUND("furo_count" * 100.0 / "total_kyoku_count", 2) as "furo_per_kyoku_percent", ROUND("reach_count" * 100.0 / "total_kyoku_count", 2) as "reach_per_kyoku_percent", ROUND(CASE WHEN "reach_count" > 0 THEN "reach_agari_count" * 100.0 / "reach_count" ELSE 0 END, 2) as "reach_agari_per_reach_percent", ROUND("ryukyoku_count" * 100.0 / "total_kyoku_count", 2) as "ryukyoku_per_kyoku_percent", ROUND(CASE WHEN "ryukyoku_count" > 0 THEN "tenpai_count" * 100.0 / "ryukyoku_count" ELSE 0 END, 2) as "tenpai_per_ryukyoku_percent", ROUND(CASE WHEN "ryukyoku_count" > 0 THEN "tenpai_points_total" * 1.0 / "ryukyoku_count" ELSE 0 END, 1) as "tenpai_points_per_ryukyoku", "rank1_count" as "rank1_count", "rank2_count" as "rank2_count", "rank3_count" as "rank3_count", "rank4_count" as "rank4_count", ROUND("rank1_count" * 100.0 / "total_game_count", 2) as "top_per_game_percent", ROUND(("rank1_count" + "rank2_count") * 100.0 / "total_game_count", 2) as "top2_per_game_percent", ROUND(("rank1_count" + "rank2_count" + "rank3_count") * 100.0 / "total_game_count", 2) as "avoid_last_per_game_percent", "best_score" as "best_score", "league_points_total" as "league_points_total", ROUND(("total_kyoku_count" - "agari_count" - "dealin_count" - "hitsumo_count" - "ryukyoku_count") * 100.0 / "total_kyoku_count", 2) as "yokomove_per_kyoku_percent", CAST(ROUND(CASE WHEN "agari_count" > 0 THEN CAST("agari_points_total" AS REAL) / "agari_count" ELSE NULL END, 0) AS INTEGER) as "agari_points_per_agari", CAST(ROUND(CASE WHEN "dealin_count" > 0 THEN CAST("dealin_points_total" AS REAL) / "dealin_count" ELSE NULL END, 0) AS INTEGER) as "dealin_points_per_dealin", ROUND(CASE WHEN "oya_kyoku_count" > 0 THEN "oya_kaburi_count" * 100.0 / "oya_kyoku_count" ELSE 0 END, 2) as "oya_kaburi_per_oya_kyoku_percent", ROUND(CASE WHEN "oya_kaburi_count" > 0 THEN "itai_oya_kaburi_count" * 100.0 / "oya_kaburi_count" ELSE 0 END, 2) as "itai_oya_kaburi_per_oya_kaburi_percent", ROUND(CASE WHEN "reach_count" > 0 THEN "reach_dealin_count" * 100.0 / "reach_count" ELSE 0 END, 2) as "reach_dealin_per_reach_percent", "reach_declare_dealin_count" as "reach_declare_dealin_count", ROUND(CASE WHEN "agari_count" > 0 THEN "dora_total" * 1.0 / "agari_count" ELSE 0 END, 3) as "dora_per_agari", ROUND(CASE WHEN "agari_count" > 0 THEN "aka_dora_total" * 1.0 / "agari_count" ELSE 0 END, 3) as "aka_dora_per_agari", ROUND(CASE WHEN "reach_agari_count" > 0 THEN "ura_dora_total" * 1.0 / "reach_agari_count" ELSE 0 END, 3) as "ura_dora_per_reach_agari", ROUND(CASE WHEN "reach_agari_count" > 0 THEN "ura_dora_agari_count" * 100.0 / "reach_agari_count" ELSE 0 END, 2) as "ura_dora_agari_per_reach_agari_percent", ROUND(CASE WHEN "agari_count" > 0 THEN ("dora_total" + "aka_dora_total" + "ura_dora_total") * 1.0 / "agari_count" ELSE 0 END, 3) as "all_dora_per_agari", ROUND(CASE WHEN "oya_kyoku_count" > 0 THEN "renchan_count" * 100.0 / "oya_kyoku_count" ELSE 0 END, 2) as "renchan_per_oya_kyoku_percent", "carryover_kyotaku_points_total" as "carryover_kyotaku_points_total", "kyotaku_points_excluding_own_reach_total" as "kyotaku_points_excluding_own_reach_total", "kyotaku_honba_points_excluding_own_reach_total" as "kyotaku_honba_points_excluding_own_reach_total", "honba_points_total" as "honba_points_total" from "player_season_stage_stats_base" order by "season_start_year", "stage", agari_per_kyoku_percent DESC;
CREATE VIEW "player_season_stage_stats_base" AS with "player_kyoku" as (select "league_season"."start_year" as "pk_start_year", "season_stage"."stage" as "pk_stage", "player"."name" as "pk_player_name", "team"."name" as "pk_team_name", "kyoku"."id" as "pk_kyoku_id", "player"."id" as "pk_player_id" from "kyoku" inner join "game" on "kyoku"."game_id" = "game"."id" inner join "season_stage" on "game"."season_stage_id" = "season_stage"."id" inner join "league_season" on "season_stage"."league_season_id" = "league_season"."id" inner join "kyoku_player_result" on "kyoku"."id" = "kyoku_player_result"."kyoku_id" inner join "player" on "kyoku_player_result"."player_id" = "player"."id" inner join "game_player_result" on ("game_player_result"."game_id" = "kyoku"."game_id" and "game_player_result"."player_id" = "player"."id") inner join "team" on "game_player_result"."team_id" = "team"."id"), "game_results" as (select "league_season"."start_year" as "gr_start_year", "season_stage"."stage" as "gr_stage", "game_player_result"."player_id" as "gr_player_id", "game_player_result"."rank" as "gr_rank", "game_player_result"."score" as "gr_score", "game_player_result"."league_points" as "gr_points", "game_player_result"."penalty_league_points" as "gr_penalty_points" from "game_player_result" inner join "game" on "game_player_result"."game_id" = "game"."id" inner join "season_stage" on "game"."season_stage_id" = "season_stage"."id" inner join "league_season" on "season_stage"."league_season_id" = "league_season"."id"), "kyoku_counts" as (select "pk_start_year" as "kc_start_year", "pk_stage" as "kc_stage", "pk_player_id" as "kc_player_id", "pk_player_name" as "kc_player_name", "pk_team_name" as "kc_team_name", COUNT(DISTINCT "pk_kyoku_id") as "kc_total_kyoku" from "player_kyoku" group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id", player_kyoku."pk_player_name", player_kyoku."pk_team_name"), "win_stats" as (select "pk_start_year" as "ws_start_year", "pk_stage" as "ws_stage", "pk_player_id" as "ws_player_id", COUNT(ae.event_id) as "ws_win_count", SUM(CASE WHEN ae.event_id IS NOT NULL THEN ae.agari_points END) as "ws_win_point_total", COUNT(CASE WHEN ae.event_id IS NOT NULL AND e_win.type = 'tsumo' THEN ae.event_id END) as "ws_tsumo_win_count", SUM(CASE WHEN ae.event_id IS NOT NULL THEN ae.honba_points END) as "ws_win_honba_points", SUM(CASE WHEN ae.event_id IS NOT NULL THEN ae.kyotaku_points END) as "ws_win_kyotaku_points", SUM(CASE WHEN ae.event_id IS NOT NULL THEN k_win.kyotaku_count * 1000 END) as "ws_carryover_kyotaku_point_total", COUNT(CASE WHEN ae.event_id IS NOT NULL AND ae.is_menzen = 0 THEN ae.event_id END) as "ws_furo_agari_count" from "player_kyoku" left join "kyoku" "k_win" on "pk_kyoku_id" = k_win.id left join "event" "e_win" on ("pk_kyoku_id" = e_win.kyoku_id and e_win.type IN ('ron', 'tsumo')) left join "agari_event" "ae" on (e_win.id = ae.event_id and ae.actor_player_id = "pk_player_id") group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "dealin_stats" as (select "pk_start_year" as "ds_start_year", "pk_stage" as "ds_stage", "pk_player_id" as "ds_player_id", COUNT(ae_dealin.event_id) as "ds_dealin_count", SUM(CASE WHEN ae_dealin.event_id IS NOT NULL THEN ae_dealin.agari_points END) as "ds_dealin_point_total", COUNT(ae_hitsumo.event_id) as "ds_hitsumo_count" from "player_kyoku" left join "event" "e_dealin" on ("pk_kyoku_id" = e_dealin.kyoku_id and e_dealin.type = 'ron') left join "agari_event" "ae_dealin" on (e_dealin.id = ae_dealin.event_id and ae_dealin.target_player_id = "pk_player_id") left join "event" "e_hitsumo" on ("pk_kyoku_id" = e_hitsumo.kyoku_id and e_hitsumo.type = 'tsumo') left join "agari_event" "ae_hitsumo" on (e_hitsumo.id = ae_hitsumo.event_id and ae_hitsumo.actor_player_id != "pk_player_id") group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "reach_stats" as (select "pk_start_year" as "rs_start_year", "pk_stage" as "rs_stage", "pk_player_id" as "rs_player_id", COUNT(re.event_id) as "rs_reach_count", COUNT(re_declare.event_id) as "rs_reach_declare_dealin_count" from "player_kyoku" left join "event" "e_reach" on ("pk_kyoku_id" = e_reach.kyoku_id and e_reach.type = 'reach') left join "reach_event" "re" on (e_reach.id = re.event_id and re.actor_player_id = "pk_player_id" and re.is_accepted = 1) left join "reach_event" "re_declare" on (e_reach.id = re_declare.event_id and re_declare.actor_player_id = "pk_player_id" and re_declare.is_accepted = 0) group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "reach_agari_stats" as (select "pk_start_year" as "ras_start_year", "pk_stage" as "ras_stage", "pk_player_id" as "ras_player_id", COUNT(DISTINCT CASE WHEN ae_ras.event_id IS NOT NULL AND re_ras.event_id IS NOT NULL THEN "pk_kyoku_id" END) as "ras_reach_agari_count", COUNT(DISTINCT CASE WHEN ae_rdl.event_id IS NOT NULL AND re_ras.event_id IS NOT NULL THEN "pk_kyoku_id" END) as "ras_reach_dealin_count" from "player_kyoku" left join "event" "e_win_ras" on ("pk_kyoku_id" = e_win_ras.kyoku_id and e_win_ras.type IN ('ron', 'tsumo')) left join "agari_event" "ae_ras" on (e_win_ras.id = ae_ras.event_id and ae_ras.actor_player_id = "pk_player_id") left join "event" "e_reach_ras" on ("pk_kyoku_id" = e_reach_ras.kyoku_id and e_reach_ras.type = 'reach') left join "reach_event" "re_ras" on (e_reach_ras.id = re_ras.event_id and re_ras.actor_player_id = "pk_player_id" and re_ras.is_accepted = 1) left join "event" "e_ron_rdl" on ("pk_kyoku_id" = e_ron_rdl.kyoku_id and e_ron_rdl.type = 'ron') left join "agari_event" "ae_rdl" on (e_ron_rdl.id = ae_rdl.event_id and ae_rdl.target_player_id = "pk_player_id") group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "dora_stats" as (select "pk_start_year" as "ds2_start_year", "pk_stage" as "ds2_stage", "pk_player_id" as "ds2_player_id", COALESCE(SUM(CASE WHEN yn_dora.name = 'ドラ' THEN aye_dora.han END), 0) as "ds2_dora_total", COALESCE(SUM(CASE WHEN yn_dora.name = '赤ドラ' THEN aye_dora.han END), 0) as "ds2_aka_dora_total", COALESCE(SUM(CASE WHEN yn_dora.name = '裏ドラ' THEN aye_dora.han END), 0) as "ds2_ura_dora_total", COUNT(DISTINCT CASE WHEN yn_dora.name = '裏ドラ' THEN ae_dora.event_id END) as "ds2_ura_dora_win_count" from "player_kyoku" left join "event" "e_win_dora" on ("pk_kyoku_id" = e_win_dora.kyoku_id and e_win_dora.type IN ('ron', 'tsumo')) left join "agari_event" "ae_dora" on (e_win_dora.id = ae_dora.event_id and ae_dora.actor_player_id = "pk_player_id") left join "agari_yaku" "aye_dora" on ae_dora.event_id = aye_dora.agari_event_id left join "yaku_name" "yn_dora" on (aye_dora.yaku_name_id = yn_dora.id and yn_dora.name IN ('ドラ', '赤ドラ', '裏ドラ')) group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "renchan_stats" as (select "pk_start_year" as "rcs_start_year", "pk_stage" as "rcs_stage", "pk_player_id" as "rcs_player_id", COUNT(DISTINCT CASE WHEN k_rc.id IS NOT NULL AND (ae_rc.event_id IS NOT NULL OR rpe_rc.ryukyoku_event_id IS NOT NULL) THEN "pk_kyoku_id" END) as "rcs_renchan_count" from "player_kyoku" left join "kyoku" "k_rc" on ("pk_kyoku_id" = k_rc.id and k_rc.oya_player_id = "pk_player_id") left join "event" "e_win_rc" on ("pk_kyoku_id" = e_win_rc.kyoku_id and e_win_rc.type IN ('ron', 'tsumo')) left join "agari_event" "ae_rc" on (e_win_rc.id = ae_rc.event_id and ae_rc.actor_player_id = "pk_player_id") left join "event" "e_ryukyoku_rc" on ("pk_kyoku_id" = e_ryukyoku_rc.kyoku_id and e_ryukyoku_rc.type = 'ryukyoku') left join "ryukyoku_player" "rpe_rc" on (e_ryukyoku_rc.id = rpe_rc.ryukyoku_event_id and rpe_rc.player_id = "pk_player_id" and rpe_rc.is_tenpai = 1) group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "furo_stats" as (select "pk_start_year" as "fs_start_year", "pk_stage" as "fs_stage", "pk_player_id" as "fs_player_id", COUNT(DISTINCT CASE WHEN ce.event_id IS NOT NULL OR pe.event_id IS NOT NULL OR dke.event_id IS NOT NULL THEN "pk_kyoku_id" END) as "fs_furo_count" from "player_kyoku" left join "event" "e_chi" on ("pk_kyoku_id" = e_chi.kyoku_id and e_chi.type = 'chi') left join "chi_event" "ce" on (e_chi.id = ce.event_id and ce.actor_player_id = "pk_player_id") left join "event" "e_pon" on ("pk_kyoku_id" = e_pon.kyoku_id and e_pon.type = 'pon') left join "pon_event" "pe" on (e_pon.id = pe.event_id and pe.actor_player_id = "pk_player_id") left join "event" "e_kan" on ("pk_kyoku_id" = e_kan.kyoku_id and e_kan.type = 'daiminkan') left join "daiminkan_event" "dke" on (e_kan.id = dke.event_id and dke.actor_player_id = "pk_player_id") group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "ryukyoku_stats" as (select "pk_start_year" as "rys_start_year", "pk_stage" as "rys_stage", "pk_player_id" as "rys_player_id", COUNT(rpe.ryukyoku_event_id) as "rys_ryukyoku_count", COUNT(CASE WHEN rpe.is_tenpai = 1 THEN 1 END) as "rys_tenpai_count", SUM(COALESCE(rpe.tenpai_points, 0)) as "rys_tenpai_point_total" from "player_kyoku" left join "event" "e_ryukyoku" on ("pk_kyoku_id" = e_ryukyoku.kyoku_id and e_ryukyoku.type = 'ryukyoku') left join "ryukyoku_player" "rpe" on (e_ryukyoku.id = rpe.ryukyoku_event_id and rpe.player_id = "pk_player_id") group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "oya_kaburi" as (select "pk_start_year" as "ok_start_year", "pk_stage" as "ok_stage", "pk_player_id" as "ok_player_id", COUNT(CASE WHEN k_ok.oya_player_id IS NOT NULL THEN 1 END) as "ok_oya_kyoku_count", COUNT(CASE WHEN k_ok.oya_player_id IS NOT NULL AND ae_ok_all.event_id IS NOT NULL THEN ae_ok_all.event_id END) as "ok_oya_kaburi_count", COUNT(CASE WHEN k_ok.oya_player_id IS NOT NULL AND ae_ok.event_id IS NOT NULL THEN ae_ok.event_id END) as "ok_itai_oya_kaburi_count", SUM(CASE WHEN k_ok.oya_player_id IS NOT NULL AND ae_ok.event_id IS NOT NULL THEN ae_ok.agari_points END) as "ok_itai_oya_kaburi_point_total" from "player_kyoku" left join "kyoku" "k_ok" on ("pk_kyoku_id" = k_ok.id and k_ok.oya_player_id = "pk_player_id") left join "event" "e_ok" on ("pk_kyoku_id" = e_ok.kyoku_id and e_ok.type = 'tsumo') left join "agari_event" "ae_ok_all" on (e_ok.id = ae_ok_all.event_id and ae_ok_all.actor_player_id != "pk_player_id") left join "agari_event" "ae_ok" on (e_ok.id = ae_ok.event_id and ae_ok.actor_player_id != "pk_player_id" and ae_ok.agari_points >= 8000) group by player_kyoku."pk_start_year", player_kyoku."pk_stage", player_kyoku."pk_player_id"), "stats" as (select "kc_start_year" as "st_start_year", "kc_stage" as "st_stage", "kc_player_id" as "st_player_id", "kc_player_name" as "st_player_name", "kc_team_name" as "st_team_name", "kc_total_kyoku" as "st_total_kyoku", "ws_win_count" as "st_win_count", "ws_win_point_total" as "st_win_point_total", "ws_tsumo_win_count" as "st_tsumo_win_count", "ds_dealin_count" as "st_dealin_count", "ds_dealin_point_total" as "st_dealin_point_total", "ds_hitsumo_count" as "st_hitsumo_count", "rs_reach_count" as "st_reach_count", COALESCE("rs_reach_declare_dealin_count", 0) as "st_reach_declare_dealin_count", "ras_reach_agari_count" as "st_reach_agari_count", "ras_reach_dealin_count" as "st_reach_dealin_count", COALESCE("ws_carryover_kyotaku_point_total", 0) as "st_carryover_kyotaku_point_total", COALESCE("ws_win_kyotaku_points", 0) - "ras_reach_agari_count" * 1000 as "st_kyotaku_points_excluding_own_reach_total", COALESCE("ws_win_kyotaku_points", 0) + COALESCE("ws_win_honba_points", 0) - "ras_reach_agari_count" * 1000 as "st_kyotaku_honba_points_excluding_own_reach_total", COALESCE("ws_win_honba_points", 0) as "st_honba_points_total", "ws_furo_agari_count" as "st_furo_agari_count", "ds2_dora_total" as "st_dora_total", "ds2_aka_dora_total" as "st_aka_dora_total", "ds2_ura_dora_total" as "st_ura_dora_total", "ds2_ura_dora_win_count" as "st_ura_dora_win_count", "rcs_renchan_count" as "st_renchan_count", "fs_furo_count" as "st_furo_count", "rys_ryukyoku_count" as "st_ryukyoku_count", "rys_tenpai_count" as "st_tenpai_count", "rys_tenpai_point_total" as "st_tenpai_point_total", "ok_oya_kyoku_count" as "st_oya_kyoku_count", "ok_oya_kaburi_count" as "st_oya_kaburi_count", "ok_itai_oya_kaburi_count" as "st_itai_oya_kaburi_count", "ok_itai_oya_kaburi_point_total" as "st_itai_oya_kaburi_point_total" from "kyoku_counts" left join "win_stats" on ("kc_start_year" = "ws_start_year" and "kc_stage" = "ws_stage" and "kc_player_id" = "ws_player_id") left join "dealin_stats" on ("kc_start_year" = "ds_start_year" and "kc_stage" = "ds_stage" and "kc_player_id" = "ds_player_id") left join "reach_stats" on ("kc_start_year" = "rs_start_year" and "kc_stage" = "rs_stage" and "kc_player_id" = "rs_player_id") left join "reach_agari_stats" on ("kc_start_year" = "ras_start_year" and "kc_stage" = "ras_stage" and "kc_player_id" = "ras_player_id") left join "dora_stats" on ("kc_start_year" = "ds2_start_year" and "kc_stage" = "ds2_stage" and "kc_player_id" = "ds2_player_id") left join "renchan_stats" on ("kc_start_year" = "rcs_start_year" and "kc_stage" = "rcs_stage" and "kc_player_id" = "rcs_player_id") left join "furo_stats" on ("kc_start_year" = "fs_start_year" and "kc_stage" = "fs_stage" and "kc_player_id" = "fs_player_id") left join "ryukyoku_stats" on ("kc_start_year" = "rys_start_year" and "kc_stage" = "rys_stage" and "kc_player_id" = "rys_player_id") left join "oya_kaburi" on ("kc_start_year" = "ok_start_year" and "kc_stage" = "ok_stage" and "kc_player_id" = "ok_player_id")), "rank_stats" as (select "gr_start_year" as "rs_start_year", "gr_stage" as "rs_stage", "gr_player_id" as "rs_player_id", COUNT(*) as "rs_total_games", COUNT(CASE WHEN "gr_rank" = 1 THEN 1 END) as "rs_rank1_count", COUNT(CASE WHEN "gr_rank" = 2 THEN 1 END) as "rs_rank2_count", COUNT(CASE WHEN "gr_rank" = 3 THEN 1 END) as "rs_rank3_count", COUNT(CASE WHEN "gr_rank" = 4 THEN 1 END) as "rs_rank4_count", MAX("gr_score") as "rs_best_score", ROUND(SUM("gr_points" + "gr_penalty_points"), 1) as "rs_total_points" from "game_results" group by game_results."gr_start_year", game_results."gr_stage", game_results."gr_player_id") select "st_start_year" as "season_start_year", "st_stage" as "stage", "st_player_name" as "player_name", "st_team_name" as "team_name", "st_total_kyoku" as "total_kyoku_count", "rs_total_games" as "total_game_count", "st_win_count" as "agari_count", "st_win_point_total" as "agari_points_total", "st_tsumo_win_count" as "tsumo_agari_count", "st_dealin_count" as "dealin_count", "st_dealin_point_total" as "dealin_points_total", "st_hitsumo_count" as "hitsumo_count", "st_reach_count" as "reach_count", "st_reach_agari_count" as "reach_agari_count", "st_furo_agari_count" as "furo_agari_count", "st_reach_dealin_count" as "reach_dealin_count", "st_reach_declare_dealin_count" as "reach_declare_dealin_count", "st_carryover_kyotaku_point_total" as "carryover_kyotaku_points_total", "st_kyotaku_points_excluding_own_reach_total" as "kyotaku_points_excluding_own_reach_total", "st_kyotaku_honba_points_excluding_own_reach_total" as "kyotaku_honba_points_excluding_own_reach_total", "st_honba_points_total" as "honba_points_total", "st_dora_total" as "dora_total", "st_aka_dora_total" as "aka_dora_total", "st_ura_dora_total" as "ura_dora_total", "st_ura_dora_win_count" as "ura_dora_agari_count", "st_renchan_count" as "renchan_count", "st_furo_count" as "furo_count", "st_ryukyoku_count" as "ryukyoku_count", "st_tenpai_count" as "tenpai_count", "st_tenpai_point_total" as "tenpai_points_total", "st_oya_kyoku_count" as "oya_kyoku_count", "st_oya_kaburi_count" as "oya_kaburi_count", "st_itai_oya_kaburi_count" as "itai_oya_kaburi_count", "st_itai_oya_kaburi_point_total" as "itai_oya_kaburi_points_total", "rs_rank1_count" as "rank1_count", "rs_rank2_count" as "rank2_count", "rs_rank3_count" as "rank3_count", "rs_rank4_count" as "rank4_count", "rs_best_score" as "best_score", "rs_total_points" as "league_points_total" from "stats" left join "rank_stats" on ("st_start_year" = "rs_start_year" and "st_stage" = "rs_stage" and "st_player_id" = "rs_player_id") order by season_start_year, stage, agari_count DESC;
CREATE VIEW "player_tenpai_waiting_tile" AS select distinct "tenpai_agari_matrix"."event_id" as "event_id", "tenpai_agari_matrix"."player_id" as "player_id", "tenpai_agari_matrix"."waiting_tile" as "waiting_tile", "tenpai_agari_matrix"."available_tile_count" as "available_tile_count", "tenpai_agari_matrix"."ideal_tile_count" as "ideal_tile_count", "tenpai_agari_matrix"."discarded_tile_count" as "discarded_tile_count", "tenpai_agari_matrix"."dora_indicator_tile_count" as "dora_indicator_tile_count", "player_tenpai_state"."tile_type_count" as "total_tile_type_count", "player_tenpai_state"."available_tile_count" as "total_available_tile_count", "player_tenpai_state"."ideal_tile_count" as "total_ideal_tile_count", "player_tenpai_state"."discarded_tile_count" as "total_discarded_tile_count", "player_tenpai_state"."dora_indicator_tile_count" as "total_dora_indicator_tile_count" from "tenpai_agari_matrix" inner join "player_tenpai_state" on ("tenpai_agari_matrix"."event_id" = "player_tenpai_state"."event_id" and "tenpai_agari_matrix"."player_id" = "player_tenpai_state"."player_id");
CREATE VIEW "team_season_stage_result" AS with "with_stage_points" as (select "game_player_result"."team_id" as "with_team_id", "league_season"."id" as "with_season_id", "league_season"."start_year" as "with_season_year", "season_stage"."stage" as "with_stage", SUM("game_player_result"."league_points" + "game_player_result"."penalty_league_points") as "with_points" from "game_player_result" inner join "game" on "game_player_result"."game_id" = "game"."id" inner join "season_stage" on "game"."season_stage_id" = "season_stage"."id" inner join "league_season" on "season_stage"."league_season_id" = "league_season"."id" group by "game_player_result"."team_id", "league_season"."id", "league_season"."start_year", "season_stage"."stage") select "team"."id" as "team_id", "team"."name" as "team_name", "league_season"."start_year" as "season_start_year", "league_season"."end_year" as "season_end_year", "season_stage"."stage" as "stage", ROUND("with_points", 1) as "stage_league_points", ROUND(
          "with_points" +
          CASE
            WHEN "season_stage"."stage" = 'regular' THEN 0
            WHEN "season_stage"."stage" = 'semifinal' THEN COALESCE((
              SELECT tsp.with_points / 2
              FROM "with_stage_points" tsp
              WHERE tsp.with_team_id = "team"."id"
                AND tsp.with_season_id = "league_season"."id"
                AND tsp.with_stage = 'regular'
            ), 0)
            WHEN "season_stage"."stage" = 'final' AND NOT EXISTS (
              SELECT 1 FROM "with_stage_points" tsp
              WHERE tsp.with_season_id = "league_season"."id"
                AND tsp.with_stage = 'semifinal'
            ) THEN COALESCE((
              SELECT tsp.with_points / 2
              FROM "with_stage_points" tsp
              WHERE tsp.with_team_id = "team"."id"
                AND tsp.with_season_id = "league_season"."id"
                AND tsp.with_stage = 'regular'
            ), 0)
            WHEN "season_stage"."stage" = 'final' THEN COALESCE((
              SELECT (
                COALESCE((SELECT tsp.with_points FROM "with_stage_points" tsp WHERE tsp.with_team_id = "team"."id" AND tsp.with_season_id = "league_season"."id" AND tsp.with_stage = 'semifinal'), 0) +
                COALESCE((SELECT tsp.with_points FROM "with_stage_points" tsp WHERE tsp.with_team_id = "team"."id" AND tsp.with_season_id = "league_season"."id" AND tsp.with_stage = 'regular'), 0) / 2
              ) / 2
            ), 0)
            ELSE 0
          END
        , 3) as "final_league_points" from "team" inner join "game_player_result" on "team"."id" = "game_player_result"."team_id" inner join "game" on "game_player_result"."game_id" = "game"."id" inner join "season_stage" on "game"."season_stage_id" = "season_stage"."id" inner join "league_season" on "season_stage"."league_season_id" = "league_season"."id" inner join "with_stage_points" on ("with_team_id" = "team"."id" and "with_season_id" = "league_season"."id" and "with_stage" = "season_stage"."stage") group by "team"."id", "team"."name", "league_season"."start_year", "league_season"."end_year", "season_stage"."stage", "league_season"."id", "with_points" order by "league_season"."start_year", CASE WHEN "season_stage"."stage" = 'regular' THEN 1 WHEN "season_stage"."stage" = 'semifinal' THEN 2 WHEN "season_stage"."stage" = 'final' THEN 3 ELSE 4 END, final_league_points DESC;
