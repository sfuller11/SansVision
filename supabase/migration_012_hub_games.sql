-- MIGRATION 12: slower, bigger spinner; garden plants are shown when placed (no "Show to visitors" switch); three new mini-games
-- (Water Balance, Vine Climb, Garden Snake); the featured garden for the new Home screen.
-- Run once in Supabase (SQL Editor) after migration_011.
--
-- What changes for existing players:
--   * Plants that were on a garden spot but hidden from visitors are taken off their spot (they return to "Not placed"),
--     so nothing a player chose to hide becomes public.

-- 1. Garden display: placed means shown
update public.plants set garden_id = null, spot = null where spot is not null and not public_display;
drop function if exists public.set_plant_display(uuid, boolean);

create or replace function public.list_public_gardens(sort text default 'recent', page_offset int default 0, page_size int default 12)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); ps int := least(greatest(coalesce(page_size, 12), 1), 24); ofs int := greatest(coalesce(page_offset, 0), 0); items jsonb; more boolean;
begin
  if u is null then raise exception 'not signed in'; end if;
  sort := coalesce(sort, 'recent');
  if sort not in ('recent', 'likes', 'level') then raise exception 'unknown sort'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) - 'ord_a' - 'ord_b' order by r.ord_a desc nulls last, r.ord_b desc nulls last, r.published_at desc, r.id desc), '[]'::jsonb) into items from (
    select * from (
      select g.id, g.name, g.published_at, g.garden_type, g.like_count,
        exists (select 1 from garden_likes l where l.garden_id = g.id and l.user_id = u) as liked_by_me,
        g.owner_id = u as is_mine, pr.display_name as owner_name, pr.avatar_path as owner_avatar, pr.avatar_v as owner_avatar_v, pr.level as owner_level,
        (select count(distinct pl.type) from plants pl where pl.garden_id = g.id and pl.spot is not null) as cultivars,
        (select count(*) from player_achievements pa where pa.user_id = g.owner_id and pa.claimed_at is not null) as achievements,
        (select coalesce(jsonb_agg(jsonb_build_object('type', x.type, 'stage', x.stage)), '[]'::jsonb)
           from (select pl.type, pl.stage from plants pl where pl.garden_id = g.id and pl.spot is not null
                 order by pl.stage desc, pl.type limit 4) x) as preview,
        case sort when 'likes' then g.like_count when 'level' then pr.level end as ord_a,
        case sort when 'level' then pr.xp end as ord_b
      from gardens g join profiles pr on pr.id = g.owner_id
      where g.is_public and exists (select 1 from plants pl where pl.garden_id = g.id and pl.spot is not null)
    ) s
    order by s.ord_a desc nulls last, s.ord_b desc nulls last, s.published_at desc, s.id desc
    offset ofs limit ps + 1) r;
  more := jsonb_array_length(items) > ps;
  if more then items := (select jsonb_agg(e order by o) from jsonb_array_elements(items) with ordinality t(e, o) where o <= ps); end if;
  return jsonb_build_object('gardens', items, 'has_more', more, 'next_offset', ofs + ps);
end $$;

create or replace function public.random_public_garden() returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select g.id into gid from gardens g where g.is_public and g.owner_id <> auth.uid()
    and exists (select 1 from plants pl where pl.garden_id = g.id and pl.spot is not null)
    order by random() limit 1;
  if gid is null then raise exception 'No public gardens to visit yet'; end if;
  return gid;
end $$;

