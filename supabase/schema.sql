-- Run this once in Supabase: SQL Editor > New query > paste > Run.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  is_admin boolean not null default false
);
alter table public.profiles enable row level security;
create policy "read own profile" on public.profiles for select using (auth.uid() = id);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin insert into public.profiles (id) values (new.id); return new; end $$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create table public.plants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  type text not null check (type in ('cream','sword','dark','banded','coppertone','siamsilver','trifasciata','laurentii','blackgold')),
  name text not null,
  stage int not null default 1 check (stage between 1 and 20),
  spot text,
  last_watered_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.plants enable row level security;
create policy "users manage their own plants" on public.plants
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Only admins may change a plant's growth stage.
create function public.guard_stage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage is distinct from old.stage
     and not coalesce((select is_admin from public.profiles where id = auth.uid()), false) then
    raise exception 'Only admins can change growth stage';
  end if;
  return new;
end $$;
create trigger guard_stage before update on public.plants
for each row execute function public.guard_stage();

-- After you sign up in the app, make yourself admin (use your email):
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'you@example.com');
