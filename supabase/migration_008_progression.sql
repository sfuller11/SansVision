-- MIGRATION 8: rarity-based growth, purchasable boosts, gem stage skips, player levels and XP, "while you were away" summary.
-- Run ONCE in Supabase (SQL Editor) after migration_007. (It multiplies existing growth by each plant's rarity once.)

-- 1. Configuration (edit values in the game_config table, no code changes needed)
update public.game_config set value = value || '{"rarity_mult":{"common":1,"uncommon":1.3,"rare":1.6,"epic":2,"legendary":2.5}}'::jsonb where key = 'growth';
update public.game_config set value = jsonb_set(value, '{duplicate_rhizomes}', '{"common":1,"uncommon":2,"rare":3,"epic":5,"legendary":8}'::jsonb) where key = 'discovery';
insert into public.game_config (key, value) values
 ('boosts', '{"2x":{"mult":2,"hours":24,"coins":100,"rhizomes":2},
              "5x":{"mult":5,"hours":48,"coins":150,"rhizomes":3},
              "rarity_cost_mult":{"common":1,"uncommon":1.25,"rare":1.5,"epic":2,"legendary":3}}'),
 ('skip_gems', '{"common":[1,1,2,3],"uncommon":[1,2,3,4],"rare":[2,3,4,5],"epic":[3,4,5,6],"legendary":[4,5,6,8]}'),
 ('xp', '{"stage":[10,20,40,60],"discover_new":15,"duplicate_rhizomes":5,"achievement":25,"game":5,"game_perfect":10}'),
 ('levels', '{"xp_per_level":100,"coins":50,"rhizomes":1,"gems":1,"gem_every":5}'),
 ('away', '{"min_minutes":10}');

-- 2. Columns and tables
alter table public.plants
  add column if not exists boost_mult numeric not null default 1 check (boost_mult >= 1),
  add column if not exists stage_seen int not null default 1,      -- highest stage already paid XP for
  add column if not exists shown_stage int not null default 1;     -- stage the player last saw (for the away summary)
alter table public.profiles
  add column if not exists level int not null default 1 check (level >= 1),
  add column if not exists xp int not null default 0 check (xp >= 0),
  add column if not exists last_seen_at timestamptz;

create table public.xp_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  amount int not null check (amount >= 0),
  idem_key text not null,
  created_at timestamptz not null default now(),
  unique (user_id, idem_key)
);
create table public.level_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  level int not null,
  rewards jsonb not null,
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  unique (user_id, level)
);
alter table public.xp_events enable row level security;
alter table public.level_events enable row level security;
create policy "read own xp" on public.xp_events for select using (auth.uid() = user_id);
create policy "read own levels" on public.level_events for select using (auth.uid() = user_id);
revoke insert, update, delete on public.xp_events, public.level_events from authenticated, anon;

-- 3. Helpers
-- growth_scale (tall plants take twice as long) times the rarity multiplier
create function public._eff_scale(c public.plant_catalog) returns numeric language sql stable as $$
  select c.growth_scale * coalesce((cfg('growth')->'rarity_mult'->>c.rarity)::numeric, 1) $$;

-- growth phase 1..5 of a stage (tall plants spread the five phases over 20 stages)
create function public._phase(s int, mx int) returns int language sql immutable as $$
  select (floor((s - 1)::numeric / mx * 5) + 1)::int $$;

create function public._skip_cost(rar text, s int, mx int) returns int language sql stable as $$
  select case when s >= mx then null
    else (cfg('skip_gems')->rar->>(least(4, _phase(s, mx)) - 1))::int end $$;

create function public._boost_cost(kind text, cur text, rar text) returns int language sql stable as $$
  select ceil((cfg('boosts')->kind->>cur)::numeric * (cfg('boosts')->'rarity_cost_mult'->>rar)::numeric)::int $$;

