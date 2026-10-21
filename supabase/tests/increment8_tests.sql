-- Run in the Supabase SQL Editor AFTER migration_008. Everything is rolled back at the end.
-- Note: a transaction has one fixed now(), so the tests move time by editing timestamps instead of waiting.
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  ps uuid; pd uuid; pc uuid; pt uuid; r jsonb; rq uuid; coins0 int; rh0 int; gems0 int; it uuid;
begin
  insert into auth.users (id, email) values (a,'t8-a@example.com'), (b,'t8-b@example.com'), (c,'t8-c@example.com');
  perform pg_temp._as(a);
  -- keep achievement XP out of the way for player a (it is tested separately with player b)
  insert into xp_events (user_id, kind, amount, idem_key) select a, 'achievement', 0, 'ach:' || id from achievements;

  -- config
  assert (cfg('growth')->'rarity_mult'->>'epic')::numeric = 2, 'epic multiplier';
  assert (cfg('discovery')->'duplicate_rhizomes'->>'legendary')::int = 8, 'legendary duplicate = 8 rhizomes';

  -- rarity changes how long a stage takes (base 12h for stage 1 to 2)
  perform _give_plant(a, 'sword', 'discovery:basic'); perform _give_plant(a, 'dark', 'discovery:basic');
  ps := (select id from plants where user_id = a and type = 'sword');   -- uncommon x1.3
  pd := (select id from plants where user_id = a and type = 'dark');    -- epic x2
  assert (_plant_json((select p from plants p where p.id = ps))->>'xp_needed')::numeric = 15.6, 'uncommon stage 1 needs 15.6h';
  assert (_plant_json((select p from plants p where p.id = pd))->>'xp_needed')::numeric = 24, 'epic stage 1 needs 24h';
  assert (_plant_json((select p from plants p where p.id = ps))->>'eta_hours')::numeric = 15.6, 'eta without a boost';
  assert (select xp from profiles where id = a) = 30, 'two new plants earn 15 XP each';

  -- stage XP is paid once
  update plants set growth_hours = 0, moisture = 100, moisture_at = now() - interval '16 hours' where id = ps;
  perform get_game_state();
  assert (select stage from plants where id = ps) = 2, '16h passes the 15.6h needed';
  assert (select xp from profiles where id = a) = 40, 'stage 1 to 2 pays 10 XP';
  perform get_game_state();
  assert (select xp from profiles where id = a) = 40, 'stage XP paid twice';

  -- level up: rewards, event, acknowledgement
  update profiles set xp = 95, leaf_coins = 0, rhizomes = 0 where id = a;
  update plants set growth_hours = 40, moisture = 100, moisture_at = now() - interval '10 hours' where id = ps;
  perform get_game_state();
  assert (select stage from plants where id = ps) = 3, 'plant should reach stage 3';
  assert (select level from profiles where id = a) = 2 and (select xp from profiles where id = a) = 15, 'stage 2 to 3 pays 20 XP: level 2, 15 left';
  assert (select leaf_coins from profiles where id = a) = 50 and (select rhizomes from profiles where id = a) = 1, 'level 2 pays 50 coins and 1 rhizome';
  assert jsonb_array_length(get_game_state()->'level_ups') = 1, 'level-up should be reported once';
  perform ack_level_ups();
  assert jsonb_array_length(get_game_state()->'level_ups') = 0, 'level-up still reported after acknowledgement';
  perform get_game_state();
  assert (select leaf_coins from profiles where id = a) = 50, 'level rewards paid twice';
  -- every 5th level pays a gem
  update profiles set level = 4, xp = 395, collector_gems = 0 where id = a;
  perform _add_xp(a, 10, 'test', 'test-xp-1');
  assert (select level from profiles where id = a) = 5 and (select collector_gems from profiles where id = a) = 1, 'level 5 pays 1 gem';
  perform _add_xp(a, 10, 'test', 'test-xp-1');
  assert (select xp from profiles where id = a) = 5, 'the same XP event counted twice';

  -- the browser cannot touch XP or levels
  begin execute 'set local role authenticated'; update profiles set xp = 999 where id = a; assert false, 'direct XP write allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  begin execute 'set local role authenticated'; perform _add_xp(a, 100, 'x', 'x'); assert false, 'browser called _add_xp';
  exception when insufficient_privilege then null; end;
  execute 'reset role';

  -- bought boosts: price scales with rarity (uncommon x1.25: 125 coins or 3 rhizomes)
  update profiles set leaf_coins = 1000, rhizomes = 10 where id = a;
  rq := gen_random_uuid();
  r := buy_boost(ps, '2x', 'leaf_coins', rq);
  assert (r->>'cost')::int = 125 and (select leaf_coins from profiles where id = a) = 875, '2x boost for an uncommon costs 125 coins';
  assert (select boost_mult from plants where id = ps) = 2 and (select xp_boost_until from plants where id = ps) between now() + interval '23 hours' and now() + interval '25 hours', '2x for about 24h';
  r := buy_boost(ps, '2x', 'leaf_coins', rq);
  assert (r->>'replay')::boolean and (select leaf_coins from profiles where id = a) = 875, 'repeated request charged again';
  begin perform buy_boost(ps, '5x', 'leaf_coins', gen_random_uuid()); assert false, 'second boost allowed while one is active';
  exception when raise_exception then null; end;
  assert (select leaf_coins from profiles where id = a) = 875, 'refused boost charged coins';
  begin perform buy_boost(pd, '9x', 'leaf_coins', gen_random_uuid()); assert false, 'unknown boost accepted'; exception when raise_exception then null; end;
  begin perform buy_boost(pd, '5x', 'gold', gen_random_uuid()); assert false, 'unknown payment accepted'; exception when raise_exception then null; end;
  -- epic 5x in rhizomes: 3 x 2 = 6
  update profiles set rhizomes = 5 where id = a;
  begin perform buy_boost(pd, '5x', 'rhizomes', gen_random_uuid()); assert false, 'bought without enough rhizomes'; exception when raise_exception then null; end;
  assert (select rhizomes from profiles where id = a) = 5 and (select boost_mult from plants where id = pd) = 1, 'failed purchase changed something';
  update profiles set rhizomes = 10 where id = a;
  perform buy_boost(pd, '5x', 'rhizomes', gen_random_uuid());
  assert (select rhizomes from profiles where id = a) = 4, 'epic 5x costs 6 rhizomes';
  -- the boost multiplies growth: 5h at 5x = 25 hours of growth
  update plants set growth_hours = 0, stage = 1, stage_seen = 1, moisture = 100, moisture_at = now() - interval '5 hours' where id = pd;
  perform get_game_state();
  assert abs((select growth_hours from plants where id = pd) - 25) < 0.01, '5x boost for 5h should give 25h of growth';
  -- time to next stage is divided by the boost
  update plants set growth_hours = 0, stage = 1, moisture_at = now() where id = ps;
  assert (_plant_json((select p from plants p where p.id = ps))->>'eta_hours')::numeric = 7.8, '15.6h at 2x = 7.8h';
  -- an ended boost no longer shows
  update plants set xp_boost_until = now() - interval '1 hour' where id = ps;
  assert _plant_json((select p from plants p where p.id = ps))->>'boost_mult' is null, 'ended boost still shown';
  -- other players cannot use my plant
  perform pg_temp._as(b);
  begin perform buy_boost(ps, '2x', 'leaf_coins', gen_random_uuid()); assert false, 'boosted another player''s plant'; exception when raise_exception then null; end;
  begin perform skip_stage(ps, gen_random_uuid()); assert false, 'skipped another player''s plant'; exception when raise_exception then null; end;
  perform pg_temp._as(a);

  -- gem skips: rare costs 2, 3, 4, 5
  perform _give_plant(a, 'cream', 'discovery:basic');
  pc := (select id from plants where user_id = a and type = 'cream');
  update profiles set collector_gems = 10 where id = a;
  rq := gen_random_uuid();
  r := skip_stage(pc, rq);
  assert (r->>'stage')::int = 2 and (r->>'cost')::int = 2 and (select collector_gems from profiles where id = a) = 8, 'rare 1 to 2 costs 2 gems';
  assert abs((select growth_hours from plants where id = pc) - 19.2) < 0.01, 'skip resets XP to the start of the new stage (12h x 1.6)';
  assert (select count(*) from xp_events where user_id = a and idem_key = 'stage:' || pc || ':2') = 1, 'skip should pay stage XP';
  r := skip_stage(pc, rq);
  assert (r->>'replay')::boolean and (select collector_gems from profiles where id = a) = 8, 'repeated skip charged again';
  r := skip_stage(pc, gen_random_uuid());
  assert (r->>'stage')::int = 3 and (select collector_gems from profiles where id = a) = 5, 'rare 2 to 3 costs 3 gems';
  update profiles set collector_gems = 0 where id = a;
  begin perform skip_stage(pc, gen_random_uuid()); assert false, 'skipped without gems'; exception when raise_exception then null; end;
  assert (select stage from plants where id = pc) = 3, 'failed skip moved the plant';
  update plants set growth_hours = 100000 where id = pc;
  perform get_game_state();
  assert (select stage from plants where id = pc) = 5 and (select final_rewarded from plants where id = pc), 'plant should be fully grown';
  update profiles set collector_gems = 10 where id = a;
  begin perform skip_stage(pc, gen_random_uuid()); assert false, 'skipped a fully grown plant'; exception when raise_exception then null; end;
  -- 20-stage plants jump to the start of the next growth phase (stage 1 to stage 5)
  perform _give_plant(a, 'trifasciata', 'discovery:basic');
  pt := (select id from plants where user_id = a and type = 'trifasciata');
  r := skip_stage(pt, gen_random_uuid());
  assert (r->>'stage')::int = 5 and (r->>'cost')::int = 1 and (select collector_gems from profiles where id = a) = 9, 'common tall plant: next phase starts at stage 5 for 1 gem';

  -- duplicates: Rhizomes (+5 XP) or a free 2x boost (not on an already boosted plant)
  update game_config set value = jsonb_set(jsonb_set(value, '{tiers,basic,odds}', '{"common":0,"uncommon":0,"rare":0,"epic":0,"legendary":100}'), '{cooldown_seconds}', '0') where key = 'discovery';
  perform _give_plant(a, 'coppertone', 'discovery:basic');
  update profiles set leaf_coins = 500, rhizomes = 0, xp = 0 where id = a;
  r := discover('basic', gen_random_uuid());
  it := (r->>'duplicate_item_id')::uuid;
  perform resolve_duplicate(it, 'rhizomes');
  assert (select rhizomes from profiles where id = a) = 8 and (select xp from profiles where id = a) = 5, 'legendary duplicate: 8 rhizomes and 5 XP';
  r := discover('basic', gen_random_uuid());
  perform resolve_duplicate((r->>'duplicate_item_id')::uuid, 'double_xp');
  assert (select boost_mult from plants where user_id = a and type = 'coppertone') = 2, 'free boost is 2x';
  r := discover('basic', gen_random_uuid());
  begin perform resolve_duplicate((r->>'duplicate_item_id')::uuid, 'double_xp'); assert false, 'boosted a plant that already has a boost';
  exception when raise_exception then null; end;
  assert (select resolved_at from duplicate_items where id = (r->>'duplicate_item_id')::uuid) is null, 'refused duplicate was used up';

  -- admin-granted plants and admin stage changes pay no XP
  update profiles set is_admin = true, xp = 0 where id = a;
  perform admin_grant_plant('siamsilver');
  perform admin_set_stage((select id from plants where user_id = a and type = 'siamsilver'), 4);
  perform get_game_state();
  assert (select xp from profiles where id = a) = 0, 'admin actions must not pay XP';

  -- achievements pay 25 XP once (player b has no muted achievements)
  perform pg_temp._as(b);
  perform _give_plant(b, 'sword', 'discovery:basic');
  perform get_game_state();
  assert (select xp from profiles where id = b) = 40, 'new plant 15 + First Discovery 25';
  perform claim_achievement('first_discovery'); perform get_game_state();
  assert (select xp from profiles where id = b) = 40, 'claiming must not pay XP again';

  -- while you were away
  perform pg_temp._as(c);
  assert get_away_summary() is null, 'a first-time player has nothing to summarise';
  perform _give_plant(c, 'sword', 'discovery:basic');
  perform get_game_state();
  assert get_away_summary() is null, 'just seen: nothing to summarise';
  update profiles set last_seen_at = now() - interval '5 hours' where id = c;
  update plants set growth_hours = 0, moisture = 100, moisture_at = now() - interval '16 hours' where user_id = c;
  r := get_away_summary();
  assert jsonb_array_length(r->'grown') = 1 and (r->'grown'->0->>'from')::int = 1 and (r->'grown'->0->>'to')::int = 2, 'summary should list the plant that grew';
  assert jsonb_array_length(r->'achievements') >= 1, 'summary should list achievements completed while away';
  assert jsonb_array_length(r->'needs_water') = 0, 'a hydrated plant needs no water';
  perform get_game_state();
  assert get_away_summary() is null, 'after viewing the garden the summary is empty';
  -- boost ended and thirsty plants
  update profiles set last_seen_at = now() - interval '5 hours' where id = c;
  update plants set moisture = 5, moisture_at = now(), xp_boost_until = now() - interval '1 hour', boost_mult = 2 where user_id = c;
  r := get_away_summary();
  assert jsonb_array_length(r->'boosts_ended') = 1 and jsonb_array_length(r->'needs_water') = 1, 'boost ended and plant thirsty';
  raise notice 'All Increment 8 tests passed';
end $$;
rollback;
