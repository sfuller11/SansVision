-- INCREMENT 4: public gardens (Realm), plus 8 new plants. Run once in Supabase (SQL Editor) after migration_005.

-- 1. New plants (rarities as you gave them)
insert into public.plant_catalog (id, name, rarity, asset_key, description, max_stage, growth_scale, tall, active) values
 ('sunnystar','Hahnii Sunny Star','common','sunnystar','Small silver-banded hahnii rosette with yellow edges.',5,1,false,true),
 ('marsha','Marsha','uncommon','marsha','Dark green pointed rosette with fine speckles.',5,1,false,true),
 ('bhitalii','Bhitalii Silver Blue','uncommon','bhitalii','Round silvery-blue leaves with bumpy edges.',5,1,false,true),
 ('gabriella','Gabriella White Variegated','rare','gabriella','Stacked white and cream variegated rosette.',5,1,false,true),
 ('assalam','Trifasciata Assalam','rare','assalam','Slender upright leaves with yellow edges.',5,1,false,true),
 ('bantels','Trifasciata Bantel''s Sensation','rare','bantels','Tall narrow leaves with white streaks.',5,1,false,true),
 ('nelsonii','Trifasciata Banded Nelsonii','rare','nelsonii','A large grower with pale banding.',20,2,true,true),
 ('kismayo','Kismayo Variegated','rare','kismayo','Tight pointed rosette with wavy edges.',5,1,false,true);