-- Adds XP once per idem key and pays level-up rewards. Money goes through the ledger like everything else.
create function public._add_xp(u uuid, amt int, k text, idem text) returns void
language plpgsql security definer set search_path = public as $$
declare lv jsonb := cfg('levels'); pr profiles; ins int; newxp int; lvl int; need int; gems int;
begin
  if amt is null or amt <= 0 then return; end if;
  perform 1 from profiles where id = u for update;
  if not found then raise exception 'no profile'; end if;
  insert into xp_events (user_id, kind, amount, idem_key) values (u, k, amt, idem) on conflict (user_id, idem_key) do nothing;
  get diagnostics ins = row_count;
  if ins = 0 then return; end if;
  select * into pr from profiles where id = u;
  newxp := pr.xp + amt; lvl := pr.level;
  loop
    need := (lv->>'xp_per_level')::int * lvl;
    exit when newxp < need;
    newxp := newxp - need; lvl := lvl + 1;
    gems := case when lvl % (lv->>'gem_every')::int = 0 then (lv->>'gems')::int else 0 end;
    perform _grant(u, 'leaf_coins', (lv->>'coins')::int, 'level_up', 'level:' || lvl || ':coins');
    perform _grant(u, 'rhizomes', (lv->>'rhizomes')::int, 'level_up', 'level:' || lvl || ':rhizomes');
    if gems > 0 then perform _grant(u, 'collector_gems', gems, 'level_up', 'level:' || lvl || ':gems'); end if;
    insert into level_events (user_id, level, rewards) values (u, lvl,
      jsonb_build_object('leaf_coins', (lv->>'coins')::int, 'rhizomes', (lv->>'rhizomes')::int, 'collector_gems', gems))
      on conflict (user_id, level) do nothing;
  end loop;
  update profiles set xp = newxp, level = lvl where id = u;
end $$;

-- 4. One-time conversions of existing data (no back-pay of XP for what was already earned)
update public.plants p set growth_hours = p.growth_hours * coalesce((cfg('growth')->'rarity_mult'->>c.rarity)::numeric, 1)
  from public.plant_catalog c where c.id = p.type;          -- keeps each plant at the same progress under the longer rarity timings
update public.plants set stage_seen = stage, shown_stage = stage;
update public.plants set boost_mult = 2 where xp_boost_until > now();   -- migration 7 double-XP boosts are 2x boosts
insert into public.xp_events (user_id, kind, amount, idem_key)
  select user_id, 'achievement', 0, 'ach:' || achievement_id from public.player_achievements where completed_at is not null
  on conflict do nothing;

-- 5. Growth: rarity scale, boost strength, and stage XP
create or replace function public._advance(pid uuid) returns public.plants
language plpgsql security definer set search_path = public as $$
declare p plants; c plant_catalog; g jsonb := cfg('growth'); xc jsonb := cfg('xp'); uid uuid; sc numeric; k int; q int;
  r numeric := (g->>'moisture_loss_per_hour')::numeric;
  th numeric := (g->>'thirsty_below')::numeric; dr numeric := (g->>'dry_below')::numeric;
  t numeric; a numeric; b numeric; cc numeric; gain numeric; ov numeric; newh numeric;
