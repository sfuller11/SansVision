-- MIGRATION 10: Odd Plant Out replaces Garden Cleanup, Rhizome Rush gets harder, profile pictures, Collection screen, profile summary.
-- Run ONCE in Supabase (SQL Editor) after migration_009.

-- 1. Odd Plant Out replaces Garden Cleanup (old plays are renamed, rewards already paid stay paid)
alter table public.game_plays drop constraint if exists game_plays_game_check;
update public.game_plays set game = 'odd_plant_out' where game = 'garden_cleanup';
alter table public.game_plays add constraint game_plays_game_check check (game in ('leaf_match','rhizome_rush','odd_plant_out','spinner'));
update public.game_config set value = (value - 'garden_cleanup') ||
  '{"odd_plant_out":{"hourly":2,"daily":10,"min_seconds":8,"penalty_seconds":2,"tier_seconds":[25,35,50]}}'::jsonb
 where key = 'games';
-- Prizes: under 25s = 100 coins (+1 rhizome 50%), under 35s = 60 + 1 rhizome, under 50s = 40, slower = 20.
-- Time is the server's clock plus 2 seconds for each wrong tap the browser reports (at most 10). Edit tier_seconds in game_config.

-- 2. Profile pictures. The browser uploads one small JPEG per player to a public 'avatars' bucket, in the player's own folder,
--    and then calls set_avatar. File name, type and size are fixed by the rules below.
alter table public.profiles add column if not exists avatar_path text, add column if not exists avatar_v bigint;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 262144, array['image/jpeg'])
  on conflict (id) do update set public = true, file_size_limit = 262144, allowed_mime_types = array['image/jpeg'];
create policy "avatars: read own" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and name = auth.uid()::text || '/avatar.jpg');
create policy "avatars: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name = auth.uid()::text || '/avatar.jpg');
create policy "avatars: replace own" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and name = auth.uid()::text || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = auth.uid()::text || '/avatar.jpg');
create policy "avatars: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and name = auth.uid()::text || '/avatar.jpg');

create function public.set_avatar() returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'avatars' and name = u::text || '/avatar.jpg') then
    raise exception 'Upload a picture first';
  end if;
  update profiles set avatar_path = u::text || '/avatar.jpg', avatar_v = (extract(epoch from clock_timestamp()) * 1000)::bigint where id = u;
end $$;

create function public.remove_avatar() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update profiles set avatar_path = null, avatar_v = null where id = auth.uid();
end $$;

-- 3. Collection
alter table public.plants add column if not exists collection_seen boolean not null default false;
update public.plants set collection_seen = true;          -- only plants you get from now on show a "New" dot

create function public.get_collection() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); d jsonb := cfg('discovery'); rar text[] := array['common','uncommon','rare','epic','legendary'];
begin
  if u is null then raise exception 'not signed in'; end if;
  return jsonb_build_object('rarities', to_jsonb(rar), 'plants', coalesce((
    select jsonb_agg(case when p.id is not null then
        jsonb_build_object('id', c.id, 'rarity', c.rarity, 'owned', true, 'name', c.name, 'description', c.description, 'plant_name', p.name,
          'stage', p.stage, 'max_stage', c.max_stage, 'tall', c.tall, 'full_growth', p.stage = c.max_stage, 'acquired_at', p.created_at,
          'source', p.acquired_source, 'is_new', not p.collection_seen)
      else
        jsonb_build_object('id', c.id, 'rarity', c.rarity, 'owned', false, 'max_stage', c.max_stage, 'tall', c.tall,
          'unlock_cost', (d->'targeted_costs'->>c.rarity)::int,
          'chances', (select coalesce(jsonb_object_agg(k, jsonb_build_object('name', v->>'name',
                'pct', round((v->'odds'->>c.rarity)::numeric / (select count(*) from plant_catalog x where x.active and x.rarity = c.rarity), 1))), '{}'::jsonb)
              from jsonb_each(d->'tiers') t(k, v) where (v->'odds'->>c.rarity)::numeric > 0))
      end order by array_position(rar, c.rarity), c.id)
    from plant_catalog c left join plants p on p.type = c.id and p.user_id = u where c.active), '[]'::jsonb));
end $$;

create function public.mark_plant_seen(cid text) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update plants set collection_seen = true where user_id = auth.uid() and type = cid;
end $$;

-- 4. Numbers for the Profile tab
create function public.get_profile_summary() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'plants_owned', (select count(*) from plants where user_id = u),
    'catalog_total', (select count(*) from plant_catalog where active),
    'full_growth', (select count(*) from plants p join plant_catalog c on c.id = p.type where p.user_id = u and p.stage = c.max_stage),
    'games_played', (select count(*) from game_plays where user_id = u and tier > 0),
    'streak_days', _game_streak(u),
    'member_since', (select created_at from auth.users where id = u));
end $$;

-- 5. Updated functions (full replacements; see migration 9 for the originals)
create or replace function public.start_game(game text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); st jsonb; gp game_plays;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  if game not in ('leaf_match','rhizome_rush','odd_plant_out') then raise exception 'unknown game'; end if;
  perform 1 from profiles where id = u for update;
  select * into gp from game_plays where id = req_id and user_id = u;
  if found then return jsonb_build_object('play_id', gp.id, 'game', gp.game, 'replay', true); end if;
  st := _game_status(u, game);
  if (st->>'day_left')::int <= 0 then raise exception 'No plays left today'; end if;
  if (st->>'hour_left')::int <= 0 then raise exception 'Hourly limit reached. Come back a little later'; end if;
  insert into game_plays (id, user_id, game) values (req_id, u, game);
  return jsonb_build_object('play_id', req_id, 'game', game, 'session_seconds', (cfg('games')->>'session_minutes')::int * 60);
