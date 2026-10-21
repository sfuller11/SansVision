-- INCREMENT 1: foundation (catalog, currency ledger, server-side growth and watering).
-- Run once in Supabase: SQL Editor > New query > paste > Run. Run migration_002 first if you have not.

-- 1. Configuration (change values here, no code changes needed)
create table public.game_config (key text primary key, value jsonb not null);
insert into public.game_config (key, value) values
 ('economy', '{"starting_coins":100,"daily_login":25,"daily_care":25,"stage_final_reward":40,"care_plants_required":3}'),
 ('growth',  '{"hours_per_stage":[12,24,48,72],"moisture_loss_per_hour":0.3929,"rate_healthy":1.0,"rate_thirsty":0.5,"rate_dry":0.0,"thirsty_below":35,"dry_below":10}');
alter table public.game_config enable row level security;
create policy "read config" on public.game_config for select to authenticated using (true);
create function public.cfg(k text) returns jsonb language sql stable as $$ select value from public.game_config where key = k $$;

-- 2. Plant catalog (rarities below are placeholders: edit them freely)
create table public.plant_catalog (
  id text primary key,
  name text not null,
  rarity text not null check (rarity in ('common','uncommon','rare','epic','legendary')),
  asset_key text not null,
  description text not null default '',
  max_stage int not null default 5 check (max_stage between 5 and 20),
  growth_scale numeric not null default 1 check (growth_scale > 0),
  tall boolean not null default false,
  active boolean not null default false
);
alter table public.plant_catalog enable row level security;
create policy "read catalog" on public.plant_catalog for select to authenticated using (true);
insert into public.plant_catalog (id, name, rarity, asset_key, description, max_stage, growth_scale, tall, active) values
 ('trifasciata','Trifasciata','common','trifasciata','The classic tall snake plant.',20,2,true,true),
 ('laurentii','Laurentii','common','laurentii','Snake plant with golden leaf edges.',20,2,true,true),
 ('sword','Forescate','uncommon','sword','Upright yellow-green trifasciata cultivar.',5,1,false,true),
 ('blackgold','Black Gold','uncommon','blackgold','Dark leaves with gold margins.',20,2,true,true),
 ('siamsilver','Siam Silver','uncommon','siamsilver','Silvery sansevieria metallica.',5,1,false,true),
 ('cream','Moonshine Splash','rare','cream','Pale cream and green variegation.',5,1,false,true),
 ('banded','Moonshine Mutant','rare','banded','Broad mottled moonshine mutant.',5,1,false,true),
 ('dark','Hallii Dark Pink Bat','epic','dark','Dark bat-shaped leaves with pink edges.',5,1,false,true),
 ('coppertone','Hallii Coppertone','legendary','coppertone','Coppery bat-shaped hallii.',5,1,false,true);

-- 3. Profiles: public display name and balances (balances change only through the ledger)
alter table public.profiles
  add column if not exists display_name text,
  add column if not exists leaf_coins int not null default 0 check (leaf_coins >= 0),
  add column if not exists collector_gems int not null default 0 check (collector_gems >= 0),
  add column if not exists rhizomes int not null default 0 check (rhizomes >= 0);
insert into public.profiles (id) select id from auth.users on conflict (id) do nothing;
update public.profiles set display_name = 'Gardener-' || substr(replace(id::text,'-',''),1,8) where display_name is null;
create unique index profiles_display_name_key on public.profiles (lower(display_name));

-- 4. Currency ledger
create table public.currency_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  currency text not null check (currency in ('leaf_coins','collector_gems','rhizomes')),
  amount int not null check (amount <> 0),
  kind text not null,
  idem_key text not null,
  created_at timestamptz not null default now(),
  unique (user_id, idem_key)
);
alter table public.currency_ledger enable row level security;
create policy "read own ledger" on public.currency_ledger for select using (auth.uid() = user_id);

