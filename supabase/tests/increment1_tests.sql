-- Run in the Supabase SQL Editor AFTER migration_004 (watering now pays the daily care reward). Everything is rolled back at the end, so no data is kept.
-- It prints "All Increment 1 tests passed" or stops at the first failing check with its description.
begin;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); pa uuid; ps uuid; s jsonb; g numeric;
begin
  insert into auth.users (id, email) values (a, 'test-a@example.com'), (b, 'test-b@example.com');
  assert (select leaf_coins from profiles where id = a) = 100, 'new account gets exactly 100 coins';
  assert not _grant(a,'leaf_coins',100,'starting_grant','starting_grant'), 'starting grant can repeat';
  assert (select leaf_coins from profiles where id = a) = 100, 'starting grant changed the balance twice';
  begin perform _grant(a,'leaf_coins',-1000,'test','overdraw'); assert false, 'overdraw was allowed';
  exception when check_violation then null; end;
  assert (select leaf_coins from profiles where id = a) = 100, 'failed overdraw changed the balance';

  update profiles set is_admin = true where id = a;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);

  assert (claim_daily_login()->>'granted')::boolean, 'first daily claim should pay';
  assert not (claim_daily_login()->>'granted')::boolean, 'second daily claim on the same day should not pay';
  assert (select leaf_coins from profiles where id = a) = 125, 'daily login should add 25';

  ps := (admin_grant_plant('sword')->>'id')::uuid;
  begin perform admin_grant_plant('sword'); assert false, 'duplicate plant was granted';
  exception when raise_exception then null; end;

  -- 10 days without water: healthy 165h + thirsty 64h at half speed -> past the 156h needed for stage 5
  update plants set moisture_at = now() - interval '10 days' where id = ps;
  s := get_game_state();
  assert (select stage from plants where id = ps) = 5, 'long-neglected plant should still have grown to stage 5';
  assert (select moisture from plants where id = ps) < 10, 'plant should be very dry after 10 days';
  assert (select leaf_coins from profiles where id = a) = 165, 'final stage reward should add 40 once';
  perform get_game_state();
  assert (select leaf_coins from profiles where id = a) = 165, 'final stage reward was paid twice';

  -- a dry plant pauses instead of dying or shrinking
  pa := (admin_grant_plant('siamsilver')->>'id')::uuid;
  update plants set moisture = 0, moisture_at = now() - interval '48 hours' where id = pa;
  perform get_game_state();
  assert (select growth_hours from plants where id = pa) = 0, 'dry plant should not grow';
  assert (select stage from plants where id = pa) = 1, 'dry plant stage should not change';
  perform water_plant(pa);
  assert (select moisture from plants where id = pa) = 100, 'watering should restore moisture to 100';
  assert (select leaf_coins from profiles where id = a) = 190, 'first watering of the day should pay the 25 care reward';
  g := (select growth_hours from plants where id = pa);
  perform water_plant(pa);
  assert (select growth_hours from plants where id = pa) >= g, 'watering must never reduce growth';
  assert (select leaf_coins from profiles where id = a) = 190, 'care reward was paid twice in one day';

  -- placing
  perform place_plant(pa, 'living-0');
  begin perform place_plant(pa, 'garage-9'); assert false, 'invalid spot accepted';
  exception when raise_exception then null; end;

  -- other players cannot touch these plants, and direct table writes are refused
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', b::text, true);
  begin perform water_plant(pa); assert false, 'watered another player''s plant';
  exception when raise_exception then null; end;
  begin perform admin_grant_plant('cream'); assert false, 'non-admin granted a plant';
  exception when raise_exception then null; end;
  begin
    execute 'set local role authenticated';
    update plants set stage = 5 where id = pa;
    assert false, 'direct plant update was allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'All Increment 1 tests passed';
end $$;
rollback;