-- 2. Gardens. The layout is the 4 rooms x 3 spots already stored in plants.spot.
create table public.gardens (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null,
  description text not null default '',
  is_public boolean not null default false,
  first_published_at timestamptz,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index gardens_public_idx on public.gardens (published_at desc, id desc) where is_public;
create table public.garden_visits (
  visitor_id uuid not null references auth.users(id) on delete cascade,
  garden_id uuid not null references public.gardens(id) on delete cascade,
  first_visit_at timestamptz not null default now(),
  primary key (visitor_id, garden_id)
);
alter table public.gardens enable row level security;
alter table public.garden_visits enable row level security;
create policy "owner reads own garden" on public.gardens for select using (auth.uid() = owner_id);
create policy "visitor reads own visits" on public.garden_visits for select using (auth.uid() = visitor_id);
revoke insert, update, delete on public.gardens, public.garden_visits from authenticated, anon;
-- Other players' gardens are reachable only through the functions below, which return public fields only.

insert into public.gardens (owner_id, name) select id, display_name || '''s Garden' from public.profiles on conflict (owner_id) do nothing;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare dn text := 'Gardener-' || substr(replace(new.id::text,'-',''),1,8);
begin
  insert into profiles (id, display_name) values (new.id, dn) on conflict (id) do nothing;
  insert into gardens (owner_id, name) values (new.id, dn || '''s Garden') on conflict (owner_id) do nothing;
  perform _grant(new.id, 'leaf_coins', (cfg('economy')->>'starting_coins')::int, 'starting_grant', 'starting_grant');
  return new;
end $$;

-- plants now report whether they may be shown to visitors
create or replace function public._plant_json(p public.plants) returns jsonb language sql stable as $$
  select jsonb_build_object('id',p.id,'type',p.type,'name',p.name,'stage',p.stage,'spot',p.spot,'moisture',p.moisture,
    'public_display',p.public_display,'cultivar',c.name,'rarity',c.rarity,'max_stage',c.max_stage,'tall',c.tall,
    'progress',least(1, p.growth_hours / _total_hours(c.growth_scale)))
  from plant_catalog c where c.id = p.type $$;

-- 3. Helpers
create function public._ensure_garden(u uuid) returns public.gardens language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  insert into gardens (owner_id, name) select u, display_name || '''s Garden' from profiles where id = u on conflict (owner_id) do nothing;
  select * into g from gardens where owner_id = u;
  return g;
end $$;

create function public._care_label(p public.plants) returns text language sql stable as $$
  select case when m >= 70 then 'Hydrated' when m >= 35 then 'Healthy' when m >= 10 then 'Thirsty' else 'Very dry' end
  from (select greatest(0, p.moisture - (cfg('growth')->>'moisture_loss_per_hour')::numeric * extract(epoch from now() - p.moisture_at) / 3600.0) m) x $$;

-- 4. Owner functions
create function public.get_my_garden() returns jsonb language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  g := _ensure_garden(auth.uid());
  return jsonb_build_object('id',g.id,'name',g.name,'description',g.description,'is_public',g.is_public,'first_published_at',g.first_published_at);
end $$;

create function public.update_garden(new_name text, new_description text) returns jsonb language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  new_name := btrim(coalesce(new_name,'')); new_description := btrim(coalesce(new_description,''));
  if char_length(new_name) < 3 or char_length(new_name) > 40 then raise exception 'Garden name must be 3 to 40 characters'; end if;
  if char_length(new_description) > 200 then raise exception 'Description can be at most 200 characters'; end if;
  perform _ensure_garden(auth.uid());
  update gardens set name = new_name, description = new_description, updated_at = now() where owner_id = auth.uid() returning * into g;
  return jsonb_build_object('id',g.id,'name',g.name,'description',g.description,'is_public',g.is_public);
end $$;

create function public.set_garden_public(make_public boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  perform _ensure_garden(auth.uid());
  update gardens set is_public = make_public, updated_at = now(),
         published_at = case when make_public and not is_public then now() else published_at end,
         first_published_at = case when make_public then coalesce(first_published_at, now()) else first_published_at end
   where owner_id = auth.uid() returning * into g;
  return jsonb_build_object('id',g.id,'is_public',g.is_public);
end $$;

create function public.set_plant_display(pid uuid, show boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from plants where id = pid and user_id = auth.uid()) then raise exception 'not your plant'; end if;
  update plants set public_display = show where id = pid;
end $$;

-- 5. Visitor functions (read-only; only fields meant for the public)
create function public.list_public_gardens(cursor_ts timestamptz default null, cursor_id uuid default null, page_size int default 12)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ps int := least(greatest(coalesce(page_size, 12), 1), 24); items jsonb; more boolean; last_item jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.published_at desc, r.id desc), '[]'::jsonb) into items from (
    select g.id, g.name, g.published_at, pr.display_name as owner_name,
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

create function public.random_public_garden() returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select g.id into gid from gardens g where g.is_public and g.owner_id <> auth.uid()
    and exists (select 1 from plants pl where pl.user_id = g.owner_id and pl.spot is not null and pl.public_display)
    order by random() limit 1;
  if gid is null then raise exception 'No public gardens to visit yet'; end if;
  return gid;
end $$;

create function public.visit_garden(gid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g gardens;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into g from gardens where id = gid and (is_public or owner_id = u);
  if not found then raise exception 'Garden not found'; end if;      -- same answer for private and missing gardens
  if g.owner_id <> u then insert into garden_visits (visitor_id, garden_id) values (u, g.id) on conflict do nothing; end if;
  return jsonb_build_object('id', g.id, 'name', g.name, 'description', g.description, 'is_mine', g.owner_id = u,
    'owner_name', (select display_name from profiles where id = g.owner_id),
    'plants', (select coalesce(jsonb_agg(jsonb_build_object('spot', p.spot, 'type', p.type, 'name', p.name, 'cultivar', c.name,
        'rarity', c.rarity, 'stage', p.stage, 'max_stage', c.max_stage, 'tall', c.tall, 'care', _care_label(p),
        'moisture', round(greatest(0, p.moisture - (cfg('growth')->>'moisture_loss_per_hour')::numeric * extract(epoch from now() - p.moisture_at) / 3600.0))) order by p.spot), '[]'::jsonb)
      from plants p join plant_catalog c on c.id = p.type where p.user_id = g.owner_id and p.spot is not null and p.public_display),
    'collector', jsonb_build_object('unique_plants', (select count(*) from plants where user_id = g.owner_id),
      'achievements', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'icon', a.icon) order by a.sort), '[]'::jsonb)
        from player_achievements pa join achievements a on a.id = pa.achievement_id where pa.user_id = g.owner_id and pa.claimed_at is not null)));
end $$;

-- 6. Switch on the three garden achievements (progress is counted from real visits and publishing)
create or replace function public._achievement_progress(u uuid, a public.achievements) returns int language sql stable set search_path = public as $$
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
    when 'gardens_visited' then (select count(*)::int from garden_visits where visitor_id = u)
    when 'garden_published' then (select count(*)::int from gardens where owner_id = u and first_published_at is not null)
    when 'first_visitor' then (select least(1, count(*))::int from garden_visits v join gardens g on g.id = v.garden_id where g.owner_id = u and v.visitor_id <> u)
    else 0 end $$;
update public.achievements set active = true where id in ('realm_explorer','garden_host','first_visitor');

-- 7. Permissions
revoke execute on function public._ensure_garden(uuid), public._care_label(public.plants) from public, anon, authenticated;
revoke execute on function public.get_my_garden(), public.update_garden(text,text), public.set_garden_public(boolean), public.set_plant_display(uuid,boolean),
  public.list_public_gardens(timestamptz,uuid,int), public.random_public_garden(), public.visit_garden(uuid) from public, anon;
grant execute on function public.get_my_garden(), public.update_garden(text,text), public.set_garden_public(boolean), public.set_plant_display(uuid,boolean),
  public.list_public_gardens(timestamptz,uuid,int), public.random_public_garden(), public.visit_garden(uuid) to authenticated;
notify pgrst, 'reload schema';