create function public._grant(u uuid, cur text, amt int, k text, idem text) returns boolean
language plpgsql security definer set search_path = public as $$
declare ins int;
begin
  perform 1 from profiles where id = u for update;          -- serialises all money changes for this player
  if not found then raise exception 'no profile'; end if;
  insert into currency_ledger (user_id, currency, amount, kind, idem_key) values (u, cur, amt, k, idem)
    on conflict (user_id, idem_key) do nothing;
  get diagnostics ins = row_count;
  if ins = 0 then return false; end if;                      -- already applied: same request cannot pay twice
  if cur = 'leaf_coins' then update profiles set leaf_coins = leaf_coins + amt where id = u;
  elsif cur = 'collector_gems' then update profiles set collector_gems = collector_gems + amt where id = u;
  elsif cur = 'rhizomes' then update profiles set rhizomes = rhizomes + amt where id = u;
  else raise exception 'unknown currency'; end if;           -- balances have CHECK >= 0, so overdrawing rolls everything back
  return true;
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name) values (new.id, 'Gardener-' || substr(replace(new.id::text,'-',''),1,8))
    on conflict (id) do nothing;
  perform _grant(new.id, 'leaf_coins', (cfg('economy')->>'starting_coins')::int, 'starting_grant', 'starting_grant');
  return new;
end $$;
select public._grant(id, 'leaf_coins', (public.cfg('economy')->>'starting_coins')::int, 'starting_grant', 'starting_grant') from public.profiles;

-- 5. Plants become server-controlled ownership + progress records
drop trigger if exists guard_stage on public.plants;
drop function if exists public.guard_stage();
alter table public.plants
  add column if not exists moisture numeric not null default 100 check (moisture between 0 and 100),
  add column if not exists moisture_at timestamptz not null default now(),
  add column if not exists growth_hours numeric not null default 0 check (growth_hours >= 0),
  add column if not exists acquired_source text not null default 'founder',
  add column if not exists final_rewarded boolean not null default false,
  add column if not exists public_display boolean not null default true;
alter table public.plants drop constraint if exists plants_type_check;
alter table public.plants add constraint plants_type_fk foreign key (type) references public.plant_catalog(id);

-- one copy of each cultivar per player; extra copies are kept in plants_archive, not deleted
create table public.plants_archive as select * from public.plants where false;
alter table public.plants_archive enable row level security;
create temp table dup_ids as
  select id from (select id, row_number() over (partition by user_id, type order by stage desc, created_at) rn from public.plants) t where rn > 1;
insert into public.plants_archive select p.* from public.plants p where p.id in (select id from dup_ids);
delete from public.plants where id in (select id from dup_ids);
create unique index plants_one_per_type on public.plants (user_id, type);
create unique index plants_one_per_spot on public.plants (user_id, spot) where spot is not null;

drop policy if exists "users manage their own plants" on public.plants;
create policy "read own plants" on public.plants for select using (auth.uid() = user_id);
revoke insert, update, delete on public.plants, public.profiles, public.currency_ledger, public.plants_archive from authenticated, anon;

create table public.plant_tends (
  user_id uuid not null references auth.users(id) on delete cascade,
  plant_id uuid not null references public.plants(id) on delete cascade,
  day date not null,
  primary key (user_id, plant_id, day)
);
alter table public.plant_tends enable row level security;
create policy "read own tends" on public.plant_tends for select using (auth.uid() = user_id);

-- 6. Growth maths
create function public._total_hours(sc numeric) returns numeric language sql stable as $$
  select sum(x::numeric) * sc from jsonb_array_elements_text(cfg('growth')->'hours_per_stage') x $$;

create function public._stage_for(h numeric, mx int, sc numeric) returns int language plpgsql stable as $$
declare d numeric[] := array(select x::numeric from jsonb_array_elements_text(cfg('growth')->'hours_per_stage') x);
        cum numeric := 0; s int := 1; i int;
begin
  if mx = 5 then
    for i in 1..array_length(d,1) loop cum := cum + d[i]*sc; if h >= cum then s := i + 1; end if; end loop;
    return s;
  end if;
  return least(mx, greatest(1, 1 + floor(h / _total_hours(sc) * (mx-1) + 0.000001)::int));
end $$;

create function public._hours_for_stage(s int, mx int, sc numeric) returns numeric language plpgsql stable as $$
declare d numeric[] := array(select x::numeric from jsonb_array_elements_text(cfg('growth')->'hours_per_stage') x);
        cum numeric := 0; i int;
begin
  if mx = 5 then
    for i in 1..(s-1) loop cum := cum + d[i]*sc; end loop;
    return cum;
  end if;
  return (s-1)::numeric / (mx-1) * _total_hours(sc);
