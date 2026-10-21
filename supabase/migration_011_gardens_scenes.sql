-- MIGRATION 11: several gardens per player (each a scene with named spots), new plants, garden likes, Realm sorting.
-- Run once in Supabase (SQL Editor) after migration_010.
--
-- What changes for existing players:
--   * Their one garden becomes a Greenhouse. Plants that were placed in rooms move onto Greenhouse spots (first 10, oldest first); any extra go back to "not placed".
--   * Paid garden backgrounds from migration 7 are refunded in full (once), because the four-room house is gone.

-- 1. New plants
insert into public.plant_catalog (id, name, rarity, asset_key, description, max_stage, growth_scale, tall, active) values
 ('goldenflame','Golden Flame','common','goldenflame','Dark green rosette with bright yellow margins and tips.',5,1,false,true),
 ('hallibat','Halli Bat','common','hallibat','Green bat-leaf rosette with faint soft banding.',5,1,false,true),
 ('masoniana','Masoniana','common','masoniana','One broad, mottled paddle leaf, with smaller leaves joining it as it grows.',5,1,false,true),
 ('silverbat','Silver Bat','uncommon','silverbat','Light silvery-blue bat leaves with soft banding.',5,1,false,true),
 ('bluebat','Blue Bat','rare','bluebat','Deep blue bat leaves with soft banding.',5,1,false,true),
 ('kirkiicoral','Kirkii Coral Blue Variegated','legendary','kirkiicoral','Upright wavy blue-green leaves with golden striations and a copper edge.',5,1,false,true),
 ('bhitaliivar','Bhitalli Silver Blue Variegated','legendary','bhitaliivar','Broad wavy silver-blue leaves with gold, white and dark striations and a copper edge.',5,1,false,true)
on conflict (id) do nothing;

-- 2. Garden types (scenes) and their spots. Skins share a layout. Pictures live in /public/gardens/<id>.png
create table public.garden_types (
  id text primary key, name text not null, description text not null default '', layout text not null,
  currency text not null check (currency in ('leaf_coins','collector_gems')),
  cost int not null default 0 check (cost >= 0), sort int not null default 0, active boolean not null default true
);
create table public.garden_spots (
  layout text not null, spot_id text not null, size text not null check (size in ('S','M','L')), sort int not null default 0,
  primary key (layout, spot_id)
);
insert into public.garden_types (id, name, description, layout, currency, cost, sort) values
 ('greenhouse','Greenhouse','Glass walls, a wall shelf and a long bench. Your starter garden.','greenhouse','leaf_coins',0,1),
 ('balcony','Balcony','A small sunny balcony with hanging baskets and crates. Few spots, so every plant counts.','balcony','leaf_coins',250,2),
 ('greenhouse_night','Night Greenhouse','The greenhouse after dark, under string lights and a crescent moon.','greenhouse','leaf_coins',300,3),
 ('backyard','Backyard','A lawn with a raised bed, potting bench, stump and wheelbarrow.','backyard','leaf_coins',500,4),
 ('autumn_backyard','Autumn Backyard','The backyard in fall colours with drifting leaves.','backyard','collector_gems',6,5),
 ('rocks','Rock Garden','Boulders, ledges and gravel for a rugged display.','rocks','leaf_coins',900,6),
 ('desert_canyon','Desert Canyon','The rock garden under a red canyon sky with cacti.','rocks','collector_gems',8,7),
 ('zen_courtyard','Zen Courtyard','A stone wall, terraces, a lantern and a pond with stepping stones.','courtyard','collector_gems',12,8);
