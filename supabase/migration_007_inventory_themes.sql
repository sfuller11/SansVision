-- MIGRATION 7: duplicates become inventory items, double-XP boosts, XP/levels, plant renaming, garden backgrounds.
-- Run once in Supabase (SQL Editor) after migration_006.

-- 1. Boost column and duplicate inventory
alter table public.plants add column if not exists xp_boost_until timestamptz;

create table public.duplicate_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plant_type text not null references public.plant_catalog(id),
  rarity text not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolution text check (resolution in ('rhizomes','double_xp'))
);
create index duplicate_items_open_idx on public.duplicate_items (user_id) where resolved_at is null;
alter table public.duplicate_items enable row level security;
create policy "read own duplicates" on public.duplicate_items for select using (auth.uid() = user_id);
revoke insert, update, delete on public.duplicate_items from authenticated, anon;

update public.game_config set value = value || '{"double_xp_hours":24,"double_xp_multiplier":2}' where key = 'discovery';

-- 2. Growth now honours a double-XP window (the part of the elapsed time inside the window grows faster)
create or replace function public._advance(pid uuid) returns public.plants
language plpgsql security definer set search_path = public as $$
declare p plants; c plant_catalog; g jsonb := cfg('growth');
  r numeric := (g->>'moisture_loss_per_hour')::numeric;
  th numeric := (g->>'thirsty_below')::numeric; dr numeric := (g->>'dry_below')::numeric;
  mult numeric := coalesce((cfg('discovery')->>'double_xp_multiplier')::numeric, 2);
  t numeric; a numeric; b numeric; cc numeric; gain numeric; ov numeric; newh numeric;
begin
  select * into p from plants where id = pid for update;
  if not found then raise exception 'plant not found'; end if;
  select * into c from plant_catalog where id = p.type;
  t := greatest(0, extract(epoch from (now() - p.moisture_at)) / 3600.0);
  a := least(t, greatest(0, (p.moisture - th) / r));
  b := greatest(0, least(t, greatest(0, (p.moisture - dr) / r)) - greatest(0, (p.moisture - th) / r));
  cc := t - a - b;
  gain := a*(g->>'rate_healthy')::numeric + b*(g->>'rate_thirsty')::numeric + cc*(g->>'rate_dry')::numeric;
  if p.xp_boost_until is not null and p.xp_boost_until > p.moisture_at and t > 0 then
    ov := extract(epoch from (least(now(), p.xp_boost_until) - p.moisture_at)) / 3600.0;   -- hours of this period that were boosted
    gain := gain * (1 + least(1, ov / t) * (mult - 1));
  end if;
  newh := least(_total_hours(c.growth_scale), p.growth_hours + gain);
  update plants set moisture = greatest(0, p.moisture - r*t), moisture_at = now(), growth_hours = newh,
         stage = _stage_for(newh, c.max_stage, c.growth_scale)
   where id = pid returning * into p;
  if p.stage = c.max_stage and not p.final_rewarded then
    perform _grant(p.user_id, 'leaf_coins', (cfg('economy')->>'stage_final_reward')::int, 'growth_final', 'final:' || p.id);
    update plants set final_rewarded = true where id = pid returning * into p;
  end if;
  return p;
end $$;

-- 3. Plants report level, XP toward the next level, and any active boost
create or replace function public._plant_json(p public.plants) returns jsonb language sql stable as $$
  select jsonb_build_object('id',p.id,'type',p.type,'name',p.name,'stage',p.stage,'spot',p.spot,'moisture',p.moisture,
    'public_display',p.public_display,'cultivar',c.name,'rarity',c.rarity,'max_stage',c.max_stage,'tall',c.tall,
    'progress',least(1, p.growth_hours / _total_hours(c.growth_scale)),
    'xp', round(greatest(0, p.growth_hours - _hours_for_stage(p.stage, c.max_stage, c.growth_scale)), 1),
    'xp_needed', case when p.stage < c.max_stage then
        round(_hours_for_stage(p.stage + 1, c.max_stage, c.growth_scale) - _hours_for_stage(p.stage, c.max_stage, c.growth_scale), 1) end,
    'boost_until', case when p.xp_boost_until > now() then p.xp_boost_until end)
  from plant_catalog c where c.id = p.type $$;