create or replace function public.visit_garden(gid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g gardens; t garden_types;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into g from gardens where id = gid and (is_public or owner_id = u);
  if not found then raise exception 'Garden not found'; end if;
  select * into t from garden_types where id = g.garden_type;
  if g.owner_id <> u then insert into garden_visits (visitor_id, garden_id) values (u, g.id) on conflict do nothing; end if;
  return jsonb_build_object('id', g.id, 'name', g.name, 'description', g.description, 'garden_type', g.garden_type, 'layout', t.layout, 'type_name', t.name,
    'is_mine', g.owner_id = u, 'like_count', g.like_count, 'liked_by_me', exists (select 1 from garden_likes l where l.garden_id = g.id and l.user_id = u),
    'owner_name', (select display_name from profiles where id = g.owner_id), 'owner_level', (select level from profiles where id = g.owner_id),
    'owner_avatar', (select avatar_path from profiles where id = g.owner_id), 'owner_avatar_v', (select avatar_v from profiles where id = g.owner_id),
    'plants', (select coalesce(jsonb_agg(jsonb_build_object('spot', p.spot, 'type', p.type, 'name', p.name, 'cultivar', c.name,
        'rarity', c.rarity, 'stage', p.stage, 'max_stage', c.max_stage, 'tall', c.tall, 'care', _care_label(p),
        'moisture', round(greatest(0, p.moisture - (cfg('growth')->>'moisture_loss_per_hour')::numeric * extract(epoch from now() - p.moisture_at) / 3600.0))) order by p.spot), '[]'::jsonb)
      from plants p join plant_catalog c on c.id = p.type where p.garden_id = g.id and p.spot is not null),
    'collector', jsonb_build_object('unique_plants', (select count(*) from plants where user_id = g.owner_id),
      'achievements', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'icon', a.icon) order by a.sort), '[]'::jsonb)
        from player_achievements pa join achievements a on a.id = pa.achievement_id where pa.user_id = g.owner_id and pa.claimed_at is not null)));
end $$;

-- 2. Featured garden for the Home screen: the public garden (not yours, if there is another) with the most likes in the last 7 days.
--    With no recent likes it is a stable pick that changes each UTC day. Viewing it here does not count as a visit.
create function public.get_featured_garden() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g gardens; t garden_types; wk int;
begin
  if u is null then raise exception 'not signed in'; end if;
  select gg.* into g from gardens gg
   where gg.is_public and exists (select 1 from plants pl where pl.garden_id = gg.id and pl.spot is not null)
   order by (gg.owner_id = u),
            (select count(*) from garden_likes l where l.garden_id = gg.id and l.created_at > now() - interval '7 days') desc,
            md5(gg.id::text || ((now() at time zone 'utc')::date)::text), gg.id
   limit 1;
  if not found then return null; end if;
  select * into t from garden_types where id = g.garden_type;
  select count(*) into wk from garden_likes where garden_id = g.id and created_at > now() - interval '7 days';
  return jsonb_build_object('id', g.id, 'name', g.name, 'garden_type', g.garden_type, 'layout', t.layout, 'type_name', t.name,
    'is_mine', g.owner_id = u, 'like_count', g.like_count, 'week_likes', wk,
    'liked_by_me', exists (select 1 from garden_likes l where l.garden_id = g.id and l.user_id = u),
    'owner_name', (select display_name from profiles where id = g.owner_id), 'owner_level', (select level from profiles where id = g.owner_id),
    'owner_avatar', (select avatar_path from profiles where id = g.owner_id), 'owner_avatar_v', (select avatar_v from profiles where id = g.owner_id),
    'plants', (select coalesce(jsonb_agg(jsonb_build_object('spot', p.spot, 'type', p.type, 'cultivar', p.name, 'stage', p.stage, 'moisture', 100) order by p.spot), '[]'::jsonb)
      from plants p where p.garden_id = g.id and p.spot is not null));
end $$;

