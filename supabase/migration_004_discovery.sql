-- INCREMENT 2: discovery tiers, Rhizomes, targeted unlocking. Also removes "tend": watering now completes the daily care task.
-- Run once in Supabase (SQL Editor) after migration_003.

-- 1. Daily care is now "water any plant once today"
drop function if exists public.tend_plant(uuid);
drop table if exists public.plant_tends;

create or replace function public.water_plant(pid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); p plants; amt int := (cfg('economy')->>'daily_care')::int; granted boolean;
begin
  if u is null or not exists (select 1 from plants where id = pid and user_id = u) then raise exception 'not your plant'; end if;
  perform _advance(pid);   -- growth earned so far is banked before moisture resets
  update plants set moisture = 100, moisture_at = now(), last_watered_at = now() where id = pid returning * into p;
  granted := _grant(u, 'leaf_coins', amt, 'daily_care', 'care:' || (now() at time zone 'utc')::date);  -- pays once per day
  return _plant_json(p) || jsonb_build_object('care_reward', granted, 'care_amount', amt);
end $$;

create or replace function public.get_game_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pid uuid; today date := (now() at time zone 'utc')::date;
begin
  if u is null then raise exception 'not signed in'; end if;
  for pid in select id from plants where user_id = u loop perform _advance(pid); end loop;
  return jsonb_build_object(
    'profile', (select jsonb_build_object('display_name',display_name,'leaf_coins',leaf_coins,'collector_gems',collector_gems,'rhizomes',rhizomes,'is_admin',is_admin) from profiles where id = u),
    'daily', jsonb_build_object(
      'login_claimed', exists(select 1 from currency_ledger where user_id = u and idem_key = 'login:' || today),
      'care_claimed',  exists(select 1 from currency_ledger where user_id = u and idem_key = 'care:' || today)),
    'plants', (select coalesce(jsonb_agg(_plant_json(p) order by p.created_at), '[]'::jsonb) from plants p where p.user_id = u),
    'catalog', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'rarity',rarity) order by name), '[]'::jsonb) from plant_catalog where active));
end $$;

-- 2. Discovery configuration. Costs, odds, rewards: all editable here, no code changes.
insert into public.game_config (key, value) values ('discovery', '{
  "cooldown_seconds": 1,
  "first_rarity_bonus": 25,
  "duplicate_rhizomes": {"common":1,"uncommon":2,"rare":4,"epic":8,"legendary":15},
  "targeted_costs": {"common":10,"uncommon":20,"rare":40,"epic":80,"legendary":150},
  "tiers": {
    "basic":     {"sort":1,"name":"Basic Discovery","currency":"leaf_coins","cost":50,
                  "odds":{"common":70,"uncommon":22,"rare":6,"epic":1.7,"legendary":0.3}},
    "selective": {"sort":2,"name":"Selective Discovery","currency":"leaf_coins","cost":150,
                  "odds":{"common":40,"uncommon":35,"rare":18,"epic":6,"legendary":1}},
    "collector": {"sort":3,"name":"Collector Discovery","currency":"collector_gems","cost":5,
                  "odds":{"common":15,"uncommon":30,"rare":30,"epic":20,"legendary":5}}
  }}');

-- 3. Record of every discovery (also makes repeated requests safe)
create table public.discoveries (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  tier text not null,
  rarity text not null,
  plant_id text not null references public.plant_catalog(id),
  is_duplicate boolean not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  unique (user_id, request_id)
);
alter table public.discoveries enable row level security;
create policy "read own discoveries" on public.discoveries for select using (auth.uid() = user_id);
revoke insert, update, delete on public.discoveries from authenticated, anon;

-- 4. Helpers
-- Returns null when a tier's odds are valid and every rarity that can be rolled has at least one active plant.
create function public._tier_problem(o jsonb) returns text language plpgsql stable set search_path = public as $$
declare r text; tot numeric := 0; v numeric;
begin
  foreach r in array array['common','uncommon','rare','epic','legendary'] loop
    v := (o->>r)::numeric;
    if v is null or v < 0 then return 'invalid odds for ' || r; end if;
    tot := tot + v;
    if v > 0 and not exists (select 1 from plant_catalog where rarity = r and active) then return 'no plants in ' || r; end if;
  end loop;
  if abs(tot - 100) > 0.0001 then return 'odds do not add up to 100'; end if;
  return null;
end $$;

create function public._give_plant(u uuid, cid text, src text) returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into plants (user_id, type, name, stage, acquired_source)
    select u, id, name, 1, src from plant_catalog where id = cid and active
    on conflict (user_id, type) do nothing;
  get diagnostics n = row_count;
  return n = 1;      -- false means the player already owned it
end $$;

-- 5. What the Discover screen shows (odds are read from the same config the server rolls with)
create function public.get_discovery_info() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery');
begin
  if u is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'tiers', (select jsonb_agg(jsonb_build_object('id',k,'name',v->>'name','currency',v->>'currency','cost',(v->>'cost')::int,
                'odds',v->'odds','problem',_tier_problem(v->'odds')) order by (v->>'sort')::int)
              from jsonb_each(d->'tiers') x(k, v)),
    'pools', coalesce((select jsonb_object_agg(rarity, n) from (select rarity, count(*) n from plant_catalog where active group by rarity) s), '{}'::jsonb),
    'targeted', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'rarity',c.rarity,
                'cost',(d->'targeted_costs'->>c.rarity)::int,
                'owned',exists(select 1 from plants p where p.user_id = u and p.type = c.id))
                order by (d->'targeted_costs'->>c.rarity)::int, c.name) from plant_catalog c where c.active), '[]'::jsonb));