-- 4. Discovery: a duplicate becomes an inventory item. The player chooses what to do with it later.
create or replace function public.discover(tier_id text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery'); t jsonb; o jsonb; prob text; cur text; cost int; bal int;
  roll numeric; cum numeric := 0; rar text; last_r text; r text; cid text; cname text; isnew boolean; bonus int := 0; dup_id uuid;
  prev discoveries; res jsonb;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  perform 1 from profiles where id = u for update;
  select * into prev from discoveries where user_id = u and discoveries.request_id = req_id;
  if found then return prev.result; end if;
  if exists (select 1 from discoveries where user_id = u and created_at > now() - make_interval(secs => (d->>'cooldown_seconds')::numeric)) then
    raise exception 'Please wait a moment before discovering again';
  end if;
  t := d->'tiers'->tier_id;
  if t is null then raise exception 'unknown discovery tier'; end if;
  o := t->'odds';
  prob := _tier_problem(o);
  if prob is not null then raise exception 'This discovery is unavailable (%)', prob; end if;
  cur := t->>'currency'; cost := (t->>'cost')::int;
  execute format('select %I from profiles where id = $1', cur) into bal using u;
  if bal < cost then raise exception 'Not enough %', replace(cur, '_', ' '); end if;

  roll := random() * 100;
  foreach r in array array['common','uncommon','rare','epic','legendary'] loop
    if (o->>r)::numeric > 0 then last_r := r; end if;
    cum := cum + (o->>r)::numeric;
    if rar is null and roll < cum then rar := r; end if;
  end loop;
  rar := coalesce(rar, last_r);
  select id, name into cid, cname from plant_catalog where rarity = rar and active order by random() limit 1;
  if cid is null then raise exception 'No eligible plants in %', rar; end if;

  perform _grant(u, cur, -cost, 'discovery_' || tier_id, 'discover:' || req_id);
  isnew := _give_plant(u, cid, 'discovery:' || tier_id);
  if not isnew then
    insert into duplicate_items (user_id, plant_type, rarity) values (u, cid, rar) returning id into dup_id;
  end if;
  if _grant(u, 'leaf_coins', (d->>'first_rarity_bonus')::int, 'first_rarity', 'first_rarity:' || rar) then
    bonus := (d->>'first_rarity_bonus')::int;
  end if;
  res := jsonb_build_object('tier', tier_id, 'tier_name', t->>'name', 'rarity', rar, 'plant', jsonb_build_object('id', cid, 'name', cname),
           'is_new', isnew, 'rhizomes_awarded', 0, 'duplicate_item_id', dup_id,
           'rhizomes_if_converted', case when isnew then null else (d->'duplicate_rhizomes'->>rar)::int end,
           'first_rarity_bonus', bonus, 'cost', cost, 'currency', cur);
  insert into discoveries (user_id, request_id, tier, rarity, plant_id, is_duplicate, result) values (u, req_id, tier_id, rar, cid, not isnew, res);
  return res;
end $$;

-- 5. Using a duplicate: convert it to Rhizomes OR give the plant you already own double XP for a while
create function public.resolve_duplicate(item_id uuid, choice text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery'); it duplicate_items; pid uuid; rhiz int; boost_end timestamptz; pname text;
begin
  if u is null then raise exception 'not signed in'; end if;
  if choice is null or choice not in ('rhizomes','double_xp') then raise exception 'invalid choice'; end if;
  perform 1 from profiles where id = u for update;
  select * into it from duplicate_items where id = item_id and user_id = u for update;
  if not found then raise exception 'Item not found'; end if;
  if it.resolved_at is not null then raise exception 'This duplicate was already used'; end if;
  if choice = 'rhizomes' then
    rhiz := (d->'duplicate_rhizomes'->>it.rarity)::int;
    perform _grant(u, 'rhizomes', rhiz, 'duplicate', 'dupitem:' || it.id);
    update duplicate_items set resolved_at = now(), resolution = 'rhizomes' where id = it.id;
    return jsonb_build_object('choice', 'rhizomes', 'rhizomes', rhiz);
  end if;
  select id into pid from plants where user_id = u and type = it.plant_type;
  if pid is null then raise exception 'You no longer own that plant'; end if;
  perform _advance(pid);                                   -- bank growth so far, so the boost only affects the future
  update plants set xp_boost_until = greatest(now(), coalesce(xp_boost_until, now())) + make_interval(secs => (d->>'double_xp_hours')::numeric * 3600)
   where id = pid returning xp_boost_until, name into boost_end, pname;
  update duplicate_items set resolved_at = now(), resolution = 'double_xp' where id = it.id;
  return jsonb_build_object('choice', 'double_xp', 'plant_name', pname, 'until', boost_end);
end $$;

create function public.rename_plant(pid uuid, new_name text) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from plants where id = pid and user_id = auth.uid()) then raise exception 'not your plant'; end if;
  new_name := btrim(coalesce(new_name, ''));
  if new_name !~ '^[A-Za-z0-9 ''_-]{1,24}$' then raise exception 'Use 1 to 24 letters, numbers, spaces, apostrophes, - or _'; end if;
  update plants set name = new_name where id = pid;
end $$;

-- 6. Garden backgrounds (themes), unlocked with currency
create table public.garden_themes (
  id text primary key, name text not null, description text not null default '',
  currency text not null check (currency in ('leaf_coins','collector_gems')),
  cost int not null default 0 check (cost >= 0), sort int not null default 0, active boolean not null default true
);
insert into public.garden_themes (id, name, description, currency, cost, sort) values
 ('cozy','Cozy House','The original four-room house.','leaf_coins',0,1),
 ('glasshouse','Glasshouse Daybed','Sunlit glass roof, white shelves and a red velvet daybed.','leaf_coins',300,2),
 ('pottingshed','Terracotta Potting Shed','Reed roof, glass walls and warm terracotta tiles.','leaf_coins',500,3),
 ('courtyard','Fountain Courtyard','A walled garden courtyard with stone beds and a fountain.','collector_gems',3,4),
 ('conservatory','Fairy-Light Conservatory','A warm wooden frame hung with strings of lights.','collector_gems',5,5);
create table public.garden_theme_unlocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  theme_id text not null references public.garden_themes(id),
  unlocked_at timestamptz not null default now(),
  primary key (user_id, theme_id)
);
alter table public.gardens add column theme text not null default 'cozy' references public.garden_themes(id);
alter table public.garden_themes enable row level security;
alter table public.garden_theme_unlocks enable row level security;
create policy "read themes" on public.garden_themes for select to authenticated using (true);
create policy "read own unlocks" on public.garden_theme_unlocks for select using (auth.uid() = user_id);
revoke insert, update, delete on public.garden_themes, public.garden_theme_unlocks from authenticated, anon;