-- 3. Games: settings (spinner now 3 spins a day, one every 8 hours)
update public.game_config set value = value || '{
  "spinner":       {"cooldown_hours":8, "daily":3},
  "water_balance": {"hourly":4, "daily":15, "min_seconds":10, "max_per_second":1,   "tiers":[4,6,8]},
  "vine_climb":    {"hourly":4, "daily":15, "min_seconds":12, "max_per_second":1,   "tiers":[10,20,30]},
  "garden_snake":  {"hourly":4, "daily":15, "min_seconds":12, "max_per_second":0.9, "tiers":[7,15,25]}
}'::jsonb where key = 'games';
alter table public.game_plays drop constraint if exists game_plays_game_check;
alter table public.game_plays add constraint game_plays_game_check
  check (game in ('leaf_match','rhizome_rush','odd_plant_out','water_balance','vine_climb','garden_snake','spinner'));

create or replace function public.start_game(game text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); st jsonb; gp game_plays;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  if game not in ('leaf_match','rhizome_rush','odd_plant_out','water_balance','vine_climb','garden_snake') then raise exception 'unknown game'; end if;
  perform 1 from profiles where id = u for update;
  select * into gp from game_plays where id = req_id and user_id = u;
  if found then return jsonb_build_object('play_id', gp.id, 'game', gp.game, 'replay', true); end if;
  st := _game_status(u, game);
  if (st->>'day_left')::int <= 0 then raise exception 'No plays left today'; end if;
  if (st->>'hour_left')::int <= 0 then raise exception 'Hourly limit reached. Come back a little later'; end if;
  insert into game_plays (id, user_id, game) values (req_id, u, game);
  return jsonb_build_object('play_id', req_id, 'game', game, 'session_seconds', (cfg('games')->>'session_minutes')::int * 60);
end $$;

-- Water Balance (rounds landed), Vine Climb (water drops caught) and Garden Snake (sprouts eaten) are scored by the browser,
-- so the server limits what it believes: the count cannot exceed the real elapsed time times a per-second cap, and plays that
-- finish faster than a human could are paid nothing. Prizes stay small and capped, like Leaf Match and Rhizome Rush.
create or replace function public.finish_game(play_id uuid, metrics jsonb default '{}') returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); gp game_plays; g jsonb := cfg('games'); gc jsonb; key text; elapsed numeric; tr int; coins int := 0; rh int := 0; perf boolean := false;
  m int; res jsonb; xpv int; n int; adj numeric;
