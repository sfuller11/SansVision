-- Run in the Supabase SQL Editor AFTER migration_011. Everything is rolled back at the end.
-- (The garden parts of increment1, 4 and 7 tests describe the old four-room house and are replaced by this file.)
begin;
create function pg_temp._as(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', u::text, true); end $$;
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  ga uuid; gb uuid; gc uuid; ba uuid; pid uuid; pid2 uuid; r jsonb; before_c int;
begin
  insert into auth.users (id, email) values (a,'t11-a@example.com'), (b,'t11-b@example.com'), (c,'t11-c@example.com');

  -- new plants and rarities
  assert (select rarity from plant_catalog where id = 'goldenflame') = 'common', 'golden flame rarity';
  assert (select rarity from plant_catalog where id = 'hallibat') = 'common' and (select rarity from plant_catalog where id = 'masoniana') = 'common', 'common plants';
  assert (select rarity from plant_catalog where id = 'silverbat') = 'uncommon' and (select rarity from plant_catalog where id = 'bluebat') = 'rare', 'bat rarities';
  assert (select count(*) from plant_catalog where id in ('kirkiicoral','bhitaliivar') and rarity = 'legendary') = 2, 'legendary pair';

  -- every player starts with a Greenhouse of 10 spots
  perform pg_temp._as(a);
  r := get_my_gardens();
  assert jsonb_array_length(r->'gardens') = 1 and r->'gardens'->0->>'garden_type' = 'greenhouse' and (r->'gardens'->0->>'spots')::int = 10, 'starter greenhouse';
  assert jsonb_array_length(r->'types') = 8, 'eight garden types';
  select id into ga from gardens where owner_id = a;

  -- buying a garden
  update profiles set leaf_coins = 100, collector_gems = 0 where id = a;
  begin perform buy_garden('balcony', gen_random_uuid()); assert false, 'bought without money'; exception when raise_exception then null; end;
  begin perform buy_garden('zen_courtyard', gen_random_uuid()); assert false, 'bought with no gems'; exception when raise_exception then null; end;
  update profiles set leaf_coins = 400 where id = a;
  r := buy_garden('balcony', gen_random_uuid());
  assert (select leaf_coins from profiles where id = a) = 150, 'balcony costs 250';
  ba := (r->>'id')::uuid;
  begin perform buy_garden('balcony', gen_random_uuid()); assert false, 'bought twice'; exception when raise_exception then null; end;
  assert (select leaf_coins from profiles where id = a) = 150, 'no second charge';
  begin perform buy_garden('nope', gen_random_uuid()); assert false, 'unknown type'; exception when raise_exception then null; end;
  assert jsonb_array_length(get_my_gardens()->'gardens') = 2, 'owns two gardens';
  -- a skin shares the layout of its base garden
  update profiles set leaf_coins = 1000 where id = a;
  perform buy_garden('greenhouse_night', gen_random_uuid());
  assert (select count(*) from gardens where owner_id = a and garden_type in ('greenhouse','greenhouse_night')) = 2, 'greenhouse and its skin';

  -- placing plants
  perform _give_plant(a, 'dark', 'discovery:basic'); perform _give_plant(a, 'marsha', 'discovery:basic'); perform _give_plant(a, 'nelsonii', 'discovery:basic');
  select id into pid from plants where user_id = a and type = 'dark';
  select id into pid2 from plants where user_id = a and type = 'marsha';
  perform place_plant(pid, ga, 'shelf1');
  assert (select spot from plants where id = pid) = 'shelf1' and (select garden_id from plants where id = pid) = ga, 'placed';
  perform place_plant(pid2, ga, 'shelf1');                                    -- takes the spot; the first plant goes back to the tray
  assert (select spot from plants where id = pid) is null and (select garden_id from plants where id = pid) is null, 'displaced plant is unplaced';
  assert (select spot from plants where id = pid2) = 'shelf1', 'new plant holds the spot';
  begin perform place_plant(pid, ga, 'rail1'); assert false, 'spot from another layout'; exception when raise_exception then null; end;
  begin perform place_plant(pid, ga, 'nowhere'); assert false, 'invalid spot'; exception when raise_exception then null; end;
  perform place_plant(pid, ba, 'rail1');                                      -- the same name is fine in a garden that has it
  assert (select garden_id from plants where id = pid) = ba, 'placed in the balcony';
  perform place_plant(pid, ga, 'shelf2');                                     -- moving between gardens
  assert (select garden_id from plants where id = pid) = ga and (select spot from plants where id = pid) = 'shelf2', 'moved garden';
  -- the same spot name can be used in two gardens at once
  perform place_plant(pid2, ba, 'floor');
  perform place_plant(pid, ga, 'floor1');
  assert (select count(*) from plants where user_id = a and spot is not null) = 2, 'two plants placed';
  -- tall plants do not fit small spots
  select id into pid from plants where user_id = a and type = 'nelsonii';
  assert (select tall from plant_catalog where id = 'nelsonii'), 'nelsonii is tall';
  begin perform place_plant(pid, ga, 'shelf3'); assert false, 'tall plant on a small spot'; exception when raise_exception then null; end;
  perform place_plant(pid, ga, 'bench1');
  perform place_plant(pid, null, null);
  assert (select spot from plants where id = pid) is null, 'taken off';

  -- other players cannot touch your gardens or plants
  perform pg_temp._as(b);
  select id into gb from gardens where owner_id = b;
  begin perform place_plant(pid, gb, 'shelf1'); assert false, 'moved someone elses plant'; exception when raise_exception then null; end;
  perform _give_plant(b, 'dark', 'discovery:basic');
  select id into pid from plants where user_id = b and type = 'dark';
  begin perform place_plant(pid, ga, 'shelf4'); assert false, 'placed in someone elses garden'; exception when raise_exception then null; end;
  begin perform update_garden(ga, 'Hijacked', ''); assert false, 'edited someone elses garden'; exception when raise_exception then null; end;
  begin perform set_garden_public(ga, true); assert false, 'published someone elses garden'; exception when raise_exception then null; end;

  -- publishing, visiting, likes
  perform pg_temp._as(a);
  perform update_garden(ga, 'Sean''s Greenhouse', 'A test');
  perform set_garden_public(ga, true);
  perform pg_temp._as(b);
  r := visit_garden(ga);
  assert r->>'layout' = 'greenhouse' and jsonb_array_length(r->'plants') = 1 and (r->>'like_count')::int = 0, 'visitor sees only that garden';
  assert (r->>'owner_level')::int = 1, 'owner level shown';
  perform pg_temp._as(a);
  begin perform visit_garden(ba); r := visit_garden(ba); exception when others then null; end;   -- owner may view own private garden
  perform pg_temp._as(b);
  begin perform visit_garden(ba); assert false, 'visited a private garden'; exception when raise_exception then null; end;
  begin perform toggle_garden_like(ba); assert false, 'liked a private garden'; exception when raise_exception then null; end;
  r := toggle_garden_like(ga);
  assert (r->>'liked')::boolean and (r->>'like_count')::int = 1, 'liked';
  assert (visit_garden(ga)->>'liked_by_me')::boolean, 'liked_by_me';
  r := toggle_garden_like(ga);
  assert not (r->>'liked')::boolean and (r->>'like_count')::int = 0, 'unliked';
  r := toggle_garden_like(ga);
  perform pg_temp._as(a);
  begin perform toggle_garden_like(ga); assert false, 'liked own garden'; exception when raise_exception then null; end;

  -- Realm sorting: b publishes a garden with a plant; c likes it twice? (only once allowed) so c likes b, b likes a.
  perform pg_temp._as(b);
  perform place_plant(pid, gb, 'shelf1'); perform set_garden_public(gb, true);
  update profiles set level = 7, xp = 10 where id = b;
  update profiles set level = 3, xp = 0 where id = a;
  perform pg_temp._as(c);
  select id into gc from gardens where owner_id = c;
  perform toggle_garden_like(gb); perform toggle_garden_like(ga);
  -- a now has 2 likes (b, c), b has 1 (c)
  r := list_public_gardens('likes', 0, 12);
  assert (r->'gardens'->0->>'id')::uuid = ga and (r->'gardens'->0->>'like_count')::int = 2, 'most liked first';
  assert (r->'gardens'->0->>'liked_by_me')::boolean, 'liked flag in list';
  r := list_public_gardens('level', 0, 12);
  assert (r->'gardens'->0->>'id')::uuid = gb and (r->'gardens'->0->>'owner_level')::int = 7, 'highest level first';
  -- recent: b published after a
  update gardens set published_at = now() - interval '1 day' where id = ga;
  r := list_public_gardens('recent', 0, 12);
  assert (r->'gardens'->0->>'id')::uuid = gb, 'newest first';
  assert (r->>'has_more')::boolean = false, 'no more pages';
  r := list_public_gardens('recent', 0, 1);
  assert jsonb_array_length(r->'gardens') = 1 and (r->>'has_more')::boolean, 'page of one has more';
  r := list_public_gardens('recent', (r->>'next_offset')::int, 1);
  assert (r->'gardens'->0->>'id')::uuid = ga, 'second page';
  begin perform list_public_gardens('bogus', 0, 12); assert false, 'bad sort accepted'; exception when raise_exception then null; end;
  -- a garden with nothing on display is not listed
  perform pg_temp._as(a);
  perform place_plant(pid2, null, null); perform place_plant((select id from plants where user_id = a and type = 'dark'), null, null);
  perform pg_temp._as(c);
  assert jsonb_array_length(list_public_gardens('recent', 0, 12)->'gardens') = 1, 'empty garden hidden';

  raise notice 'increment 11 tests passed';
end $$;
rollback;