end $$;

update public.plants p set growth_hours = public._hours_for_stage(p.stage, c.max_stage, c.growth_scale)
  from public.plant_catalog c where c.id = p.type;

-- Brings one plant up to date from elapsed server time. Plants never die and growth never goes backwards.
create function public._advance(pid uuid) returns public.plants
language plpgsql security definer set search_path = public as $$
declare p plants; c plant_catalog; g jsonb := cfg('growth');
  r numeric := (g->>'moisture_loss_per_hour')::numeric;
  th numeric := (g->>'thirsty_below')::numeric; dr numeric := (g->>'dry_below')::numeric;
  t numeric; a numeric; b numeric; cc numeric; newh numeric;
begin
  select * into p from plants where id = pid for update;
  if not found then raise exception 'plant not found'; end if;
  select * into c from plant_catalog where id = p.type;
  t := greatest(0, extract(epoch from (now() - p.moisture_at)) / 3600.0);
  a := least(t, greatest(0, (p.moisture - th) / r));                                         -- hours at healthy or better
  b := greatest(0, least(t, greatest(0, (p.moisture - dr) / r)) - greatest(0, (p.moisture - th) / r)); -- hours thirsty
  cc := t - a - b;                                                                           -- hours very dry
  newh := least(_total_hours(c.growth_scale), p.growth_hours
          + a*(g->>'rate_healthy')::numeric + b*(g->>'rate_thirsty')::numeric + cc*(g->>'rate_dry')::numeric);
  update plants set moisture = greatest(0, p.moisture - r*t), moisture_at = now(), growth_hours = newh,
         stage = _stage_for(newh, c.max_stage, c.growth_scale)
   where id = pid returning * into p;
  if p.stage = c.max_stage and not p.final_rewarded then
    perform _grant(p.user_id, 'leaf_coins', (cfg('economy')->>'stage_final_reward')::int, 'growth_final', 'final:' || p.id);
    update plants set final_rewarded = true where id = pid returning * into p;
  end if;
  return p;
end $$;

create function public._plant_json(p public.plants) returns jsonb language sql stable as $$
  select jsonb_build_object('id',p.id,'type',p.type,'name',p.name,'stage',p.stage,'spot',p.spot,'moisture',p.moisture,
    'cultivar',c.name,'rarity',c.rarity,'max_stage',c.max_stage,'tall',c.tall,
    'progress',least(1, p.growth_hours / _total_hours(c.growth_scale)))
  from plant_catalog c where c.id = p.type $$;

-- 7. Functions the app calls
create function public.get_game_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pid uuid; today date := (now() at time zone 'utc')::date;
begin
  if u is null then raise exception 'not signed in'; end if;
  for pid in select id from plants where user_id = u loop perform _advance(pid); end loop;
  return jsonb_build_object(
    'profile', (select jsonb_build_object('display_name',display_name,'leaf_coins',leaf_coins,'collector_gems',collector_gems,'rhizomes',rhizomes,'is_admin',is_admin) from profiles where id = u),
    'daily', jsonb_build_object(
      'login_claimed', exists(select 1 from currency_ledger where user_id = u and idem_key = 'login:' || today),
      'care_claimed',  exists(select 1 from currency_ledger where user_id = u and idem_key = 'care:' || today),
      'tends_required', least((cfg('economy')->>'care_plants_required')::int, (select count(*) from plants where user_id = u)),
      'tended_ids', (select coalesce(jsonb_agg(plant_id), '[]'::jsonb) from plant_tends where user_id = u and day = today)),
    'plants', (select coalesce(jsonb_agg(_plant_json(p) order by p.created_at), '[]'::jsonb) from plants p where p.user_id = u),
    'catalog', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'rarity',rarity) order by name), '[]'::jsonb) from plant_catalog where active));
end $$;

create function public.claim_daily_login() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); amt int := (cfg('economy')->>'daily_login')::int;
begin
  if u is null then raise exception 'not signed in'; end if;
  return jsonb_build_object('granted', _grant(u,'leaf_coins',amt,'daily_login','login:' || (now() at time zone 'utc')::date), 'amount', amt);
end $$;