begin
  if u is null then raise exception 'not signed in'; end if;
  perform 1 from profiles where id = u for update;
  select * into gp from game_plays where id = play_id and user_id = u for update;
  if not found then raise exception 'Game not found'; end if;
  if gp.game = 'spinner' then raise exception 'Use spin for the spinner'; end if;
  if gp.finished_at is not null then return gp.reward || jsonb_build_object('replay', true); end if;
  elapsed := extract(epoch from now() - gp.started_at);
  if elapsed > (g->>'session_minutes')::numeric * 60 or elapsed < (g->(gp.game)->>'min_seconds')::numeric then
    res := jsonb_build_object('tier', 0, 'coins', 0, 'rhizomes', 0, 'xp', 0, 'no_reward', case when elapsed < (g->(gp.game)->>'min_seconds')::numeric then 'too_fast' else 'expired' end);
    update game_plays set finished_at = now(), tier = 0, reward = res where id = gp.id;
    return res;
  end if;

  if gp.game = 'leaf_match' then
    m := case when coalesce(metrics->>'misses', '') ~ '^[0-9]{1,3}$' then (metrics->>'misses')::int else 99 end;
    tr := case when m = 0 then 4 when m <= 2 then 3 when m <= 5 then 2 else 1 end;
    perf := m = 0;
    coins := case tr when 1 then 20 + floor(random() * 21)::int when 2 then 50 + floor(random() * 26)::int when 3 then 75 + floor(random() * 26)::int else 150 end;
    rh := case when tr = 4 then 1 when tr = 3 and random() < 0.10 then 1 else 0 end;
  elsif gp.game = 'rhizome_rush' then
    m := case when coalesce(metrics->>'hits', '') ~ '^[0-9]{1,3}$' then least(10, (metrics->>'hits')::int) else 0 end;
    tr := case when m >= 7 then 3 when m >= 5 then 2 else 1 end;
    perf := m = 10;
    coins := case tr when 1 then 15 when 2 then 25 else 40 end;
    rh := case when tr = 3 then 1 else 0 end;
  elsif gp.game = 'odd_plant_out' then   -- server time plus a penalty for each wrong tap the browser reports (capped at 10)
    m := case when coalesce(metrics->>'misses', '') ~ '^[0-9]{1,3}$' then least(10, (metrics->>'misses')::int) else 10 end;
    adj := elapsed + m * (g->'odd_plant_out'->>'penalty_seconds')::numeric;
    tr := case when adj < (g->'odd_plant_out'->'tier_seconds'->>0)::numeric then 4
               when adj < (g->'odd_plant_out'->'tier_seconds'->>1)::numeric then 3
               when adj < (g->'odd_plant_out'->'tier_seconds'->>2)::numeric then 2 else 1 end;
    perf := tr = 4;
    coins := case tr when 1 then 20 when 2 then 40 when 3 then 60 else 100 end;
    rh := case when tr = 3 then 1 when tr = 4 and random() < 0.5 then 1 else 0 end;
  else   -- water_balance, vine_climb, garden_snake
    gc := g->(gp.game);
    key := case gp.game when 'water_balance' then 'landed' when 'vine_climb' then 'drops' else 'food' end;
    m := case when coalesce(metrics->>key, '') ~ '^[0-9]{1,4}$' then (metrics->>key)::int else 0 end;
    m := least(m, floor(elapsed * (gc->>'max_per_second')::numeric)::int);
    tr := case when m >= (gc->'tiers'->>2)::int then 4 when m >= (gc->'tiers'->>1)::int then 3 when m >= (gc->'tiers'->>0)::int then 2 else 1 end;
    perf := tr = 4;
    coins := case tr when 1 then 20 when 2 then 40 when 3 then 60 else 100 end;
    rh := case when tr = 4 and random() < 0.5 then 1 when tr = 3 and random() < 0.15 then 1 else 0 end;
  end if;

  perform _grant(u, 'leaf_coins', coins, 'game_' || gp.game, 'game:' || gp.id || ':coins');
  if rh > 0 then perform _grant(u, 'rhizomes', rh, 'game_' || gp.game, 'game:' || gp.id || ':rh'); end if;
  xpv := case when perf then (cfg('xp')->>'game_perfect')::int else (cfg('xp')->>'game')::int end;
  perform _add_xp(u, xpv, 'game', 'game:' || gp.id);
  res := jsonb_build_object('tier', tr, 'coins', coins, 'rhizomes', rh, 'perfect', perf, 'xp', xpv);

  if gp.game = 'rhizome_rush' then                         -- five perfect rounds in a row pay a bonus
    insert into game_progress (user_id) values (u) on conflict do nothing;
    if perf then
      update game_progress set rush_perfects = rush_perfects + 1 where user_id = u returning rush_perfects into n;
      if n >= (g->>'rush_perfects_needed')::int then
        perform _grant(u, 'leaf_coins', (g->'rush_bonus'->>'coins')::int, 'game_rush_streak', 'rush5:' || gp.id || ':coins');
        perform _grant(u, 'rhizomes', (g->'rush_bonus'->>'rhizomes')::int, 'game_rush_streak', 'rush5:' || gp.id || ':rh');
        update game_progress set rush_perfects = 0 where user_id = u;
        res := res || jsonb_build_object('rush_bonus', g->'rush_bonus'); n := 0;
      end if;
    else
      update game_progress set rush_perfects = 0 where user_id = u; n := 0;
    end if;
    res := res || jsonb_build_object('rush_perfects', n);
  end if;

  res := res || _game_day_bonus(u);
  update game_plays set finished_at = now(), tier = tr, perfect = perf, reward = res where id = gp.id;
  return res;
end $$;

