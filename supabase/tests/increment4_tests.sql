-- Run in the Supabase SQL Editor AFTER migration_006. Everything is rolled back at the end.
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid(); x uuid; i int;
  ga jsonb; gid uuid; v jsonb; l jsonb; l2 jsonb; pid uuid; hid uuid; ids uuid[] := '{}'; coins int;
begin
  insert into auth.users (id, email) values (a,'garden-a@example.com'), (b,'garden-b@example.com'), (c,'garden-c@example.com');
  perform _give_plant(a,'trifasciata','discovery:basic'); perform _give_plant(a,'cream','discovery:basic');
  perform _give_plant(c,'sword','discovery:basic');
  perform pg_temp._as(a);
  ga := get_my_garden(); gid := (ga->>'id')::uuid;
  assert not (ga->>'is_public')::boolean, 'new gardens should be private';
  pid := (select id from plants where user_id = a and type = 'trifasciata'); hid := (select id from plants where user_id = a and type = 'cream');
  perform place_plant(pid, 'living-0'); perform place_plant(hid, 'living-1');
  begin perform update_garden('ab', 'x'); assert false, 'short garden name accepted'; exception when raise_exception then null; end;
  perform update_garden('Sean''s greenhouse', 'Snake plants everywhere');

  -- private gardens are invisible
  perform pg_temp._as(b);
  assert jsonb_array_length(list_public_gardens()->'gardens') = 0, 'private garden listed';
  begin perform visit_garden(gid); assert false, 'visited a private garden'; exception when raise_exception then null; end;
  assert (select count(*) from garden_visits) = 0, 'private visit recorded';
  perform pg_temp._as(a);
  assert (visit_garden(gid)->>'is_mine')::boolean, 'owner should see own garden';
  assert (select count(*) from garden_visits) = 0, 'owner visit recorded';

  -- publish, hide one plant, visit
  perform set_garden_public(true);
  perform set_plant_display(hid, false);
  perform pg_temp._as(b);
  l := list_public_gardens();
  assert jsonb_array_length(l->'gardens') = 1 and (l->'gardens'->0->>'cultivars')::int = 1, 'public garden should list one visible cultivar';
  v := visit_garden(gid);
  assert jsonb_array_length(v->'plants') = 1 and v->'plants'->0->>'type' = 'trifasciata', 'hidden plant was shown to a visitor';
  assert position(a::text in v::text) = 0 and position(a::text in l::text) = 0 and position('garden-a@example.com' in v::text) = 0, 'private identifiers leaked';
  perform visit_garden(gid);
  assert (select count(*) from garden_visits where visitor_id = b) = 1, 'repeat visits should count once';

  -- visitors cannot change anything
  begin perform place_plant(pid, null); assert false, 'visitor moved the owner''s plant'; exception when raise_exception then null; end;
  begin perform set_plant_display(pid, false); assert false, 'visitor changed plant display'; exception when raise_exception then null; end;
  perform set_garden_public(false);                                  -- b's own garden, not a's
  assert (select is_public from gardens where id = gid), 'visitor unpublished the owner''s garden';
  begin
    execute 'set local role authenticated';
    update gardens set name = 'hacked' where id = gid;
    assert false, 'direct garden update was allowed';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform pg_temp._as(b);

  -- empty gardens are not listed; achievements
  perform pg_temp._as(c); perform place_plant((select id from plants where user_id = c), 'porch-0'); perform set_garden_public(true);
  perform pg_temp._as(b); perform set_garden_public(true);           -- b has no plants on display
  assert jsonb_array_length(list_public_gardens()->'gardens') = 2, 'empty garden was listed';
  perform get_achievements();
  assert (select completed_at from player_achievements where user_id = b and achievement_id = 'garden_host') is not null, 'Garden Host should complete';
  perform pg_temp._as(a); perform get_achievements();
  assert (select completed_at from player_achievements where user_id = a and achievement_id = 'first_visitor') is not null, 'First Visitor should complete';
  coins := (select leaf_coins from profiles where id = a);
  perform claim_achievement('first_visitor'); perform claim_achievement('first_visitor');
  assert (select leaf_coins from profiles where id = a) = coins + 50, 'First Visitor should pay 50 once';
  perform pg_temp._as(c); perform get_achievements();
  assert (select completed_at from player_achievements where user_id = c and achievement_id = 'first_visitor') is null, 'First Visitor completed without a visitor';

  -- five distinct gardens complete Realm Explorer; the same garden twice or your own garden does not count
  for i in 1..4 loop
    x := gen_random_uuid(); insert into auth.users (id, email) values (x, 'garden-x' || i || '@example.com');
    perform _give_plant(x,'laurentii','discovery:basic'); perform pg_temp._as(x);
    perform place_plant((select id from plants where user_id = x), 'kitchen-0'); perform set_garden_public(true); ids := ids || (get_my_garden()->>'id')::uuid;
  end loop;
  perform pg_temp._as(b);
  perform visit_garden(gid); perform visit_garden(ids[1]); perform visit_garden(ids[2]); perform visit_garden(ids[3]);
  perform visit_garden((select id from gardens where owner_id = b));                          -- own garden does not count
  perform get_achievements();
  assert (select completed_at from player_achievements where user_id = b and achievement_id = 'realm_explorer') is null, 'Realm Explorer completed too early';
  perform visit_garden(ids[4]);
  perform get_achievements();
  assert (select completed_at from player_achievements where user_id = b and achievement_id = 'realm_explorer') is not null, 'Realm Explorer should complete after 5 distinct gardens';

  -- pagination: 6 public gardens with plants (a, c, 4 others), pages of 4 then 2, no overlap
  l := list_public_gardens(null, null, 4);
  assert jsonb_array_length(l->'gardens') = 4 and l->'next_cursor' is not null, 'first page should have 4 and a cursor';
  l2 := list_public_gardens((l->'next_cursor'->>'ts')::timestamptz, (l->'next_cursor'->>'id')::uuid, 4);
  assert jsonb_array_length(l2->'gardens') = 2 and l2->'next_cursor' is null, 'second page should have the remaining 2';
  assert (select count(distinct e->>'id') from jsonb_array_elements((l->'gardens') || (l2->'gardens')) e) = 6, 'pages overlapped or missed a garden';
  assert (select random_public_garden()) <> (select id from gardens where owner_id = b), 'random garden returned own garden';
  raise notice 'All Increment 4 tests passed';
end $$;
rollback;