insert into public.garden_spots (layout, spot_id, size, sort) values
 ('greenhouse','shelf1','S',1),
 ('greenhouse','shelf2','S',2),
 ('greenhouse','shelf3','S',3),
 ('greenhouse','shelf4','S',4),
 ('greenhouse','bench1','M',5),
 ('greenhouse','bench2','M',6),
 ('greenhouse','bench3','M',7),
 ('greenhouse','floor1','L',8),
 ('greenhouse','floor2','L',9),
 ('greenhouse','floor3','L',10),
 ('backyard','bench1','S',1),
 ('backyard','bench2','S',2),
 ('backyard','bed1','M',3),
 ('backyard','bed2','M',4),
 ('backyard','bed3','M',5),
 ('backyard','barrow','M',6),
 ('backyard','stump','M',7),
 ('backyard','ground1','L',8),
 ('backyard','ground2','L',9),
 ('backyard','ground3','L',10),
 ('balcony','rail1','S',1),
 ('balcony','rail2','S',2),
 ('balcony','hang1','S',3),
 ('balcony','hang2','S',4),
 ('balcony','crate1','M',5),
 ('balcony','crate2','M',6),
 ('balcony','floor','L',7),
 ('rocks','ledge1','S',1),
 ('rocks','ledge2','S',2),
 ('rocks','boulder1','M',3),
 ('rocks','boulder2','M',4),
 ('rocks','boulder3','M',5),
 ('rocks','gravel1','M',6),
 ('rocks','gravel2','M',7),
 ('rocks','front1','L',8),
 ('rocks','front2','L',9),
 ('rocks','front3','L',10),
 ('courtyard','wall1','S',1),
 ('courtyard','wall2','S',2),
 ('courtyard','wall3','S',3),
 ('courtyard','left1','M',4),
 ('courtyard','left2','M',5),
 ('courtyard','right1','M',6),
 ('courtyard','right2','M',7),
 ('courtyard','stone1','S',8),
 ('courtyard','stone2','S',9),
 ('courtyard','stone3','S',10),
 ('courtyard','front1','L',11),
 ('courtyard','front2','L',12);
alter table public.garden_types enable row level security;
alter table public.garden_spots enable row level security;
create policy "read garden types" on public.garden_types for select to authenticated using (true);
create policy "read garden spots" on public.garden_spots for select to authenticated using (true);
revoke insert, update, delete on public.garden_types, public.garden_spots from authenticated, anon;

-- 3. Gardens: several per player (one per type), with a like counter
alter table public.gardens drop constraint if exists gardens_owner_id_key;
alter table public.gardens add column garden_type text not null default 'greenhouse' references public.garden_types(id);
alter table public.gardens add column like_count int not null default 0 check (like_count >= 0);
create unique index gardens_one_type_per_owner on public.gardens (owner_id, garden_type);
create index gardens_owner_idx on public.gardens (owner_id);
create index gardens_likes_idx on public.gardens (like_count desc, published_at desc) where is_public;

create table public.garden_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  garden_id uuid not null references public.gardens(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, garden_id)
);
create index garden_likes_garden_idx on public.garden_likes (garden_id);
alter table public.garden_likes enable row level security;
create policy "read own likes" on public.garden_likes for select using (auth.uid() = user_id);
revoke insert, update, delete on public.garden_likes from authenticated, anon;

-- 4. Plants now say which garden they stand in
alter table public.plants add column garden_id uuid references public.gardens(id) on delete set null;
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.plants'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%spot%' loop
    execute format('alter table public.plants drop constraint %I', c.conname);
  end loop;
end $$;
drop index if exists public.plants_one_per_spot;
-- move old room spots onto the owner's Greenhouse (first 10, oldest first)
with ranked as (
  select p.id, g.id as gid, row_number() over (partition by p.user_id order by p.created_at, p.id) as rn
  from plants p join gardens g on g.owner_id = p.user_id and g.garden_type = 'greenhouse' where p.spot is not null
), spots as (select spot_id, row_number() over (order by sort) as rn from garden_spots where layout = 'greenhouse')
update plants p set garden_id = case when s.spot_id is not null then r.gid end, spot = s.spot_id
from ranked r left join spots s on s.rn = r.rn where p.id = r.id;
create unique index plants_one_per_garden_spot on public.plants (garden_id, spot) where spot is not null;

-- 5. Refund paid backgrounds from the old four-room house (once)
do $$ declare r record; begin
  for r in select u.user_id, t.id, t.currency, t.cost from garden_theme_unlocks u join garden_themes t on t.id = u.theme_id where t.cost > 0 loop
    perform _grant(r.user_id, r.currency, r.cost, 'theme_refund', 'theme_refund:' || r.id);
  end loop;
end $$;
drop function if exists public.list_garden_themes();
drop function if exists public.unlock_garden_theme(text);
drop function if exists public.set_garden_theme(text);
drop function if exists public.get_my_garden();
drop function if exists public.update_garden(text, text);
drop function if exists public.set_garden_public(boolean);
drop function if exists public.place_plant(uuid, text);
drop function if exists public.list_public_gardens(timestamptz, uuid, int);

