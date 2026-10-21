-- MIGRATION 9: mini-games (Leaf Match, Rhizome Rush, Garden Cleanup, Growth Burst Spinner), play limits, daily and weekly streaks.
-- Run ONCE in Supabase (SQL Editor) after migration_008.
--
-- How cheating is limited: every play is a server-side record. start_game uses up a play (so quitting and retrying costs plays),
-- limits are counted on the server, and finish_game works out the reward on the server. Garden Cleanup uses the SERVER's clock.
-- Leaf Match "misses" and Rhizome Rush "hits" are reported by the browser, so a determined player could fake them,
-- but they can never beat the reward caps or the hourly/daily limits. The spinner is rolled entirely on the server.

insert into public.game_config (key, value) values ('games', '{
  "leaf_match":     {"hourly":3, "daily":15, "min_seconds":8},
  "rhizome_rush":   {"hourly":5, "daily":20, "min_seconds":8},
  "garden_cleanup": {"hourly":2, "daily":10, "min_seconds":6},
  "spinner":        {"cooldown_hours":4, "daily":6},
  "session_minutes": 10,
  "rush_perfects_needed": 5, "rush_bonus": {"coins":50,"rhizomes":1},
  "daily_streak":  {"games":3, "coins":50, "rhizomes":1},
  "weekly_streak": {"days":7, "coins":150, "rhizomes":3, "gems":1}
}');

create table public.game_plays (
  id uuid primary key,                         -- the browser's request id, so a repeated request cannot use up two plays
  user_id uuid not null references auth.users(id) on delete cascade,
  game text not null check (game in ('leaf_match','rhizome_rush','garden_cleanup','spinner')),
  day date not null default (now() at time zone 'utc')::date,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  tier int,
  perfect boolean not null default false,
  reward jsonb
);
create index game_plays_user_game_idx on public.game_plays (user_id, game, started_at desc);
create table public.game_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  completed int not null default 0,
  bonus_paid boolean not null default false,
  primary key (user_id, day)
);
create table public.game_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  rush_perfects int not null default 0
);
alter table public.game_plays enable row level security;
alter table public.game_days enable row level security;
alter table public.game_progress enable row level security;
create policy "read own plays" on public.game_plays for select using (auth.uid() = user_id);
create policy "read own days" on public.game_days for select using (auth.uid() = user_id);
create policy "read own progress" on public.game_progress for select using (auth.uid() = user_id);
revoke insert, update, delete on public.game_plays, public.game_days, public.game_progress from authenticated, anon;

-- Remaining plays for one game (hourly window is rolling; the day is the UTC day)
create function public._game_status(u uuid, g text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare gc jsonb := cfg('games')->g; today date := (now() at time zone 'utc')::date; hc int; dc int; hl int; nxt timestamptz; win interval;
begin
  select count(*) into dc from game_plays where user_id = u and game = g and day = today;
  if g = 'spinner' then
    win := make_interval(secs => (gc->>'cooldown_hours')::numeric * 3600);
    select count(*), min(started_at) into hc, nxt from (select started_at from game_plays where user_id = u and game = g order by started_at desc limit 1) x where started_at > now() - win;
    hl := 1 - hc;
  else
    win := interval '1 hour';
    select count(*), min(started_at) into hc, nxt from game_plays where user_id = u and game = g and started_at > now() - win;
    hl := (gc->>'hourly')::int - hc;
  end if;
  return jsonb_build_object('hour_left', greatest(0, hl), 'day_left', greatest(0, (gc->>'daily')::int - dc),
    'hourly', gc->'hourly', 'daily', (gc->>'daily')::int,
    'next_at', case when hl <= 0 and (gc->>'daily')::int - dc > 0 then nxt + win end);
end $$;

-- consecutive UTC days (ending today, or yesterday if today is not done yet) on which the daily streak bonus was earned
create function public._game_streak(u uuid) returns int language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'utc')::date; n int := 0;
begin
  if not exists (select 1 from game_days where user_id = u and day = d and bonus_paid) then d := d - 1; end if;
  while n < 1000 and exists (select 1 from game_days where user_id = u and day = d and bonus_paid) loop n := n + 1; d := d - 1; end loop;
  return n;
end $$;