end $$;

create or replace function public.finish_game(play_id uuid, metrics jsonb default '{}') returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); gp game_plays; g jsonb := cfg('games'); elapsed numeric; tr int; coins int := 0; rh int := 0; perf boolean := false;
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
  else   -- odd_plant_out: server time plus a penalty for each wrong tap the browser reports (capped at 10)
    m := case when coalesce(metrics->>'misses', '') ~ '^[0-9]{1,3}$' then least(10, (metrics->>'misses')::int) else 10 end;
    adj := elapsed + m * (g->'odd_plant_out'->>'penalty_seconds')::numeric;
    tr := case when adj < (g->'odd_plant_out'->'tier_seconds'->>0)::numeric then 4
               when adj < (g->'odd_plant_out'->'tier_seconds'->>1)::numeric then 3
               when adj < (g->'odd_plant_out'->'tier_seconds'->>2)::numeric then 2 else 1 end;
    perf := tr = 4;
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

create or replace function public.get_games_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g jsonb := cfg('games'); today date := (now() at time zone 'utc')::date; gd game_days; n int;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into gd from game_days where user_id = u and day = today;
  n := _game_streak(u);
  return jsonb_build_object(
    'games', jsonb_build_object('leaf_match', _game_status(u, 'leaf_match'), 'rhizome_rush', _game_status(u, 'rhizome_rush'),
                                'odd_plant_out', _game_status(u, 'odd_plant_out'), 'spinner', _game_status(u, 'spinner')),
    'today', jsonb_build_object('completed', coalesce(gd.completed, 0), 'needed', (g->'daily_streak'->>'games')::int, 'bonus_paid', coalesce(gd.bonus_paid, false),
                                'bonus', g->'daily_streak'),
    'streak', jsonb_build_object('days', n, 'week_days', (g->'weekly_streak'->>'days')::int, 'weekly', g->'weekly_streak'),
    'rush', jsonb_build_object('perfects', coalesce((select rush_perfects from game_progress where user_id = u), 0), 'needed', (g->>'rush_perfects_needed')::int, 'bonus', g->'rush_bonus'));
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
    'owner_avatar', (select avatar_path from profiles where id = g.owner_id), 'owner_avatar_v', (select avatar_v from profiles where id = g.owner_id),
    'plants', (select coalesce(jsonb_agg(jsonb_build_object('spot', p.spot, 'type', p.type, 'name', p.name, 'cultivar', c.name,
        'rarity', c.rarity, 'stage', p.stage, 'max_stage', c.max_stage, 'tall', c.tall, 'care', _care_label(p),
        'moisture', round(greatest(0, p.moisture - (cfg('growth')->>'moisture_loss_per_hour')::numeric * extract(epoch from now() - p.moisture_at) / 3600.0))) order by p.spot), '[]'::jsonb)
      from plants p join plant_catalog c on c.id = p.type where p.user_id = g.owner_id and p.spot is not null and p.public_display),
    'collector', jsonb_build_object('unique_plants', (select count(*) from plants where user_id = g.owner_id),
      'achievements', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'icon', a.icon) order by a.sort), '[]'::jsonb)
        from player_achievements pa join achievements a on a.id = pa.achievement_id where pa.user_id = g.owner_id and pa.claimed_at is not null)));
end $$;

create or replace function public.list_public_gardens(cursor_ts timestamptz default null, cursor_id uuid default null, page_size int default 12)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ps int := least(greatest(coalesce(page_size, 12), 1), 24); items jsonb; more boolean; last_item jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.published_at desc, r.id desc), '[]'::jsonb) into items from (
    select g.id, g.name, g.published_at, pr.display_name as owner_name, pr.avatar_path as owner_avatar, pr.avatar_v as owner_avatar_v,
      (select count(distinct pl.type) from plants pl where pl.user_id = g.owner_id and pl.spot is not null and pl.public_display) as cultivars,
      (select count(*) from player_achievements pa where pa.user_id = g.owner_id and pa.claimed_at is not null) as achievements,
      (select coalesce(jsonb_agg(jsonb_build_object('type', x.type, 'stage', x.stage)), '[]'::jsonb)
         from (select pl.type, pl.stage from plants pl where pl.user_id = g.owner_id and pl.spot is not null and pl.public_display
               order by pl.stage desc, pl.type limit 4) x) as preview
    from gardens g join profiles pr on pr.id = g.owner_id
    where g.is_public
      and exists (select 1 from plants pl where pl.user_id = g.owner_id and pl.spot is not null and pl.public_display)
      and (cursor_ts is null or (g.published_at, g.id) < (cursor_ts, cursor_id))
    order by g.published_at desc, g.id desc limit ps + 1) r;
  more := jsonb_array_length(items) > ps;
  if more then
    last_item := items -> (ps - 1);
    items := (select jsonb_agg(e order by o) from jsonb_array_elements(items) with ordinality t(e, o) where o <= ps);
  end if;
  return jsonb_build_object('gardens', items,
    'next_cursor', case when more then jsonb_build_object('ts', last_item->>'published_at', 'id', last_item->>'id') end);
end $$;

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
                  'avatar_path',avatar_path,'avatar_v',avatar_v,'level',level,'xp',xp,'xp_needed',(lv->>'xp_per_level')::int * level) from profiles where id = u),
    'new_plants', (select count(*) from plants where user_id = u and not collection_seen),
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

-- 6. Permissions
revoke execute on function public.set_avatar(), public.remove_avatar(), public.get_collection(), public.mark_plant_seen(text),
  public.get_profile_summary() from public, anon;
grant execute on function public.set_avatar(), public.remove_avatar(), public.get_collection(), public.mark_plant_seen(text),
  public.get_profile_summary() to authenticated;
notify pgrst, 'reload schema';