begin
  select user_id into uid from plants where id = pid;
  if not found then raise exception 'plant not found'; end if;
  perform 1 from profiles where id = uid for update;          -- always lock the player first, then the plant
  select * into p from plants where id = pid for update;
  select * into c from plant_catalog where id = p.type;
  sc := _eff_scale(c);
  t := greatest(0, extract(epoch from (now() - p.moisture_at)) / 3600.0);
  a := least(t, greatest(0, (p.moisture - th) / r));
  b := greatest(0, least(t, greatest(0, (p.moisture - dr) / r)) - greatest(0, (p.moisture - th) / r));
  cc := t - a - b;
  gain := a*(g->>'rate_healthy')::numeric + b*(g->>'rate_thirsty')::numeric + cc*(g->>'rate_dry')::numeric;
  if p.xp_boost_until is not null and p.xp_boost_until > p.moisture_at and t > 0 then
    ov := extract(epoch from (least(now(), p.xp_boost_until) - p.moisture_at)) / 3600.0;   -- hours of this period that were boosted
    gain := gain * (1 + least(1, ov / t) * (p.boost_mult - 1));
  end if;
  newh := least(_total_hours(sc), p.growth_hours + gain);
  update plants set moisture = greatest(0, p.moisture - r*t), moisture_at = now(), growth_hours = newh,
         stage = _stage_for(newh, c.max_stage, sc)
   where id = pid returning * into p;
  -- XP for each new growth phase reached (1>2 = 10, 2>3 = 20, 3>4 = 40, 4>5 = 60). Admin-granted plants pay nothing.
  if p.stage > p.stage_seen then
    if p.acquired_source <> 'admin' then
      for k in (p.stage_seen + 1)..p.stage loop
        q := _phase(k, c.max_stage);
        if q >= 2 and q > _phase(k - 1, c.max_stage) then
          perform _add_xp(p.user_id, (xc->'stage'->>(q - 2))::int, 'stage', 'stage:' || p.id || ':' || k);
        end if;
      end loop;
    end if;
    update plants set stage_seen = p.stage where id = pid returning * into p;
  end if;
  if p.stage = c.max_stage and not p.final_rewarded then
    perform _grant(p.user_id, 'leaf_coins', (cfg('economy')->>'stage_final_reward')::int, 'growth_final', 'final:' || p.id);
    update plants set final_rewarded = true where id = pid returning * into p;
  end if;
  return p;
end $$;

-- 6. What the app sees for each plant
create or replace function public._plant_json(p public.plants) returns jsonb language sql stable as $$
  select jsonb_build_object('id',p.id,'type',p.type,'name',p.name,'stage',p.stage,'spot',p.spot,'moisture',p.moisture,
    'public_display',p.public_display,'cultivar',c.name,'rarity',c.rarity,'max_stage',c.max_stage,'tall',c.tall,
    'progress',least(1, p.growth_hours / _total_hours(_eff_scale(c))),
    'xp', round(greatest(0, p.growth_hours - _hours_for_stage(p.stage, c.max_stage, _eff_scale(c))), 1),
    'xp_needed', case when p.stage < c.max_stage then
        round(_hours_for_stage(p.stage + 1, c.max_stage, _eff_scale(c)) - _hours_for_stage(p.stage, c.max_stage, _eff_scale(c)), 1) end,
    'eta_hours', case when p.stage < c.max_stage then
        round(greatest(0, _hours_for_stage(p.stage + 1, c.max_stage, _eff_scale(c)) - p.growth_hours)
              / (case when p.xp_boost_until > now() then p.boost_mult else 1 end), 1) end,
    'boost_mult', case when p.xp_boost_until > now() then p.boost_mult end,
    'boost_until', case when p.xp_boost_until > now() then p.xp_boost_until end,
    'skip_cost', _skip_cost(c.rarity, p.stage, c.max_stage),
    'boost_costs', jsonb_build_object(
        '2x', jsonb_build_object('coins', _boost_cost('2x','coins',c.rarity), 'rhizomes', _boost_cost('2x','rhizomes',c.rarity), 'hours', (cfg('boosts')->'2x'->>'hours')::int),
        '5x', jsonb_build_object('coins', _boost_cost('5x','coins',c.rarity), 'rhizomes', _boost_cost('5x','rhizomes',c.rarity), 'hours', (cfg('boosts')->'5x'->>'hours')::int)))
  from plant_catalog c where c.id = p.type $$;

create or replace function public.admin_set_stage(pid uuid, new_stage int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); c plant_catalog; p plants;
begin
  if not coalesce((select is_admin from profiles where id = u), false) then raise exception 'admins only'; end if;
  select * into p from plants where id = pid and user_id = u;
  if not found then raise exception 'not your plant'; end if;
  select * into c from plant_catalog where id = p.type;
  if new_stage < 1 or new_stage > c.max_stage then raise exception 'stage out of range'; end if;
  update plants set growth_hours = _hours_for_stage(new_stage, c.max_stage, _eff_scale(c)), moisture_at = now(), stage = new_stage,
         stage_seen = greatest(stage_seen, new_stage), shown_stage = new_stage          -- admin changes pay no XP and are not "growth"
   where id = pid returning * into p;
  return _plant_json(p);