create function public.list_garden_themes() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); cur text;
begin
  if u is null then raise exception 'not signed in'; end if;
  cur := (_ensure_garden(u)).theme;
  return (select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'description', t.description, 'currency', t.currency, 'cost', t.cost,
      'owned', t.cost = 0 or exists (select 1 from garden_theme_unlocks x where x.user_id = u and x.theme_id = t.id), 'current', t.id = cur) order by t.sort)
    from garden_themes t where t.active);
end $$;

create function public.unlock_garden_theme(theme_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t garden_themes; bal int;
begin
  if u is null then raise exception 'not signed in'; end if;
  perform 1 from profiles where id = u for update;
  select * into t from garden_themes where id = theme_id and active;
  if not found then raise exception 'Unknown background'; end if;
  if t.cost = 0 or exists (select 1 from garden_theme_unlocks where user_id = u and garden_theme_unlocks.theme_id = t.id) then raise exception 'You already have this background'; end if;
  execute format('select %I from profiles where id = $1', t.currency) into bal using u;
  if bal < t.cost then raise exception 'Not enough %', replace(t.currency, '_', ' '); end if;
  perform _grant(u, t.currency, -t.cost, 'theme_unlock', 'theme:' || t.id);
  insert into garden_theme_unlocks (user_id, theme_id) values (u, t.id);
  return jsonb_build_object('id', t.id, 'name', t.name, 'cost', t.cost, 'currency', t.currency);
end $$;

create function public.set_garden_theme(theme_id text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t garden_themes;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into t from garden_themes where id = theme_id and active;
  if not found then raise exception 'Unknown background'; end if;
  if t.cost > 0 and not exists (select 1 from garden_theme_unlocks where user_id = u and garden_theme_unlocks.theme_id = t.id) then raise exception 'Unlock this background first'; end if;
  perform _ensure_garden(u);
  update gardens set theme = t.id, updated_at = now() where owner_id = u;
end $$;

-- the garden functions now report the theme
create or replace function public.get_my_garden() returns jsonb language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  g := _ensure_garden(auth.uid());
  return jsonb_build_object('id',g.id,'name',g.name,'description',g.description,'is_public',g.is_public,'theme',g.theme,'first_published_at',g.first_published_at);
end $$;

create or replace function public.visit_garden(gid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g gardens;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into g from gardens where id = gid and (is_public or owner_id = u);
  if not found then raise exception 'Garden not found'; end if;
  if g.owner_id <> u then insert into garden_visits (visitor_id, garden_id) values (u, g.id) on conflict do nothing; end if;
  return jsonb_build_object('id', g.id, 'name', g.name, 'description', g.description, 'theme', g.theme, 'is_mine', g.owner_id = u,
    'owner_name', (select display_name from profiles where id = g.owner_id),
    'plants', (select coalesce(jsonb_agg(jsonb_build_object('spot', p.spot, 'type', p.type, 'name', p.name, 'cultivar', c.name,
        'rarity', c.rarity, 'stage', p.stage, 'max_stage', c.max_stage, 'tall', c.tall, 'care', _care_label(p),
        'moisture', round(greatest(0, p.moisture - (cfg('growth')->>'moisture_loss_per_hour')::numeric * extract(epoch from now() - p.moisture_at) / 3600.0))) order by p.spot), '[]'::jsonb)
      from plants p join plant_catalog c on c.id = p.type where p.user_id = g.owner_id and p.spot is not null and p.public_display),
    'collector', jsonb_build_object('unique_plants', (select count(*) from plants where user_id = g.owner_id),
      'achievements', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'icon', a.icon) order by a.sort), '[]'::jsonb)
        from player_achievements pa join achievements a on a.id = pa.achievement_id where pa.user_id = g.owner_id and pa.claimed_at is not null)));
