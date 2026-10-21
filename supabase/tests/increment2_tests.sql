-- Run in the Supabase SQL Editor AFTER migration_007 (duplicates are now inventory items you convert yourself). Everything is rolled back at the end.
-- Not covered here: two requests at the same instant (a SQL Editor script is one transaction). See the README.
begin;
do $$
declare a uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; rq uuid := gen_random_uuid(); k text; v jsonb; n int; coins int;
  only_legendary jsonb := '{"common":0,"uncommon":0,"rare":0,"epic":0,"legendary":100}';
begin
  insert into auth.users (id, email) values (a, 'test-disc@example.com');
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);

  for k, v in select * from jsonb_each(cfg('discovery')->'tiers') loop
    assert _tier_problem(v->'odds') is null, 'tier ' || k || ' has invalid odds or an empty rarity';
  end loop;
  assert cfg('discovery')->'tiers'->'basic'->>'cost' = '50' and cfg('discovery')->'tiers'->'selective'->>'cost' = '150'
     and cfg('discovery')->'tiers'->'collector'->>'cost' = '5', 'tier costs differ from the spec';
  assert _tier_problem('{"common":50,"uncommon":22,"rare":6,"epic":1.7,"legendary":0.3}') is not null, 'odds not adding to 100 were accepted';

  -- make results predictable: only legendary can be rolled, and no cooldown
  update game_config set value = jsonb_set(jsonb_set(value, '{tiers,basic,odds}', only_legendary), '{cooldown_seconds}', '0') where key = 'discovery';

  r1 := discover('basic', rq);
  assert r1->>'rarity' = 'legendary' and (r1->'plant'->>'id') = 'coppertone' and (r1->>'is_new')::boolean, 'first legendary discovery should be new';
  assert (select leaf_coins from profiles where id = a) = 100 - 50 + 25, 'cost 50, first-rarity bonus 25';
  assert (select count(*) from plants where user_id = a and type = 'coppertone') = 1, 'plant not granted';
  r2 := discover('basic', rq);                                   -- the same request again
  assert r2 = r1, 'a repeated request should return the same result';
  assert (select leaf_coins from profiles where id = a) = 75, 'a repeated request charged again';
  assert (select count(*) from currency_ledger where user_id = a and idem_key = 'discover:' || rq) = 1, 'ledger has more than one spend';

  -- duplicate: no second copy, Rhizomes instead, no second first-rarity bonus
  update profiles set leaf_coins = leaf_coins + 100 where id = a;
  r2 := discover('basic', gen_random_uuid());
  assert not (r2->>'is_new')::boolean and (r2->>'rhizomes_awarded')::int = 0 and r2->>'duplicate_item_id' is not null, 'duplicate should become an inventory item';
  assert (select rhizomes from profiles where id = a) = 0, 'duplicate paid rhizomes before the player chose';
  perform resolve_duplicate((r2->>'duplicate_item_id')::uuid, 'rhizomes');
  assert (select count(*) from plants where user_id = a and type = 'coppertone') = 1, 'duplicate created a second copy';
  assert (select rhizomes from profiles where id = a) = 8, 'rhizome balance wrong';
  assert (select leaf_coins from profiles where id = a) = 125, 'duplicate cost or bonus wrong';

  -- cannot afford: nothing changes
  update profiles set leaf_coins = 10 where id = a;
  begin perform discover('basic', gen_random_uuid()); assert false, 'discovered without enough coins';
  exception when raise_exception then null; end;
  assert (select leaf_coins from profiles where id = a) = 10, 'failed discovery changed the balance';
  begin perform discover('collector', gen_random_uuid()); assert false, 'collector discovery without gems';
  exception when raise_exception then null; end;

  -- empty rarity pool: refused and not charged
  update profiles set leaf_coins = 500 where id = a;
  update plant_catalog set active = false where rarity = 'legendary';
  begin perform discover('basic', gen_random_uuid()); assert false, 'discovery ran with an empty rarity';
  exception when raise_exception then null; end;
  assert (select leaf_coins from profiles where id = a) = 500, 'empty rarity pool consumed currency';
  update plant_catalog set active = true where rarity = 'legendary';

  -- cooldown
  update game_config set value = jsonb_set(value, '{cooldown_seconds}', '5') where key = 'discovery';
  begin perform discover('basic', gen_random_uuid()); assert false, 'cooldown ignored';
  exception when raise_exception then null; end;
  update game_config set value = jsonb_set(value, '{cooldown_seconds}', '0') where key = 'discovery';

  -- targeted: exact plant, correct cost, refused if owned, nothing charged on refusal
  perform _grant(a, 'rhizomes', 200, 'test', 'test-rhizomes');
  r1 := targeted_unlock('trifasciata', gen_random_uuid());
  assert r1->'plant'->>'id' = 'trifasciata', 'targeted unlock granted the wrong plant';
  assert (select rhizomes from profiles where id = a) = 8 + 200 - 10, 'common costs 10 rhizomes';
  begin perform targeted_unlock('trifasciata', gen_random_uuid()); assert false, 'bought an owned plant';
  exception when raise_exception then null; end;
  assert (select rhizomes from profiles where id = a) = 198, 'refused purchase charged rhizomes';
  begin perform targeted_unlock('no-such-plant', gen_random_uuid()); assert false, 'unknown plant accepted';
  exception when raise_exception then null; end;
  perform targeted_unlock('dark', gen_random_uuid()); perform targeted_unlock('cream', gen_random_uuid());
  assert (select rhizomes from profiles where id = a) = 198 - 80 - 40, 'epic costs 80 and rare costs 40 rhizomes';
  update profiles set rhizomes = 5 where id = a;
  begin perform targeted_unlock('laurentii', gen_random_uuid()); assert false, 'bought a plant without enough rhizomes';
  exception when raise_exception then null; end;
  assert (select rhizomes from profiles where id = a) = 5, 'failed purchase changed the rhizome balance';

  -- the browser cannot write plants or balances directly
  begin
    execute 'set local role authenticated';
    insert into plants (user_id, type, name) values (a, 'laurentii', 'cheat');
    assert false, 'direct plant insert was allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'All Increment 2 tests passed';
end $$;
rollback;