-- 6. New players get a Greenhouse; helper returns it
create or replace function public._ensure_garden(u uuid) returns public.gardens language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  insert into gardens (owner_id, name, garden_type) select u, left(display_name || '''s Greenhouse', 40), 'greenhouse' from profiles where id = u
    on conflict (owner_id, garden_type) do nothing;
  select * into g from gardens where owner_id = u and garden_type = 'greenhouse';
  return g;
end $$;
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare dn text := 'Gardener-' || substr(replace(new.id::text,'-',''),1,8);
begin
  insert into profiles (id, display_name) values (new.id, dn) on conflict (id) do nothing;
  insert into gardens (owner_id, name, garden_type) values (new.id, dn || '''s Greenhouse', 'greenhouse') on conflict (owner_id, garden_type) do nothing;
  perform _grant(new.id, 'leaf_coins', (cfg('economy')->>'starting_coins')::int, 'starting_grant', 'starting_grant');
  return new;
end $$;

-- 7. Plants report their garden
create or replace function public._plant_json(p public.plants) returns jsonb language sql stable as $$
  select jsonb_build_object('id',p.id,'type',p.type,'name',p.name,'stage',p.stage,'spot',p.spot,'garden_id',p.garden_id,'moisture',p.moisture,
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

-- 8. Owner functions
create function public.get_my_gardens() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'not signed in'; end if;
  perform _ensure_garden(u);
  return jsonb_build_object(
    'gardens', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'description', g.description, 'is_public', g.is_public,
        'garden_type', g.garden_type, 'type_name', t.name, 'layout', t.layout, 'like_count', g.like_count,
        'spots', (select count(*) from garden_spots s where s.layout = t.layout),
        'placed', (select count(*) from plants p where p.garden_id = g.id and p.spot is not null)) order by t.sort), '[]'::jsonb)
      from gardens g join garden_types t on t.id = g.garden_type where g.owner_id = u),
    'types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'description', t.description, 'layout', t.layout,
        'currency', t.currency, 'cost', t.cost, 'owned', exists (select 1 from gardens g where g.owner_id = u and g.garden_type = t.id),
        'spots', (select count(*) from garden_spots s where s.layout = t.layout)) order by t.sort), '[]'::jsonb)
      from garden_types t where t.active));
end $$;

create function public.update_garden(gid uuid, new_name text, new_description text) returns jsonb language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  new_name := btrim(coalesce(new_name,'')); new_description := btrim(coalesce(new_description,''));
  if char_length(new_name) < 3 or char_length(new_name) > 40 then raise exception 'Garden name must be 3 to 40 characters'; end if;
  if char_length(new_description) > 200 then raise exception 'Description can be at most 200 characters'; end if;
  update gardens set name = new_name, description = new_description, updated_at = now() where id = gid and owner_id = auth.uid() returning * into g;
  if not found then raise exception 'not your garden'; end if;
  return jsonb_build_object('id',g.id,'name',g.name,'description',g.description,'is_public',g.is_public);
end $$;