-- Spinner: 100 / 125 coins, 150 coins + 1 Rhizome, 200 coins + 2 Rhizomes, then 5 Rhizomes alone, then 1 Gem alone (1 in 100).
create or replace function public.spin(req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); st jsonb; gp game_plays; roll numeric := random() * 100; cum numeric := 0; seg int := 5; i int; res jsonb;
  weights numeric[] := array[38, 28, 20, 10, 3, 1];
  coins_t int[] := array[100, 125, 150, 200, 0, 0];
  rh_t int[] := array[0, 0, 1, 2, 5, 0];
  gem_t int[] := array[0, 0, 0, 0, 0, 1];
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  perform 1 from profiles where id = u for update;
  select * into gp from game_plays where id = req_id and user_id = u;
  if found then return gp.reward || jsonb_build_object('replay', true); end if;
  st := _game_status(u, 'spinner');
  if (st->>'day_left')::int <= 0 then raise exception 'No spins left today'; end if;
  if (st->>'hour_left')::int <= 0 then raise exception 'The spinner is recharging'; end if;
  for i in 1..6 loop
    cum := cum + weights[i];
    if roll < cum then seg := i - 1; exit; end if;
  end loop;
  insert into game_plays (id, user_id, game, finished_at, tier) values (req_id, u, 'spinner', now(), seg + 1);
  if coins_t[seg + 1] > 0 then perform _grant(u, 'leaf_coins', coins_t[seg + 1], 'game_spinner', 'game:' || req_id || ':coins'); end if;
  if rh_t[seg + 1] > 0 then perform _grant(u, 'rhizomes', rh_t[seg + 1], 'game_spinner', 'game:' || req_id || ':rh'); end if;
  if gem_t[seg + 1] > 0 then perform _grant(u, 'collector_gems', gem_t[seg + 1], 'game_spinner', 'game:' || req_id || ':gem'); end if;
  perform _add_xp(u, (cfg('xp')->>'game')::int, 'game', 'game:' || req_id);
  res := jsonb_build_object('segment', seg, 'tier', seg + 1, 'coins', coins_t[seg + 1], 'rhizomes', rh_t[seg + 1], 'gems', gem_t[seg + 1],
                            'xp', (cfg('xp')->>'game')::int) || _game_day_bonus(u);
  update game_plays set reward = res where id = req_id;
  return res;
end $$;

create or replace function public.get_games_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g jsonb := cfg('games'); today date := (now() at time zone 'utc')::date; gd game_days; n int;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into gd from game_days where user_id = u and day = today;
  n := _game_streak(u);
  return jsonb_build_object(
    'games', jsonb_build_object('leaf_match', _game_status(u, 'leaf_match'), 'rhizome_rush', _game_status(u, 'rhizome_rush'),
                                'odd_plant_out', _game_status(u, 'odd_plant_out'), 'water_balance', _game_status(u, 'water_balance'),
                                'vine_climb', _game_status(u, 'vine_climb'), 'garden_snake', _game_status(u, 'garden_snake'),
                                'spinner', _game_status(u, 'spinner')),
    'today', jsonb_build_object('completed', coalesce(gd.completed, 0), 'needed', (g->'daily_streak'->>'games')::int, 'bonus_paid', coalesce(gd.bonus_paid, false),
                                'bonus', g->'daily_streak'),
    'streak', jsonb_build_object('days', n, 'week_days', (g->'weekly_streak'->>'days')::int, 'weekly', g->'weekly_streak'),
    'rush', jsonb_build_object('perfects', coalesce((select rush_perfects from game_progress where user_id = u), 0), 'needed', (g->>'rush_perfects_needed')::int, 'bonus', g->'rush_bonus'));
end $$;

-- 4. Permissions
revoke execute on function public.get_featured_garden() from public, anon;
grant execute on function public.get_featured_garden() to authenticated;
notify pgrst, 'reload schema';