create function public.water_plant(pid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); p plants;
begin
  if u is null or not exists (select 1 from plants where id = pid and user_id = u) then raise exception 'not your plant'; end if;
  perform _advance(pid);   -- growth earned so far is banked before moisture resets
  update plants set moisture = 100, moisture_at = now(), last_watered_at = now() where id = pid returning * into p;
  return _plant_json(p);
end $$;

create function public.tend_plant(pid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); today date := (now() at time zone 'utc')::date; cnt int; need int; granted boolean := false;
        amt int := (cfg('economy')->>'daily_care')::int;
begin
  if u is null or not exists (select 1 from plants where id = pid and user_id = u) then raise exception 'not your plant'; end if;
  insert into plant_tends (user_id, plant_id, day) values (u, pid, today) on conflict do nothing;   -- once per plant per day
  select count(*) into cnt from plant_tends where user_id = u and day = today;
  need := least((cfg('economy')->>'care_plants_required')::int, (select count(*) from plants where user_id = u));
  if cnt >= need then granted := _grant(u,'leaf_coins',amt,'daily_care','care:' || today); end if;
  return jsonb_build_object('tended', cnt, 'required', need, 'reward_granted', granted, 'amount', amt);
end $$;

create function public.place_plant(pid uuid, spot_name text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null or not exists (select 1 from plants where id = pid and user_id = u) then raise exception 'not your plant'; end if;
  if spot_name is not null and spot_name !~ '^(living|kitchen|bedroom|porch)-[0-2]$' then raise exception 'invalid spot'; end if;
  if spot_name is not null then update plants set spot = null where user_id = u and spot = spot_name and id <> pid; end if;
  update plants set spot = spot_name where id = pid;
end $$;

create function public.set_display_name(new_name text) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  new_name := btrim(new_name);
  if new_name !~ '^[A-Za-z0-9 _-]{3,24}$' then raise exception 'Use 3 to 24 letters, numbers, spaces, - or _'; end if;
  update profiles set display_name = new_name where id = auth.uid();
exception when unique_violation then raise exception 'That name is taken';
end $$;

create function public.admin_set_stage(pid uuid, new_stage int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); c plant_catalog; p plants;
begin
  if not coalesce((select is_admin from profiles where id = u), false) then raise exception 'admins only'; end if;
  select * into p from plants where id = pid and user_id = u;
  if not found then raise exception 'not your plant'; end if;
  select * into c from plant_catalog where id = p.type;
  if new_stage < 1 or new_stage > c.max_stage then raise exception 'stage out of range'; end if;
  update plants set growth_hours = _hours_for_stage(new_stage, c.max_stage, c.growth_scale), moisture_at = now(), stage = new_stage
   where id = pid returning * into p;
  return _plant_json(p);
end $$;

create function public.admin_grant_plant(catalog_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); p plants; c plant_catalog;
begin
  if not coalesce((select is_admin from profiles where id = u), false) then raise exception 'admins only'; end if;
  select * into c from plant_catalog where id = catalog_id and active;
  if not found then raise exception 'unknown plant'; end if;
  insert into plants (user_id, type, name, stage, acquired_source) values (u, c.id, c.name, 1, 'admin')
    on conflict (user_id, type) do nothing returning * into p;
  if p.id is null then raise exception 'already owned'; end if;
  return _plant_json(p);
end $$;

-- 8. Permissions: internal helpers are not callable from the browser, app functions need a signed-in user
revoke execute on function public._grant(uuid,text,int,text,text), public._advance(uuid), public._stage_for(numeric,int,numeric),
  public._hours_for_stage(int,int,numeric), public._total_hours(numeric), public._plant_json(public.plants), public.cfg(text)
  from public, anon, authenticated;
revoke execute on function public.get_game_state(), public.claim_daily_login(), public.water_plant(uuid), public.tend_plant(uuid),
  public.place_plant(uuid,text), public.set_display_name(text), public.admin_set_stage(uuid,int), public.admin_grant_plant(text)
  from public, anon;
grant execute on function public.get_game_state(), public.claim_daily_login(), public.water_plant(uuid), public.tend_plant(uuid),
  public.place_plant(uuid,text), public.set_display_name(text), public.admin_set_stage(uuid,int), public.admin_grant_plant(text)
  to authenticated;
