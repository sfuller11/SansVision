-- Run in the Supabase SQL Editor AFTER migration_007. Everything is rolled back at the end.
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); r jsonb; j jsonb; it uuid; pid uuid; pid2 uuid; g1 numeric; g2 numeric;
begin
  insert into auth.users (id, email) values (a,'t7-a@example.com'), (b,'t7-b@example.com');
  perform _give_plant(a,'coppertone','discovery:basic'); perform _give_plant(a,'sword','discovery:basic');
  update profiles set is_admin = true where id = a;
  perform pg_temp._as(a);
  pid := (select id from plants where user_id = a and type = 'coppertone'); pid2 := (select id from plants where user_id = a and type = 'sword');

  -- renaming
  perform rename_plant(pid, 'Copper King');
  assert (select name from plants where id = pid) = 'Copper King', 'rename failed';
  begin perform rename_plant(pid, ''); assert false, 'empty name accepted'; exception when raise_exception then null; end;
  begin perform rename_plant(pid, '<script>'); assert false, 'symbols accepted'; exception when raise_exception then null; end;
  begin perform rename_plant(pid, repeat('a', 25)); assert false, 'long name accepted'; exception when raise_exception then null; end;
  perform pg_temp._as(b);
  begin perform rename_plant(pid, 'Mine'); assert false, 'renamed another player''s plant'; exception when raise_exception then null; end;
  perform pg_temp._as(a);

  -- a duplicate is an inventory item, not instant Rhizomes
  update game_config set value = jsonb_set(jsonb_set(value, '{tiers,basic,odds}', '{"common":0,"uncommon":0,"rare":0,"epic":0,"legendary":100}'), '{cooldown_seconds}', '0') where key = 'discovery';
  update profiles set leaf_coins = 500 where id = a;
  r := discover('basic', gen_random_uuid());
  assert not (r->>'is_new')::boolean and (r->>'rhizomes_awarded')::int = 0 and (r->>'rhizomes_if_converted')::int = 8, 'duplicate result is wrong';
  assert (select rhizomes from profiles where id = a) = 0, 'duplicate paid before the player chose';
  it := (r->>'duplicate_item_id')::uuid;
  assert jsonb_array_length(get_game_state()->'duplicates') = 1, 'duplicate missing from inventory';
  perform pg_temp._as(b);
  begin perform resolve_duplicate(it, 'rhizomes'); assert false, 'used another player''s duplicate'; exception when raise_exception then null; end;
  perform pg_temp._as(a);
  begin perform resolve_duplicate(it, 'bogus'); assert false, 'invalid choice accepted'; exception when raise_exception then null; end;
  perform resolve_duplicate(it, 'rhizomes');
  assert (select rhizomes from profiles where id = a) = 8, 'legendary duplicate converts to 8 rhizomes';
  begin perform resolve_duplicate(it, 'rhizomes'); assert false, 'duplicate used twice'; exception when raise_exception then null; end;
  assert (select rhizomes from profiles where id = a) = 8, 'duplicate paid twice';
  assert jsonb_array_length(get_game_state()->'duplicates') = 0, 'used duplicate still listed';

  -- double XP lands on the plant already owned
  r := discover('basic', gen_random_uuid());
  perform resolve_duplicate((r->>'duplicate_item_id')::uuid, 'double_xp');
  assert (select xp_boost_until from plants where id = pid) between now() + interval '23 hours' and now() + interval '25 hours', 'boost should last about 24 hours';
  assert _plant_json((select p from plants p where p.id = pid))->>'boost_until' is not null, 'boost not visible on the plant';
  assert (select rhizomes from profiles where id = a) = 8, 'double xp should not also pay rhizomes';

  -- the boost really doubles growth; without it growth is normal
  update plants set growth_hours = 0, stage = 1, moisture = 100, moisture_at = now() - interval '10 hours', xp_boost_until = null where id = pid2;
  perform get_game_state(); g1 := (select growth_hours from plants where id = pid2);
  assert abs(g1 - 10) < 0.01, 'normal growth should be 10 hours of XP';
  update plants set growth_hours = 0, stage = 1, moisture = 100, moisture_at = now() - interval '10 hours', xp_boost_until = now() + interval '1 hour', boost_mult = 2 where id = pid2;
  perform get_game_state(); g2 := (select growth_hours from plants where id = pid2);
  assert abs(g2 - 20) < 0.01, 'boosted growth should be 20 hours of XP';

  -- level / XP numbers
  j := admin_set_stage(pid2, 3);
  assert (j->>'stage')::int = 3 and (j->>'xp')::numeric = 0 and (j->>'xp_needed')::numeric = 62.4, 'level 3 needs 62.4 xp (48 x 1.3 uncommon) for the next level';
  j := admin_set_stage(pid2, 5);
  assert j->>'xp_needed' is null, 'max level has no next level';

  -- garden backgrounds
  assert (get_my_garden()->>'theme') = 'cozy', 'default background';
  assert jsonb_array_length(list_garden_themes()) = 5, 'five backgrounds expected';
  begin perform set_garden_theme('glasshouse'); assert false, 'used a locked background'; exception when raise_exception then null; end;
  update profiles set leaf_coins = 100, collector_gems = 0 where id = a;
  begin perform unlock_garden_theme('glasshouse'); assert false, 'unlocked without enough coins'; exception when raise_exception then null; end;
  assert (select leaf_coins from profiles where id = a) = 100, 'failed unlock charged coins';
  update profiles set leaf_coins = 400 where id = a;
  perform unlock_garden_theme('glasshouse');
  assert (select leaf_coins from profiles where id = a) = 100, 'glasshouse costs 300';
  begin perform unlock_garden_theme('glasshouse'); assert false, 'unlocked twice'; exception when raise_exception then null; end;
  assert (select leaf_coins from profiles where id = a) = 100, 'second unlock charged coins';
  perform set_garden_theme('glasshouse');
  begin perform unlock_garden_theme('courtyard'); assert false, 'gem background without gems'; exception when raise_exception then null; end;
  update profiles set collector_gems = 3 where id = a;
  perform unlock_garden_theme('courtyard');
  assert (select collector_gems from profiles where id = a) = 0, 'courtyard costs 3 gems';
  perform place_plant(pid, 'living-0'); perform set_garden_public(true);
  perform pg_temp._as(b);
  assert visit_garden((select id from gardens where owner_id = a))->>'theme' = 'glasshouse', 'visitors should see the owner''s background';
  begin perform set_garden_theme('glasshouse'); assert false, 'used a background the player does not own'; exception when raise_exception then null; end;
  begin
    execute 'set local role authenticated';
    insert into garden_theme_unlocks (user_id, theme_id) values (b, 'conservatory');
    assert false, 'direct unlock was allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'All migration 7 tests passed';
end $$;
rollback;