end $$;

-- 7. Main state call now also lists duplicate items and the boost settings
create or replace function public.get_game_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pid uuid; today date := (now() at time zone 'utc')::date; d jsonb := cfg('discovery');
begin
  if u is null then raise exception 'not signed in'; end if;
  for pid in select id from plants where user_id = u loop perform _advance(pid); end loop;
  perform _evaluate_achievements(u);
  return jsonb_build_object(
    'profile', (select jsonb_build_object('display_name',display_name,'leaf_coins',leaf_coins,'collector_gems',collector_gems,'rhizomes',rhizomes,'is_admin',is_admin) from profiles where id = u),
    'daily', jsonb_build_object(
      'login_claimed', exists(select 1 from currency_ledger where user_id = u and idem_key = 'login:' || today),
      'care_claimed',  exists(select 1 from currency_ledger where user_id = u and idem_key = 'care:' || today)),
    'ready_achievements', (select count(*) from player_achievements pa join achievements a on a.id = pa.achievement_id
                           where pa.user_id = u and a.active and pa.completed_at is not null and pa.claimed_at is null),
    'boost', jsonb_build_object('hours', (d->>'double_xp_hours')::numeric, 'multiplier', (d->>'double_xp_multiplier')::numeric),
    'duplicates', (select coalesce(jsonb_agg(jsonb_build_object('id', di.id, 'plant_type', di.plant_type, 'cultivar', c.name, 'rarity', di.rarity,
                     'rhizomes', (d->'duplicate_rhizomes'->>di.rarity)::int) order by di.created_at), '[]'::jsonb)
                   from duplicate_items di join plant_catalog c on c.id = di.plant_type where di.user_id = u and di.resolved_at is null),
    'plants', (select coalesce(jsonb_agg(_plant_json(p) order by p.created_at), '[]'::jsonb) from plants p where p.user_id = u),
    'catalog', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'rarity',rarity) order by name), '[]'::jsonb) from plant_catalog where active));
end $$;

-- 8. Permissions
revoke execute on function public.resolve_duplicate(uuid,text), public.rename_plant(uuid,text), public.list_garden_themes(),
  public.unlock_garden_theme(text), public.set_garden_theme(text) from public, anon;
grant execute on function public.resolve_duplicate(uuid,text), public.rename_plant(uuid,text), public.list_garden_themes(),
  public.unlock_garden_theme(text), public.set_garden_theme(text) to authenticated;
notify pgrst, 'reload schema';
