-- Run in the Supabase SQL Editor AFTER migration_010. Everything is rolled back at the end.
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); r jsonb; p1 uuid; x jsonb;
begin
  insert into auth.users (id, email) values (a,'t10-a@example.com'), (b,'t10-b@example.com');
  perform pg_temp._as(a);
  update profiles set leaf_coins = 0, rhizomes = 0 where id = a;

  -- Odd Plant Out replaced Garden Cleanup
  begin perform start_game('garden_cleanup', gen_random_uuid()); assert false, 'old game still works'; exception when raise_exception then null; end;
  assert get_games_state()->'games' ? 'odd_plant_out' and not (get_games_state()->'games' ? 'garden_cleanup'), 'games list';
  -- 40 seconds, no misses: 35 to 50 seconds pays 40 coins
  p1 := gen_random_uuid(); perform start_game('odd_plant_out', p1);
  update game_plays set started_at = now() - interval '40 seconds' where id = p1;
  r := finish_game(p1, '{"misses":0}');
  assert (r->>'tier')::int = 2 and (r->>'coins')::int = 40, '40s with no misses';
  -- 20 seconds + 3 misses (6s penalty) = 26s: not under 25, so 60 coins + 1 rhizome
  p1 := gen_random_uuid(); perform start_game('odd_plant_out', p1);
  update game_plays set started_at = now() - interval '20 seconds' where id = p1;
  r := finish_game(p1, '{"misses":3}');
  assert (r->>'tier')::int = 3 and (r->>'coins')::int = 60 and (r->>'rhizomes')::int = 1, 'wrong taps add time';
  -- a missing misses value counts as the maximum penalty (10 x 2s = 20s): 15s becomes 35s = tier 2
  update game_plays set started_at = now() - interval '5 hours' where user_id = a;
  p1 := gen_random_uuid(); perform start_game('odd_plant_out', p1);
  update game_plays set started_at = now() - interval '15 seconds' where id = p1;
  r := finish_game(p1, '{}');
  assert (r->>'tier')::int = 2, 'missing misses should not skip the penalty';
  -- Rhizome Rush: 7 hits is now enough for the top tier, 6 is not
  update game_plays set started_at = now() - interval '5 hours' where user_id = a;
  p1 := gen_random_uuid(); perform start_game('rhizome_rush', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"hits":7}');
  assert (r->>'tier')::int = 3 and (r->>'rhizomes')::int = 1, '7 hits is tier 3';
  p1 := gen_random_uuid(); perform start_game('rhizome_rush', p1);
  update game_plays set started_at = now() - interval '30 seconds' where id = p1;
  r := finish_game(p1, '{"hits":6}');
  assert (r->>'tier')::int = 2, '6 hits is tier 2';

  -- Collection: unowned plants reveal no name or description
  perform _give_plant(a, 'dark', 'discovery:basic');
  x := get_collection();
  assert jsonb_array_length(x->'plants') = (select count(*) from plant_catalog where active), 'every active plant listed';
  assert (select count(*) from jsonb_array_elements(x->'plants') e where (e->>'owned')::boolean) = 1, 'one owned plant';
  assert (select e->>'name' from jsonb_array_elements(x->'plants') e where e->>'id' = 'dark') = 'Hallii Dark Pink Bat', 'owned plant shows its name';
  assert (select count(*) from jsonb_array_elements(x->'plants') e where not (e->>'owned')::boolean and (e ? 'name' or e ? 'description' or e ? 'plant_name')) = 0, 'unowned plants leaked a name';
  assert (select (e->>'unlock_cost')::int from jsonb_array_elements(x->'plants') e where e->>'id' = 'coppertone') = 150, 'unowned plants show the Rhizome price';
  assert (select e->'chances'->'basic'->>'pct' from jsonb_array_elements(x->'plants') e where e->>'id' = 'coppertone') is not null, 'unowned plants show the odds';
  assert (select array_agg(e->>'rarity' order by o) from jsonb_array_elements(x->'plants') with ordinality t(e, o))
       = (select array_agg(rarity order by array_position(array['common','uncommon','rare','epic','legendary'], rarity), id) from plant_catalog where active), 'plants are ordered by rarity';
  -- the New dot
  update plants set collection_seen = false where user_id = a and type = 'dark';
  assert (get_game_state()->>'new_plants')::int = 1, 'new plant counted';
  assert (select (e->>'is_new')::boolean from jsonb_array_elements(get_collection()->'plants') e where e->>'id' = 'dark'), 'plant marked new';
  perform mark_plant_seen('dark');
  assert (get_game_state()->>'new_plants')::int = 0, 'seen plants are not new';
  perform pg_temp._as(b);
  perform mark_plant_seen('dark');   -- another player's call changes nothing for a
  perform pg_temp._as(a);
  assert (select count(*) from plants where user_id = a and not collection_seen) = 0, 'seen flag is per player';

  -- Profile summary
  perform _give_plant(a, 'sword', 'discovery:basic');
  update plants set growth_hours = 100000 where user_id = a and type = 'sword';
  perform get_game_state();
  r := get_profile_summary();
  assert (r->>'plants_owned')::int = 2 and (r->>'full_growth')::int = 1 and (r->>'games_played')::int >= 5, 'summary numbers';

  -- Avatars: needs an uploaded file; the path is always the player's own
  begin perform set_avatar(); assert false, 'avatar set without a file'; exception when raise_exception then null; end;
  insert into storage.objects (bucket_id, name) values ('avatars', a::text || '/avatar.jpg');
  perform set_avatar();
  assert (select avatar_path from profiles where id = a) = a::text || '/avatar.jpg' and (get_game_state()->'profile'->>'avatar_v') is not null, 'avatar saved';
  perform pg_temp._as(b);
  begin perform set_avatar(); assert false, 'player b used a''s file'; exception when raise_exception then null; end;
  perform pg_temp._as(a);
  perform remove_avatar();
  assert (select avatar_path from profiles where id = a) is null, 'avatar removed';
  begin execute 'set local role authenticated'; update profiles set avatar_path = 'x' where id = a; assert false, 'direct avatar write allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'All Increment 10 tests passed';
end $$;
rollback;