create function public.set_garden_public(gid uuid, make_public boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare g gardens;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update gardens set is_public = make_public, updated_at = now(),
         published_at = case when make_public and not is_public then now() else published_at end,
         first_published_at = case when make_public then coalesce(first_published_at, now()) else first_published_at end
   where id = gid and owner_id = auth.uid() returning * into g;
  if not found then raise exception 'not your garden'; end if;
  return jsonb_build_object('id',g.id,'is_public',g.is_public);
end $$;

create function public.buy_garden(type_id text, req_id uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t garden_types; bal int; gid uuid; dn text;
begin
  if u is null then raise exception 'not signed in'; end if;
  if req_id is null then raise exception 'missing request id'; end if;
  perform 1 from profiles where id = u for update;
  select * into t from garden_types where id = type_id and active;
  if not found then raise exception 'Unknown garden'; end if;
  if exists (select 1 from gardens where owner_id = u and garden_type = t.id) then raise exception 'You already own this garden'; end if;
  execute format('select %I from profiles where id = $1', t.currency) into bal using u;
  if bal < t.cost then raise exception 'Not enough %', replace(t.currency, '_', ' '); end if;
  perform _grant(u, t.currency, -t.cost, 'garden_buy', 'garden:' || t.id);
  select display_name into dn from profiles where id = u;
  insert into gardens (owner_id, name, garden_type) values (u, left(dn || '''s ' || t.name, 40), t.id) returning id into gid;
  return jsonb_build_object('id', gid, 'garden_type', t.id, 'name', t.name, 'cost', t.cost, 'currency', t.currency);
end $$;

-- Put a plant on a spot in one of your gardens, or pass a null garden/spot to take it off. Tall plants cannot use small spots.
create function public.place_plant(pid uuid, gid uuid, spot_name text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g gardens; t garden_types; sz text; tl boolean;
begin
  if u is null or not exists (select 1 from plants where id = pid and user_id = u) then raise exception 'not your plant'; end if;
  perform 1 from profiles where id = u for update;
  if gid is null or spot_name is null then
    update plants set garden_id = null, spot = null where id = pid;
    return;
  end if;
  select * into g from gardens where id = gid and owner_id = u;
  if not found then raise exception 'not your garden'; end if;
  select * into t from garden_types where id = g.garden_type;
  select size into sz from garden_spots where layout = t.layout and spot_id = spot_name;
  if sz is null then raise exception 'invalid spot'; end if;
  select c.tall into tl from plants p join plant_catalog c on c.id = p.type where p.id = pid;
  if tl and sz = 'S' then raise exception 'This plant is too tall for a small spot'; end if;
  update plants set garden_id = null, spot = null where garden_id = gid and spot = spot_name and id <> pid;
  update plants set garden_id = gid, spot = spot_name where id = pid;
end $$;

-- 9. Likes: one per player per garden, not your own, public gardens only. Calling again removes the like.
create function public.toggle_garden_like(gid uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); g gardens; liked boolean; n int;
begin
  if u is null then raise exception 'not signed in'; end if;
  select * into g from gardens where id = gid and is_public;
  if not found then raise exception 'Garden not found'; end if;
  if g.owner_id = u then raise exception 'You cannot like your own garden'; end if;
  delete from garden_likes where user_id = u and garden_id = gid;
  if found then liked := false;
  else insert into garden_likes (user_id, garden_id) values (u, gid); liked := true; end if;
  update gardens set like_count = (select count(*) from garden_likes where garden_id = gid) where id = gid returning like_count into n;
  return jsonb_build_object('liked', liked, 'like_count', n);
end $$;

-- 10. Realm: sort by recently published, most liked, or the owner's level
create function public.list_public_gardens(sort text default 'recent', page_offset int default 0, page_size int default 12)
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
        (select count(distinct pl.type) from plants pl where pl.garden_id = g.id and pl.spot is not null and pl.public_display) as cultivars,
        (select count(*) from player_achievements pa where pa.user_id = g.owner_id and pa.claimed_at is not null) as achievements,
        (select coalesce(jsonb_agg(jsonb_build_object('type', x.type, 'stage', x.stage)), '[]'::jsonb)
           from (select pl.type, pl.stage from plants pl where pl.garden_id = g.id and pl.spot is not null and pl.public_display
                 order by pl.stage desc, pl.type limit 4) x) as preview,
        case sort when 'likes' then g.like_count when 'level' then pr.level end as ord_a,
        case sort when 'level' then pr.xp end as ord_b
      from gardens g join profiles pr on pr.id = g.owner_id
      where g.is_public and exists (select 1 from plants pl where pl.garden_id = g.id and pl.spot is not null and pl.public_display)
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
    and exists (select 1 from plants pl where pl.garden_id = g.id and pl.spot is not null and pl.public_display)
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
      from plants p join plant_catalog c on c.id = p.type where p.garden_id = g.id and p.spot is not null and p.public_display),
    'collector', jsonb_build_object('unique_plants', (select count(*) from plants where user_id = g.owner_id),
      'achievements', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'icon', a.icon) order by a.sort), '[]'::jsonb)
        from player_achievements pa join achievements a on a.id = pa.achievement_id where pa.user_id = g.owner_id and pa.claimed_at is not null)));
end $$;

-- 11. Permissions
revoke execute on function public.get_my_gardens(), public.update_garden(uuid,text,text), public.set_garden_public(uuid,boolean), public.buy_garden(text,uuid),
  public.place_plant(uuid,uuid,text), public.toggle_garden_like(uuid), public.list_public_gardens(text,int,int) from public, anon;
grant execute on function public.get_my_gardens(), public.update_garden(uuid,text,text), public.set_garden_public(uuid,boolean), public.buy_garden(text,uuid),
  public.place_plant(uuid,uuid,text), public.toggle_garden_like(uuid), public.list_public_gardens(text,int,int) to authenticated;
notify pgrst, 'reload schema';