-- called after every completed play: counts it, pays the daily bonus, and the weekly bonus every 7th day in a row
create function public._game_day_bonus(u uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb := cfg('games'); today date := (now() at time zone 'utc')::date; done int; paid boolean; n int; outj jsonb := '{}';
  dc jsonb := g->'daily_streak'; wc jsonb := g->'weekly_streak';
begin
  insert into game_days (user_id, day, completed) values (u, today, 1)
    on conflict (user_id, day) do update set completed = game_days.completed + 1 returning completed, bonus_paid into done, paid;
  if done >= (dc->>'games')::int and not paid then
    perform _grant(u, 'leaf_coins', (dc->>'coins')::int, 'game_daily_streak', 'gdaily:' || today || ':coins');
    perform _grant(u, 'rhizomes', (dc->>'rhizomes')::int, 'game_daily_streak', 'gdaily:' || today || ':rh');
    update game_days set bonus_paid = true where user_id = u and day = today;
    outj := outj || jsonb_build_object('daily_bonus', jsonb_build_object('coins', (dc->>'coins')::int, 'rhizomes', (dc->>'rhizomes')::int));
    n := _game_streak(u);
    if n > 0 and n % (wc->>'days')::int = 0 then
      perform _grant(u, 'leaf_coins', (wc->>'coins')::int, 'game_weekly_streak', 'gweekly:' || today || ':coins');
      perform _grant(u, 'rhizomes', (wc->>'rhizomes')::int, 'game_weekly_streak', 'gweekly:' || today || ':rh');
      perform _grant(u, 'collector_gems', (wc->>'gems')::int, 'game_weekly_streak', 'gweekly:' || today || ':gem');
      outj := outj || jsonb_build_object('weekly_bonus', jsonb_build_object('coins', (wc->>'coins')::int, 'rhizomes', (wc->>'rhizomes')::int, 'gems', (wc->>'gems')::int));
    end if;
  end if;
  return outj || jsonb_build_object('today_completed', done, 'streak_days', _game_streak(u));
end $$;

-- 1. Start one of the three skill games (uses up a play)
create function public.start_game(game text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); st jsonb; gp game_plays;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  if game not in ('leaf_match','rhizome_rush','garden_cleanup') then raise exception 'unknown game'; end if;
  perform 1 from profiles where id = u for update;
  select * into gp from game_plays where id = req_id and user_id = u;
  if found then return jsonb_build_object('play_id', gp.id, 'game', gp.game, 'replay', true); end if;
  st := _game_status(u, game);
  if (st->>'day_left')::int <= 0 then raise exception 'No plays left today'; end if;
  if (st->>'hour_left')::int <= 0 then raise exception 'Hourly limit reached. Come back a little later'; end if;
  insert into game_plays (id, user_id, game) values (req_id, u, game);
  return jsonb_build_object('play_id', req_id, 'game', game, 'session_seconds', (cfg('games')->>'session_minutes')::int * 60);
end $$;

-- 2. Finish it. The browser reports how it went; the server decides the reward.
--    leaf_match: {"misses": n}   rhizome_rush: {"hits": 0..10}   garden_cleanup: nothing (the server times it)
create function public.finish_game(play_id uuid, metrics jsonb default '{}') returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); gp game_plays; g jsonb := cfg('games'); elapsed numeric; tr int; coins int := 0; rh int := 0; perf boolean := false;
  m int; res jsonb; xpv int; n int;
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
    tr := case when m >= 8 then 3 when m >= 5 then 2 else 1 end;
    perf := m = 10;
    coins := case tr when 1 then 15 when 2 then 25 else 40 end;
    rh := case when tr = 3 then 1 else 0 end;
  else   -- garden_cleanup: time is measured by the server
    tr := case when elapsed < 20 then 4 when elapsed < 30 then 3 when elapsed < 45 then 2 else 1 end;
    perf := elapsed < 20;
    coins := case tr when 1 then 20 when 2 then 40 when 3 then 60 else 100 end;
    rh := case when tr = 3 then 1 when tr = 4 and random() < 0.5 then 1 else 0 end;
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

-- 3. Growth Burst Spinner: rolled completely on the server
create function public.spin(req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); st jsonb; gp game_plays; roll numeric := random() * 100; cum numeric := 0; seg int := 5; i int; res jsonb;
  weights numeric[] := array[30, 30, 20, 12, 7, 1];
  coins_t int[] := array[10, 25, 50, 75, 100, 150];
  rh_t int[] := array[0, 0, 0, 1, 2, 3];
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
  perform _grant(u, 'leaf_coins', coins_t[seg + 1], 'game_spinner', 'game:' || req_id || ':coins');
  if rh_t[seg + 1] > 0 then perform _grant(u, 'rhizomes', rh_t[seg + 1], 'game_spinner', 'game:' || req_id || ':rh'); end if;
  perform _add_xp(u, (cfg('xp')->>'game')::int, 'game', 'game:' || req_id);
  res := jsonb_build_object('segment', seg, 'tier', seg + 1, 'coins', coins_t[seg + 1], 'rhizomes', rh_t[seg + 1], 'xp', (cfg('xp')->>'game')::int) || _game_day_bonus(u);
  update game_plays set reward = res where id = req_id;
  return res;
end $$;

-- 4. Everything the Mini-Games screen needs
create function public.get_games_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g jsonb := cfg('games'); today date := (now() at time zone 'utc')::date; gd game_days; n int;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into gd from game_days where user_id = u and day = today;
  n := _game_streak(u);
  return jsonb_build_object(
    'games', jsonb_build_object('leaf_match', _game_status(u, 'leaf_match'), 'rhizome_rush', _game_status(u, 'rhizome_rush'),
                                'garden_cleanup', _game_status(u, 'garden_cleanup'), 'spinner', _game_status(u, 'spinner')),
    'today', jsonb_build_object('completed', coalesce(gd.completed, 0), 'needed', (g->'daily_streak'->>'games')::int, 'bonus_paid', coalesce(gd.bonus_paid, false),
                                'bonus', g->'daily_streak'),
    'streak', jsonb_build_object('days', n, 'week_days', (g->'weekly_streak'->>'days')::int, 'weekly', g->'weekly_streak'),
    'rush', jsonb_build_object('perfects', coalesce((select rush_perfects from game_progress where user_id = u), 0), 'needed', (g->>'rush_perfects_needed')::int, 'bonus', g->'rush_bonus'));
end $$;

revoke execute on function public._game_status(uuid,text), public._game_streak(uuid), public._game_day_bonus(uuid) from public, anon, authenticated;
revoke execute on function public.start_game(text,uuid), public.finish_game(uuid,jsonb), public.spin(uuid), public.get_games_state() from public, anon;
grant execute on function public.start_game(text,uuid), public.finish_game(uuid,jsonb), public.spin(uuid), public.get_games_state() to authenticated;
notify pgrst, 'reload schema';