end $$;

-- 6. Random discovery. One transaction: any failure undoes the charge.
create function public.discover(tier_id text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery'); t jsonb; o jsonb; prob text; cur text; cost int; bal int;
  roll numeric; cum numeric := 0; rar text; last_r text; r text; cid text; cname text; isnew boolean; rhiz int := 0; bonus int := 0;
  prev discoveries; res jsonb;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  perform 1 from profiles where id = u for update;                       -- one money action at a time per player
  select * into prev from discoveries where user_id = u and discoveries.request_id = req_id;
  if found then return prev.result; end if;                              -- a repeated request returns the same result and charges nothing
  if exists (select 1 from discoveries where user_id = u and created_at > now() - make_interval(secs => (d->>'cooldown_seconds')::numeric)) then
    raise exception 'Please wait a moment before discovering again';
  end if;
  t := d->'tiers'->tier_id;
  if t is null then raise exception 'unknown discovery tier'; end if;
  o := t->'odds';
  prob := _tier_problem(o);                                              -- checks the CURRENT catalog, not what the screen showed
  if prob is not null then raise exception 'This discovery is unavailable (%)', prob; end if;
  cur := t->>'currency'; cost := (t->>'cost')::int;
  execute format('select %I from profiles where id = $1', cur) into bal using u;
  if bal < cost then raise exception 'Not enough %', replace(cur, '_', ' '); end if;

  roll := random() * 100;                                                -- step 1: roll the rarity
  foreach r in array array['common','uncommon','rare','epic','legendary'] loop
    if (o->>r)::numeric > 0 then last_r := r; end if;
    cum := cum + (o->>r)::numeric;
    if rar is null and roll < cum then rar := r; end if;
  end loop;
  rar := coalesce(rar, last_r);
  select id, name into cid, cname from plant_catalog where rarity = rar and active order by random() limit 1;   -- step 2: every plant in that rarity is equally likely
  if cid is null then raise exception 'No eligible plants in %', rar; end if;

  perform _grant(u, cur, -cost, 'discovery_' || tier_id, 'discover:' || req_id);
  isnew := _give_plant(u, cid, 'discovery:' || tier_id);
  if not isnew then
    rhiz := (d->'duplicate_rhizomes'->>rar)::int;
    perform _grant(u, 'rhizomes', rhiz, 'duplicate', 'dup:' || req_id);
  end if;
  if _grant(u, 'leaf_coins', (d->>'first_rarity_bonus')::int, 'first_rarity', 'first_rarity:' || rar) then
    bonus := (d->>'first_rarity_bonus')::int;
  end if;
  res := jsonb_build_object('tier', tier_id, 'tier_name', t->>'name', 'rarity', rar, 'plant', jsonb_build_object('id', cid, 'name', cname),
           'is_new', isnew, 'rhizomes_awarded', rhiz, 'first_rarity_bonus', bonus, 'cost', cost, 'currency', cur);
  insert into discoveries (user_id, request_id, tier, rarity, plant_id, is_duplicate, result) values (u, req_id, tier_id, rar, cid, not isnew, res);
  return res;
end $$;

-- 7. Targeted discovery: spend Rhizomes on a specific plant you do not own
create function public.targeted_unlock(cid text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery'); c plant_catalog; cost int; bal int; bonus int := 0; prev discoveries; res jsonb;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  perform 1 from profiles where id = u for update;
  select * into prev from discoveries where user_id = u and discoveries.request_id = req_id;
  if found then return prev.result; end if;
  select * into c from plant_catalog where id = cid and active;
  if not found then raise exception 'That plant is not available'; end if;
  if exists (select 1 from plants where user_id = u and type = cid) then raise exception 'You already own this plant'; end if;   -- checked before charging
  cost := (d->'targeted_costs'->>c.rarity)::int;
  select rhizomes into bal from profiles where id = u;
  if bal < cost then raise exception 'Not enough Species Rhizomes'; end if;
  perform _grant(u, 'rhizomes', -cost, 'targeted', 'targeted:' || req_id);
  if not _give_plant(u, cid, 'targeted') then raise exception 'You already own this plant'; end if;
  if _grant(u, 'leaf_coins', (d->>'first_rarity_bonus')::int, 'first_rarity', 'first_rarity:' || c.rarity) then
    bonus := (d->>'first_rarity_bonus')::int;
  end if;
  res := jsonb_build_object('tier', 'targeted', 'tier_name', 'Targeted Discovery', 'rarity', c.rarity,
           'plant', jsonb_build_object('id', c.id, 'name', c.name), 'is_new', true, 'rhizomes_awarded', 0,
           'first_rarity_bonus', bonus, 'cost', cost, 'currency', 'rhizomes');
  insert into discoveries (user_id, request_id, tier, rarity, plant_id, is_duplicate, result) values (u, req_id, 'targeted', c.rarity, c.id, false, res);
  return res;
end $$;

-- 8. Permissions
revoke execute on function public._tier_problem(jsonb), public._give_plant(uuid,text,text) from public, anon, authenticated;
revoke execute on function public.get_discovery_info(), public.discover(text,uuid), public.targeted_unlock(text,uuid) from public, anon;
grant execute on function public.get_discovery_info(), public.discover(text,uuid), public.targeted_unlock(text,uuid) to authenticated;

-- 9. Refuse to finish if any configured odds table is invalid
do $$ declare k text; v jsonb; p text; begin
  for k, v in select * from jsonb_each(cfg('discovery')->'tiers') loop
    p := _tier_problem(v->'odds');
    if p is not null then raise exception 'tier % is invalid: %', k, p; end if;
  end loop;
end $$;
