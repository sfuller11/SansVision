-- Run in the Supabase SQL Editor AFTER migration_010 (it uses Odd Plant Out, which replaced Garden Cleanup). Everything is rolled back at the end.
-- A transaction has one fixed now(), so the tests move time by editing started_at instead of waiting.
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); d uuid := gen_random_uuid();
  p1 uuid; p2 uuid; p3 uuid; r jsonb; s jsonb; i int; today date := (now() at time zone 'utc')::date;
begin
  insert into auth.users (id, email) values (a,'t9-a@example.com'), (b,'t9-b@example.com'), (d,'t9-d@example.com');
  perform pg_temp._as(a);
  update profiles set leaf_coins = 0, rhizomes = 0, collector_gems = 0 where id = a;

  -- a play is recorded once per request id, and finishing too fast pays nothing
  p1 := gen_random_uuid();
  r := start_game('leaf_match', p1);
  assert (r->>'play_id')::uuid = p1, 'play id should be the request id';
  assert (start_game('leaf_match', p1)->>'replay')::boolean, 'a repeated start should not use another play';
  assert (get_games_state()->'games'->'leaf_match'->>'hour_left')::int = 2, 'one of three plays used';
  r := finish_game(p1, '{"misses":0}');
  assert r->>'no_reward' = 'too_fast' and (select leaf_coins from profiles where id = a) = 0, 'an instant finish must not pay';
  assert (finish_game(p1, '{"misses":0}')->>'no_reward') = 'too_fast', 'finishing twice should return the stored result';

  -- Leaf Match perfect: 150 coins + 1 rhizome, perfect XP
  p1 := gen_random_uuid(); perform start_game('leaf_match', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"misses":0}');
  assert (r->>'tier')::int = 4 and (r->>'coins')::int = 150 and (r->>'rhizomes')::int = 1 and (r->>'perfect')::boolean, 'perfect Leaf Match tier';
  assert (select leaf_coins from profiles where id = a) = 150 and (select rhizomes from profiles where id = a) = 1, 'perfect Leaf Match payout';
  assert (select xp from profiles where id = a) = 10, 'perfect game gives 10 XP';
  assert (finish_game(p1, '{"misses":0}')->>'replay')::boolean and (select leaf_coins from profiles where id = a) = 150, 'a repeated finish paid again';
  -- a loose game pays within its band
  p2 := gen_random_uuid(); perform start_game('leaf_match', p2);
  update game_plays set started_at = now() - interval '30 seconds' where id = p2;
  r := finish_game(p2, '{"misses":20}');
  assert (r->>'tier')::int = 1 and (r->>'coins')::int between 20 and 40, 'sloppy Leaf Match pays 20 to 40';
  -- hourly limit: 3 per hour (that was the third)
  begin perform start_game('leaf_match', gen_random_uuid()); assert false, 'fourth Leaf Match this hour allowed'; exception when raise_exception then null; end;
  update game_plays set started_at = now() - interval '2 hours' where user_id = a and game = 'leaf_match';
  perform start_game('leaf_match', gen_random_uuid());     -- the window has moved on
  -- browser cannot start unknown games or touch the tables
  begin perform start_game('slots', gen_random_uuid()); assert false, 'unknown game accepted'; exception when raise_exception then null; end;
  begin execute 'set local role authenticated'; insert into game_plays (id, user_id, game) values (gen_random_uuid(), a, 'leaf_match'); assert false, 'direct insert allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  begin execute 'set local role authenticated'; perform _game_day_bonus(a); assert false, 'browser called the bonus helper';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  -- other players cannot finish my game
  p3 := (select id from game_plays where user_id = a and finished_at is null limit 1);
  perform pg_temp._as(b);
  begin perform finish_game(p3, '{"misses":0}'); assert false, 'finished another player''s game'; exception when raise_exception then null; end;
  perform pg_temp._as(a);

  -- Rhizome Rush + Odd Plant Out, then the daily streak (3 games = +50 coins +1 rhizome, once)
  update profiles set leaf_coins = 0, rhizomes = 0, xp = 0 where id = a;
  delete from game_days where user_id = a;
  p1 := gen_random_uuid(); perform start_game('rhizome_rush', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"hits":10}');
  assert (r->>'tier')::int = 3 and (r->>'coins')::int = 40 and (r->>'rhizomes')::int = 1 and (r->>'perfect')::boolean and (r->'rush_perfects')::int = 1, 'perfect Rhizome Rush';
  p2 := gen_random_uuid(); perform start_game('odd_plant_out', p2);
  update game_plays set started_at = now() - interval '40 seconds' where id = p2;     -- 35 to 50 seconds = 40 coins
  r := finish_game(p2, '{"misses":0}');
  assert (r->>'tier')::int = 2 and (r->>'coins')::int = 40 and (r->>'rhizomes')::int = 0, 'Odd Plant Out in 40 seconds';
  assert (select leaf_coins from profiles where id = a) = 80 and not (get_games_state()->'today'->>'bonus_paid')::boolean, 'no streak bonus after two games';
  p3 := gen_random_uuid(); perform start_game('leaf_match', p3);
  update game_plays set started_at = now() - interval '30 seconds' where id = p3;
  r := finish_game(p3, '{"misses":0}');
  assert (r->'daily_bonus'->>'coins')::int = 50 and (r->'daily_bonus'->>'rhizomes')::int = 1, 'daily streak bonus on the third game';
  assert (select leaf_coins from profiles where id = a) = 80 + 150 + 50 and (select rhizomes from profiles where id = a) = 1 + 1 + 1, 'daily bonus payout';
  p3 := gen_random_uuid(); perform start_game('odd_plant_out', p3);
  update game_plays set started_at = now() - interval '40 seconds' where id = p3;
  r := finish_game(p3, '{"misses":0}');
  assert r->'daily_bonus' is null, 'daily bonus paid twice';
  assert (select xp from profiles where id = a) = 10 + 5 + 10 + 5, 'game XP: perfect 10, normal 5';
  -- very fast cleanup: under 25 seconds is the top tier
  update game_plays set started_at = now() - interval '3 hours' where user_id = a and game = 'odd_plant_out';
  p3 := gen_random_uuid(); perform start_game('odd_plant_out', p3);
  update game_plays set started_at = now() - interval '12 seconds' where id = p3;
  r := finish_game(p3, '{"misses":0}');
  assert (r->>'tier')::int = 4 and (r->>'coins')::int = 100 and (r->>'perfect')::boolean, 'odd plant out under 25 seconds';

  -- five perfect Rhizome Rush rounds in a row pay +50 coins +1 rhizome; a miss resets the count
  update game_progress set rush_perfects = 4 where user_id = a;
  update profiles set leaf_coins = 0, rhizomes = 0 where id = a;
  update game_plays set started_at = now() - interval '3 hours' where user_id = a and game = 'rhizome_rush';
  p1 := gen_random_uuid(); perform start_game('rhizome_rush', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"hits":10}');
  assert (r->'rush_bonus'->>'coins')::int = 50 and (select leaf_coins from profiles where id = a) = 40 + 50 and (select rhizomes from profiles where id = a) = 2, 'five perfects bonus';
  assert (select rush_perfects from game_progress where user_id = a) = 0, 'count should reset after the bonus';
  update game_progress set rush_perfects = 3 where user_id = a;
  p1 := gen_random_uuid(); perform start_game('rhizome_rush', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  perform finish_game(p1, '{"hits":9}');
  assert (select rush_perfects from game_progress where user_id = a) = 0, 'a non-perfect round resets the count';

  -- spinner: server-rolled, once per 4 hours, 6 per day
  perform pg_temp._as(d);
  update profiles set leaf_coins = 0, rhizomes = 0 where id = d;
  p1 := gen_random_uuid();
  r := spin(p1);
  assert (r->>'segment')::int between 0 and 5 and (r->>'coins')::int in (10, 25, 50, 75, 100, 150), 'spin result';
  assert (select leaf_coins from profiles where id = d) = (r->>'coins')::int, 'spin coins paid';
  assert (spin(p1)->>'replay')::boolean and (select leaf_coins from profiles where id = d) = (r->>'coins')::int, 'a repeated spin paid again';
  begin perform spin(gen_random_uuid()); assert false, 'spun again inside 4 hours'; exception when raise_exception then null; end;
  update game_plays set started_at = now() - interval '5 hours' where user_id = d;
  perform spin(gen_random_uuid());
  update game_plays set started_at = now() - interval '5 hours' where user_id = d;
  for i in 1..4 loop perform spin(gen_random_uuid()); update game_plays set started_at = now() - interval '5 hours' where user_id = d; end loop;
  assert (select count(*) from game_plays where user_id = d and game = 'spinner') = 6, 'six spins used';
  begin perform spin(gen_random_uuid()); assert false, 'seventh spin allowed'; exception when raise_exception then null; end;
  assert (get_games_state()->'games'->'spinner'->>'day_left')::int = 0, 'no spins left today';

  -- weekly streak: the 7th day in a row pays +150 coins +3 rhizomes +1 gem
  perform pg_temp._as(b);
  update profiles set leaf_coins = 0, rhizomes = 0, collector_gems = 0 where id = b;
  insert into game_days (user_id, day, completed, bonus_paid) select b, today - g, 3, true from generate_series(1, 6) g;
  insert into game_days (user_id, day, completed, bonus_paid) values (b, today, 2, false);
  assert (get_games_state()->'streak'->>'days')::int = 6, 'six days so far';
  p1 := gen_random_uuid(); perform start_game('leaf_match', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"misses":0}');
  assert r->'weekly_bonus' is not null and (r->>'streak_days')::int = 7, 'seventh day pays the weekly bonus';
  assert (select leaf_coins from profiles where id = b) = 150 + 50 + 150 and (select rhizomes from profiles where id = b) = 1 + 1 + 3 and (select collector_gems from profiles where id = b) = 1, 'weekly payout';
  -- a gap breaks the streak
  delete from game_days where user_id = b and day in (today - 1, today);
  assert (get_games_state()->'streak'->>'days')::int = 0, 'a missed day resets the streak';
  raise notice 'All Increment 9 tests passed';
end $$;
rollback;