end $$;

-- 7. Discovery: a new plant earns XP (admin grants do not)
create or replace function public._give_plant(u uuid, cid text, src text) returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into plants (user_id, type, name, stage, acquired_source)
    select u, id, name, 1, src from plant_catalog where id = cid and active
    on conflict (user_id, type) do nothing;
  get diagnostics n = row_count;
  if n = 1 and src <> 'admin' then
    perform _add_xp(u, (cfg('xp')->>'discover_new')::int, 'discover', 'discover:' || cid);
  end if;
  return n = 1;      -- false means the player already owned it
end $$;

-- 8. Achievements: completing one earns XP once
create or replace function public._evaluate_achievements(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare a achievements; pr int; n int := (select count(*) from plant_catalog where active);
begin
  for a in select * from achievements where active loop
    if a.kind = 'plants_owned' and a.target > n then continue; end if;      -- not earnable until the catalog is big enough
    pr := least(a.target, _achievement_progress(u, a));
    insert into player_achievements (user_id, achievement_id, progress, completed_at)
      values (u, a.id, pr, case when pr >= a.target then now() end)
      on conflict (user_id, achievement_id) do update
        set progress = greatest(player_achievements.progress, excluded.progress),
            completed_at = coalesce(player_achievements.completed_at, excluded.completed_at);
    if pr >= a.target then
      perform _add_xp(u, (cfg('xp')->>'achievement')::int, 'achievement', 'ach:' || a.id);   -- no-op after the first time
    end if;
  end loop;
end $$;

-- 9. Duplicates: Rhizomes (+5 XP) or a free 2x boost on the plant you already own
create or replace function public.resolve_duplicate(item_id uuid, choice text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery'); b jsonb := cfg('boosts')->'2x'; it duplicate_items; pid uuid; rhiz int; boost_end timestamptz; pname text;
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
    perform _add_xp(u, (cfg('xp')->>'duplicate_rhizomes')::int, 'duplicate', 'dupxp:' || it.id);
    return jsonb_build_object('choice', 'rhizomes', 'rhizomes', rhiz);
  end if;
  select id into pid from plants where user_id = u and type = it.plant_type;
  if pid is null then raise exception 'You no longer own that plant'; end if;
  perform _advance(pid);                                   -- bank growth so far, so the boost only affects the future
  if exists (select 1 from plants where id = pid and xp_boost_until > now()) then
    raise exception 'That plant already has an active boost';
  end if;
  update plants set boost_mult = (b->>'mult')::numeric, xp_boost_until = now() + make_interval(secs => (b->>'hours')::numeric * 3600)
   where id = pid returning xp_boost_until, name into boost_end, pname;
  update duplicate_items set resolved_at = now(), resolution = 'double_xp' where id = it.id;
  return jsonb_build_object('choice', 'double_xp', 'plant_name', pname, 'until', boost_end);
end $$;

-- 10. Boosts bought with Leaf Coins or Rhizomes (one active boost per plant)
create function public.buy_boost(pid uuid, kind text, pay_with text, req_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); p plants; c plant_catalog; b jsonb; cost int; bal int; cur text;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  if kind not in ('2x','5x') then raise exception 'unknown boost'; end if;
  if pay_with not in ('leaf_coins','rhizomes') then raise exception 'pay with Leaf Coins or Species Rhizomes'; end if;
  perform 1 from profiles where id = u for update;
  select * into p from plants where id = pid and user_id = u;
  if not found then raise exception 'not your plant'; end if;
  if exists (select 1 from currency_ledger where user_id = u and idem_key = 'boost:' || req_id) then   -- repeated request: change nothing
    return _plant_json(p) || jsonb_build_object('replay', true);
  end if;
  p := _advance(pid);
  if p.xp_boost_until > now() then raise exception 'This plant already has an active boost'; end if;
  select * into c from plant_catalog where id = p.type;
  b := cfg('boosts')->kind;
  cur := case pay_with when 'leaf_coins' then 'coins' else 'rhizomes' end;
  cost := _boost_cost(kind, cur, c.rarity);
  execute format('select %I from profiles where id = $1', pay_with) into bal using u;
  if bal < cost then raise exception 'Not enough %', replace(pay_with, '_', ' '); end if;
  perform _grant(u, pay_with, -cost, 'boost_' || kind, 'boost:' || req_id);
  update plants set boost_mult = (b->>'mult')::numeric, xp_boost_until = now() + make_interval(secs => (b->>'hours')::numeric * 3600)
   where id = pid returning * into p;
  return _plant_json(p) || jsonb_build_object('cost', cost, 'paid_with', pay_with);
end $$;

-- 11. Gem skip: jump to the next growth phase right now (for 5-stage plants that is simply the next stage)
create function public.skip_stage(pid uuid, req_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); p plants; c plant_catalog; cost int; target int; s int;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  perform 1 from profiles where id = u for update;
  select * into p from plants where id = pid and user_id = u;
  if not found then raise exception 'not your plant'; end if;
  if exists (select 1 from currency_ledger where user_id = u and idem_key = 'skip:' || req_id) then
    return _plant_json(p) || jsonb_build_object('replay', true);
  end if;
  p := _advance(pid);
  select * into c from plant_catalog where id = p.type;
  if p.stage >= c.max_stage then raise exception 'This plant is fully grown'; end if;
  cost := _skip_cost(c.rarity, p.stage, c.max_stage);
  if (select collector_gems from profiles where id = u) < cost then raise exception 'Not enough collector gems'; end if;
  target := c.max_stage;
  for s in (p.stage + 1)..c.max_stage loop
    if _phase(s, c.max_stage) > _phase(p.stage, c.max_stage) then target := s; exit; end if;
  end loop;
  perform _grant(u, 'collector_gems', -cost, 'skip_stage', 'skip:' || req_id);
  update plants set growth_hours = _hours_for_stage(target, c.max_stage, _eff_scale(c)), moisture_at = now(), stage = target
   where id = pid;
  p := _advance(pid);                                      -- pays stage XP and the final-stage reward if reached
  return _plant_json(p) || jsonb_build_object('cost', cost, 'new_stage', p.stage);
end $$;

-- 12. "While you were away": call this BEFORE get_game_state (get_game_state resets the last-seen time)
create function public.get_away_summary() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pr profiles; pid uuid; th numeric := (cfg('growth')->>'thirsty_below')::numeric;
  grown jsonb; lv jsonb; ach jsonb; bend jsonb; dry jsonb;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into pr from profiles where id = u;
  if pr.last_seen_at is null or pr.last_seen_at > now() - make_interval(mins => (cfg('away')->>'min_minutes')::int) then return null; end if;
  for pid in select id from plants where user_id = u loop perform _advance(pid); end loop;
  perform _evaluate_achievements(u);
  select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'type', p.type, 'cultivar', c.name, 'rarity', c.rarity,
           'from', p.shown_stage, 'to', p.stage, 'max_stage', c.max_stage) order by p.created_at), '[]'::jsonb) into grown
    from plants p join plant_catalog c on c.id = p.type where p.user_id = u and p.stage > p.shown_stage;
  select coalesce(jsonb_agg(jsonb_build_object('level', level, 'rewards', rewards) order by level), '[]'::jsonb) into lv
    from level_events where user_id = u and seen_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'icon', a.icon) order by a.sort), '[]'::jsonb) into ach
    from player_achievements pa join achievements a on a.id = pa.achievement_id where pa.user_id = u and pa.completed_at > pr.last_seen_at;
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'mult', boost_mult)), '[]'::jsonb) into bend
    from plants where user_id = u and xp_boost_until > pr.last_seen_at and xp_boost_until <= now();
  select coalesce(jsonb_agg(jsonb_build_object('name', name)), '[]'::jsonb) into dry
    from plants where user_id = u and moisture < th;
  if jsonb_array_length(grown) + jsonb_array_length(lv) + jsonb_array_length(ach) + jsonb_array_length(bend) = 0 then return null; end if;
  return jsonb_build_object('away_minutes', round(extract(epoch from now() - pr.last_seen_at) / 60),
    'grown', grown, 'levels', lv, 'achievements', ach, 'boosts_ended', bend, 'needs_water', dry);
