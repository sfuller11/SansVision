-- Run in the Supabase SQL Editor AFTER migration_005. Everything is rolled back at the end.
begin;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); before_c int; before_g int; t1 timestamptz; r jsonb; k text;
begin
  insert into auth.users (id, email) values (a, 'test-ach-a@example.com'), (b, 'test-ach-b@example.com');
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);

  -- nothing is complete without plants, and unfinished achievements cannot be claimed
  perform get_achievements();
  begin perform claim_achievement('first_discovery'); assert false, 'claimed an incomplete achievement';
  exception when raise_exception then null; end;

  -- plants granted by an admin do not count as discoveries
  perform _give_plant(b, 'trifasciata', 'admin');
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  perform get_achievements();
  assert (select completed_at from player_achievements where user_id = b and achievement_id = 'first_discovery') is null, 'admin-granted plant counted';
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  -- First Discovery: completes once, pays once
  perform _give_plant(a, 'trifasciata', 'discovery:basic');
  perform get_achievements();
  t1 := (select completed_at from player_achievements where user_id = a and achievement_id = 'first_discovery');
  assert t1 is not null, 'first discovery should complete';
  perform get_achievements();
  assert (select completed_at from player_achievements where user_id = a and achievement_id = 'first_discovery') = t1, 'completion time changed';
  before_c := (select leaf_coins from profiles where id = a);
  r := claim_achievement('first_discovery');
  assert (r->>'claimed')::boolean, 'claim should succeed';
  assert (select leaf_coins from profiles where id = a) = before_c + 50, 'first discovery pays 50 coins';
  r := claim_achievement('first_discovery');
  assert not (r->>'claimed')::boolean, 'second claim should not pay';
  assert (select leaf_coins from profiles where id = a) = before_c + 50, 'reward paid twice';

  -- rarity achievements pay gems
  perform _give_plant(a, 'cream', 'discovery:basic');     -- rare
  perform _give_plant(a, 'dark', 'discovery:basic');      -- epic
  perform _give_plant(a, 'coppertone', 'discovery:basic');-- legendary
  before_g := (select collector_gems from profiles where id = a);
  perform claim_achievement('rare_find'); perform claim_achievement('epic_discovery'); perform claim_achievement('legendary_discovery');
  assert (select collector_gems from profiles where id = a) = before_g + 1 + 2 + 3, 'rarity achievements should pay 1 + 2 + 3 gems';

  -- collection sizes: five plants completes Growing Collection, 15 is not earnable with this catalog
  perform _give_plant(a, 'sword', 'discovery:basic'); perform _give_plant(a, 'banded', 'discovery:basic');
  perform get_achievements();
  assert (select completed_at from player_achievements where user_id = a and achievement_id = 'growing_collection') is not null, 'five plants should complete Growing Collection';
  before_c := (select leaf_coins from profiles where id = a);
  perform claim_achievement('growing_collection');
  assert (select leaf_coins from profiles where id = a) = before_c + 50, 'Growing Collection pays 50';
  assert (select count(*) from jsonb_array_elements(get_achievements()) x where x->>'id' = 'dedicated_collector' and x->>'state' = 'needs_plants') = 1,
    'Dedicated Collector should wait for a bigger catalog';
  begin perform claim_achievement('dedicated_collector'); assert false, 'claimed an unearnable achievement';
  exception when raise_exception then null; end;
  assert (select count(*) from jsonb_array_elements(get_achievements()) x where x->>'id' = 'realm_explorer' and x->>'state' = 'coming_soon') = 1,
    'garden achievements should be coming soon';

  -- growth: five fully grown plants complete Green Thumb and First Growth
  perform _give_plant(a, 'siamsilver', 'discovery:basic');
  update plants set growth_hours = 100000, moisture_at = now() where user_id = a and type in ('sword','cream','dark','banded','coppertone');
  perform get_game_state();
  assert (select completed_at from player_achievements where user_id = a and achievement_id = 'first_growth') is not null, 'First Growth should complete';
  assert (select completed_at from player_achievements where user_id = a and achievement_id = 'green_thumb') is not null, 'Green Thumb should complete';
  before_c := (select leaf_coins from profiles where id = a);
  perform claim_achievement('green_thumb');
  assert (select leaf_coins from profiles where id = a) = before_c + 100, 'Green Thumb pays 100';

  -- the browser cannot write achievement progress or rewards
  begin
    execute 'set local role authenticated';
    update player_achievements set claimed_at = null where user_id = a;
    assert false, 'direct achievement update was allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'All Increment 3 tests passed';
end $$;
rollback;
