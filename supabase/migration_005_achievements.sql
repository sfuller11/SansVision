-- INCREMENT 3: achievements. Run once in Supabase (SQL Editor) after migration_004.

create table public.achievements (
  id text primary key,
  name text not null,
  description text not null,
  icon text not null default '🏆',
  kind text not null,                 -- what is counted (see _achievement_progress)
  param text,                         -- extra setting for the kind, e.g. a rarity
  target int not null check (target > 0),
  rewards jsonb not null default '{}',-- e.g. {"leaf_coins":100,"collector_gems":1}
  active boolean not null default true,
  sort int not null default 0
);
create table public.player_achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  achievement_id text not null references public.achievements(id),
  progress int not null default 0,
  completed_at timestamptz,
  claimed_at timestamptz,
  primary key (user_id, achievement_id)
);
alter table public.achievements enable row level security;
alter table public.player_achievements enable row level security;
create policy "read achievements" on public.achievements for select to authenticated using (true);
create policy "read own achievements" on public.player_achievements for select using (auth.uid() = user_id);
revoke insert, update, delete on public.achievements, public.player_achievements from authenticated, anon;

-- The three garden achievements stay inactive until the gardens increment adds what they count.
insert into public.achievements (id, name, description, icon, kind, param, target, rewards, active, sort) values
 ('first_discovery','First Discovery','Discover your first plant.','🌱','plants_owned',null,1,'{"leaf_coins":50}',true,1),
 ('first_growth','First Growth','Grow a plant past its first stage.','🌿','phase_at_least','2',1,'{"leaf_coins":50}',true,2),
 ('green_thumb','Green Thumb','Grow five plants to their final stage.','👍','final_stage_plants',null,5,'{"leaf_coins":100}',true,3),
 ('growing_collection','Growing Collection','Discover five unique cultivars.','📚','plants_owned',null,5,'{"leaf_coins":50}',true,4),
 ('dedicated_collector','Dedicated Collector','Discover 15 unique cultivars.','🧺','plants_owned',null,15,'{"leaf_coins":100,"collector_gems":1}',true,5),
 ('rare_find','Rare Find','Discover a Rare plant or better.','💙','rarity_min','rare',1,'{"collector_gems":1}',true,6),
 ('epic_discovery','Epic Discovery','Discover an Epic plant.','💜','rarity_exact','epic',1,'{"collector_gems":2}',true,7),
 ('legendary_discovery','Legendary Discovery','Discover a Legendary plant.','🌟','rarity_exact','legendary',1,'{"collector_gems":3}',true,8),
 ('botanical_library','Botanical Library','Discover 25 unique cultivars.','🏛️','plants_owned',null,25,'{"leaf_coins":150,"collector_gems":2}',true,9),
 ('realm_explorer','Realm Explorer','Visit five different public gardens.','🧭','gardens_visited',null,5,'{"leaf_coins":50}',false,10),
 ('garden_host','Garden Host','Publish your garden for the first time.','🏡','garden_published',null,1,'{"leaf_coins":50}',false,11),
 ('first_visitor','First Visitor','Receive your first visit from another player.','👋','first_visitor',null,1,'{"leaf_coins":50}',false,12);

-- Progress is always worked out from real game state, never supplied by the browser.
create function public._achievement_progress(u uuid, a public.achievements) returns int language sql stable set search_path = public as $$
  select case a.kind
    when 'plants_owned' then (select count(*)::int from plants where user_id = u and acquired_source <> 'admin')
    when 'phase_at_least' then (select count(*)::int from plants p join plant_catalog c on c.id = p.type
        where p.user_id = u and floor((p.stage - 1)::numeric / c.max_stage * 5) + 1 >= a.param::int)
    when 'final_stage_plants' then (select count(*)::int from plants p join plant_catalog c on c.id = p.type
        where p.user_id = u and p.stage = c.max_stage)
    when 'rarity_min' then (select count(*)::int from plants p join plant_catalog c on c.id = p.type
        where p.user_id = u and p.acquired_source <> 'admin'
        and array_position(array['common','uncommon','rare','epic','legendary'], c.rarity) >= array_position(array['common','uncommon','rare','epic','legendary'], a.param))
    when 'rarity_exact' then (select count(*)::int from plants p join plant_catalog c on c.id = p.type
        where p.user_id = u and p.acquired_source <> 'admin' and c.rarity = a.param)
    else 0 end $$;

create function public._evaluate_achievements(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare a achievements; pr int; n int := (select count(*) from plant_catalog where active);
begin
  for a in select * from achievements where active loop
    if a.kind = 'plants_owned' and a.target > n then continue; end if;      -- not earnable until the catalog is big enough
    pr := least(a.target, _achievement_progress(u, a));
    insert into player_achievements (user_id, achievement_id, progress, completed_at)
      values (u, a.id, pr, case when pr >= a.target then now() end)
      on conflict (user_id, achievement_id) do update
        set progress = greatest(player_achievements.progress, excluded.progress),            -- progress never goes backwards
            completed_at = coalesce(player_achievements.completed_at, excluded.completed_at); -- completed only once
  end loop;
end $$;

create function public.get_achievements() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); n int := (select count(*) from plant_catalog where active);
begin
  if u is null then raise exception 'not signed in'; end if;
  perform _evaluate_achievements(u);
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'description',a.description,'icon',a.icon,
      'target',a.target,'rewards',a.rewards,'progress',coalesce(pa.progress,0),
      'state', case when pa.claimed_at is not null then 'claimed'
                    when pa.completed_at is not null then 'ready'
                    when not a.active then 'coming_soon'
                    when a.kind = 'plants_owned' and a.target > n then 'needs_plants'
                    else 'in_progress' end) order by a.sort)
    from achievements a left join player_achievements pa on pa.achievement_id = a.id and pa.user_id = u), '[]'::jsonb);
end $$;

create function public.claim_achievement(aid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); a achievements; pa player_achievements; k text; amt int; got jsonb := '{}';
begin
  if u is null then raise exception 'not signed in'; end if;
  perform 1 from profiles where id = u for update;
  select * into a from achievements where id = aid and active;
  if not found then raise exception 'unknown achievement'; end if;
  perform _evaluate_achievements(u);
  select * into pa from player_achievements where user_id = u and achievement_id = aid for update;
  if not found or pa.completed_at is null then raise exception 'Achievement not completed yet'; end if;
  if pa.claimed_at is not null then return jsonb_build_object('claimed', false, 'already_claimed', true); end if;
  for k, amt in select key, value::int from jsonb_each_text(a.rewards) loop
    perform _grant(u, k, amt, 'achievement', 'achievement:' || aid || ':' || k);   -- the ledger refuses a second payout
    got := got || jsonb_build_object(k, amt);
  end loop;
  update player_achievements set claimed_at = now() where user_id = u and achievement_id = aid;
  return jsonb_build_object('claimed', true, 'name', a.name, 'rewards', got);
end $$;

-- the main state call now also reports how many rewards are waiting
create or replace function public.get_game_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pid uuid; today date := (now() at time zone 'utc')::date;
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
    'plants', (select coalesce(jsonb_agg(_plant_json(p) order by p.created_at), '[]'::jsonb) from plants p where p.user_id = u),
    'catalog', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'rarity',rarity) order by name), '[]'::jsonb) from plant_catalog where active));
end $$;

revoke execute on function public._achievement_progress(uuid, public.achievements), public._evaluate_achievements(uuid) from public, anon, authenticated;
revoke execute on function public.get_achievements(), public.claim_achievement(text) from public, anon;
grant execute on function public.get_achievements(), public.claim_achievement(text) to authenticated;