end $$;

create function public.ack_level_ups() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update level_events set seen_at = now() where user_id = auth.uid() and seen_at is null;
end $$;

-- 13. Main state call: adds level, XP and unseen level-ups; records that the player has seen the garden
create or replace function public.get_game_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pid uuid; today date := (now() at time zone 'utc')::date; lv jsonb := cfg('levels'); b jsonb := cfg('boosts');
begin
  if u is null then raise exception 'not signed in'; end if;
  for pid in select id from plants where user_id = u loop perform _advance(pid); end loop;
  perform _evaluate_achievements(u);
  update profiles set last_seen_at = now() where id = u;
  update plants set shown_stage = stage where user_id = u and shown_stage <> stage;
  return jsonb_build_object(
    'profile', (select jsonb_build_object('display_name',display_name,'leaf_coins',leaf_coins,'collector_gems',collector_gems,'rhizomes',rhizomes,'is_admin',is_admin,
                  'level',level,'xp',xp,'xp_needed',(lv->>'xp_per_level')::int * level) from profiles where id = u),
    'level_rewards', jsonb_build_object('leaf_coins',(lv->>'coins')::int,'rhizomes',(lv->>'rhizomes')::int,'gem_every',(lv->>'gem_every')::int,'gems',(lv->>'gems')::int),
    'level_ups', (select coalesce(jsonb_agg(jsonb_build_object('level',level,'rewards',rewards) order by level), '[]'::jsonb) from level_events where user_id = u and seen_at is null),
    'daily', jsonb_build_object(
      'login_claimed', exists(select 1 from currency_ledger where user_id = u and idem_key = 'login:' || today),
      'care_claimed',  exists(select 1 from currency_ledger where user_id = u and idem_key = 'care:' || today)),
    'ready_achievements', (select count(*) from player_achievements pa join achievements a on a.id = pa.achievement_id
                           where pa.user_id = u and a.active and pa.completed_at is not null and pa.claimed_at is null),
    'boost', jsonb_build_object('hours', (b->'2x'->>'hours')::numeric, 'multiplier', (b->'2x'->>'mult')::numeric),
    'duplicates', (select coalesce(jsonb_agg(jsonb_build_object('id', di.id, 'plant_type', di.plant_type, 'cultivar', c.name, 'rarity', di.rarity,
                     'rhizomes', (cfg('discovery')->'duplicate_rhizomes'->>di.rarity)::int) order by di.created_at), '[]'::jsonb)
                   from duplicate_items di join plant_catalog c on c.id = di.plant_type where di.user_id = u and di.resolved_at is null),
    'plants', (select coalesce(jsonb_agg(_plant_json(p) order by p.created_at), '[]'::jsonb) from plants p where p.user_id = u),
    'catalog', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'rarity',rarity) order by name), '[]'::jsonb) from plant_catalog where active));
end $$;

-- 14. Permissions
revoke execute on function public._eff_scale(public.plant_catalog), public._phase(int,int), public._skip_cost(text,int,int),
  public._boost_cost(text,text,text), public._add_xp(uuid,int,text,text) from public, anon, authenticated;
revoke execute on function public.buy_boost(uuid,text,text,uuid), public.skip_stage(uuid,uuid), public.get_away_summary(), public.ack_level_ups() from public, anon;
grant execute on function public.buy_boost(uuid,text,text,uuid), public.skip_stage(uuid,uuid), public.get_away_summary(), public.ack_level_ups() to authenticated;
notify pgrst, 'reload schema';
