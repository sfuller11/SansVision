-- Run in the Supabase SQL Editor AFTER migration_012. Everything is rolled back at the end.
-- Older game tests (increment9 and 10) that expect the old spinner table or "show to visitors" switch are replaced by this file for those parts.
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid(); d uuid := gen_random_uuid();
  ga uuid; gb uuid; gc uuid; pid uuid; p1 uuid; r jsonb; i int; seen int[] := '{}'; coins0 int; rh0 int; gem0 int; x int;
begin
  insert into auth.users (id, email) values (a,'t12-a@example.com'), (b,'t12-b@example.com'), (c,'t12-c@example.com'), (d,'t12-d@example.com');
  perform pg_temp._as(a);

  -- spinner: 3 spins a day, one every 8 hours
  assert (get_games_state()->'games'->'spinner'->>'daily')::int = 3, 'three spins a day';
  r := spin(gen_random_uuid());
  begin perform spin(gen_random_uuid()); assert false, 'second spin inside 8 hours'; exception when raise_exception then null; end;
  update game_plays set started_at = now() - interval '9 hours' where user_id = a;
  perform spin(gen_random_uuid());
  update game_plays set started_at = now() - interval '9 hours' where user_id = a;
  perform spin(gen_random_uuid());
  update game_plays set started_at = now() - interval '9 hours' where user_id = a;
  begin perform spin(gen_random_uuid()); assert false, 'fourth spin in one day'; exception when raise_exception then null; end;
  -- the prize table: coin prizes are 100 to 200; the two big prizes pay only 5 Rhizomes or only 1 Gem
  for i in 1..400 loop
    delete from game_plays where user_id = a and game = 'spinner';
    r := spin(gen_random_uuid());
    seen := seen || (r->>'segment')::int;
    assert (r->>'segment')::int between 0 and 5, 'segment range';
    case (r->>'segment')::int
      when 0 then assert (r->>'coins')::int = 100 and (r->>'rhizomes')::int = 0 and (r->>'gems')::int = 0, 'seg 0';
      when 1 then assert (r->>'coins')::int = 125 and (r->>'rhizomes')::int = 0, 'seg 1';
      when 2 then assert (r->>'coins')::int = 150 and (r->>'rhizomes')::int = 1, 'seg 2';
      when 3 then assert (r->>'coins')::int = 200 and (r->>'rhizomes')::int = 2, 'seg 3';
      when 4 then assert (r->>'coins')::int = 0 and (r->>'rhizomes')::int = 5 and (r->>'gems')::int = 0, 'seg 4';
      else assert (r->>'coins')::int = 0 and (r->>'rhizomes')::int = 0 and (r->>'gems')::int = 1, 'seg 5';
    end case;
  end loop;
  assert 0 = any(seen) and 1 = any(seen) and 2 = any(seen), 'the common prizes come up';
  -- a gem really lands in the wallet
  update profiles set collector_gems = 0 where id = a;
  loop
    delete from game_plays where user_id = a and game = 'spinner';
    r := spin(gen_random_uuid());
    exit when (r->>'segment')::int = 5;
  end loop;
  assert (select collector_gems from profiles where id = a) = 1, 'gem granted';

  -- new games: Water Balance (rounds landed)
  update game_plays set started_at = now() - interval '5 hours' where user_id = a;
  p1 := gen_random_uuid(); perform start_game('water_balance', p1);
  update game_plays set started_at = now() - interval '20 seconds' where id = p1;
  r := finish_game(p1, '{"landed":8}');
  assert (r->>'tier')::int = 4 and (r->>'coins')::int = 100, 'water balance 8 of 8';
  p1 := gen_random_uuid(); perform start_game('water_balance', p1);
  update game_plays set started_at = now() - interval '20 seconds' where id = p1;
  r := finish_game(p1, '{"landed":5}');
  assert (r->>'tier')::int = 2 and (r->>'coins')::int = 40, 'water balance 5 of 8';
  p1 := gen_random_uuid(); perform start_game('water_balance', p1);
  update game_plays set started_at = now() - interval '3 seconds' where id = p1;
  r := finish_game(p1, '{"landed":8}');
  assert r->>'no_reward' = 'too_fast', 'too fast to count';
  -- Vine Climb: drops are capped by elapsed time (20 s allows at most 20)
  update game_plays set started_at = now() - interval '5 hours' where user_id = a;
  p1 := gen_random_uuid(); perform start_game('vine_climb', p1);
  update game_plays set started_at = now() - interval '20 seconds' where id = p1;
  r := finish_game(p1, '{"drops":999}');
  assert (r->>'tier')::int = 3 and (r->>'coins')::int = 60, 'vine climb drops are capped by time';
  p1 := gen_random_uuid(); perform start_game('vine_climb', p1);
  update game_plays set started_at = now() - interval '40 seconds' where id = p1;
  r := finish_game(p1, '{"drops":4}');
  assert (r->>'tier')::int = 1 and (r->>'coins')::int = 20, 'vine climb low score';
  -- Garden Snake
  p1 := gen_random_uuid(); perform start_game('garden_snake', p1);
  update game_plays set started_at = now() - interval '40 seconds' where id = p1;
  r := finish_game(p1, '{"food":30}');
  assert (r->>'tier')::int = 4 and (r->>'coins')::int = 100, 'snake 30 sprouts in 40 s';
  p1 := gen_random_uuid(); perform start_game('garden_snake', p1);
  update game_plays set started_at = now() - interval '10 seconds' where id = p1;
  r := finish_game(p1, '{"food":50}');
  assert (r->>'tier')::int = 2, 'snake sprouts capped at 0.9 per second (9 of 50)';
  p1 := gen_random_uuid(); perform start_game('garden_snake', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"food":"lots"}');
  assert (r->>'tier')::int = 1, 'bad metric counts as zero';
  begin perform start_game('not_a_game', gen_random_uuid()); assert false, 'unknown game'; exception when raise_exception then null; end;
  assert (get_games_state()->'games') ?& array['water_balance','vine_climb','garden_snake','spinner'], 'all games listed';
  -- every finished play counts toward the daily streak
  assert (get_games_state()->'today'->>'completed')::int >= 3, 'plays counted';

  -- garden: placed means shown to visitors
  select id into ga from gardens where owner_id = a;
  perform _give_plant(a, 'dark', 'discovery:basic');
  select id into pid from plants where user_id = a and type = 'dark';
  perform place_plant(pid, ga, 'shelf1');
  update plants set public_display = false where id = pid;                    -- an old hidden flag must not matter any more
  perform set_garden_public(ga, true);
  perform pg_temp._as(b);
  r := visit_garden(ga);
  assert jsonb_array_length(r->'plants') = 1, 'placed plant is visible';
  assert jsonb_array_length(list_public_gardens('recent', 0, 12)->'gardens') = 1, 'garden with a placed plant is listed';
  assert not exists (select 1 from pg_proc where proname = 'set_plant_display'), 'the show-to-visitors switch is gone';
  perform pg_temp._as(a);
  perform place_plant(pid, null, null);                                       -- one-step removal
  assert (select spot from plants where id = pid) is null, 'removed';
  perform pg_temp._as(b);
  assert jsonb_array_length(list_public_gardens('recent', 0, 12)->'gardens') = 0, 'empty garden is not listed';

  -- featured garden
  assert get_featured_garden() is null, 'nothing public to feature';
  perform pg_temp._as(a);
  perform place_plant(pid, ga, 'shelf1');
  perform pg_temp._as(c);
  select id into gc from gardens where owner_id = c;
  perform _give_plant(c, 'marsha', 'discovery:basic');
  perform place_plant((select id from plants where user_id = c and type = 'marsha'), gc, 'shelf1');
  perform set_garden_public(gc, true);
  perform pg_temp._as(d);
  perform toggle_garden_like(gc);                                             -- c gets a like this week
  r := get_featured_garden();
  assert (r->>'id')::uuid = gc and (r->>'week_likes')::int = 1, 'most liked this week is featured';
  assert jsonb_array_length(r->'plants') = 1, 'featured garden includes its plants';
  update garden_likes set created_at = now() - interval '10 days' where garden_id = gc;
  r := get_featured_garden();
  assert (r->>'week_likes')::int = 0, 'old likes do not count';
  -- never your own garden while another exists
  perform pg_temp._as(a);
  r := get_featured_garden();
  assert (r->>'id')::uuid = gc, 'own garden is not featured while another exists';
  assert (select count(*) from game_plays where user_id = d) = 0, 'featuring is not a visit or a play';
  assert not exists (select 1 from garden_visits where visitor_id = d), 'featuring does not record a visit';

  raise notice 'increment 12 tests passed';
end $$;
rollback;
