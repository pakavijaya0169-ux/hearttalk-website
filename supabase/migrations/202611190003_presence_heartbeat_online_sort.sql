-- HeartTalk real online presence (heartbeat-based; online means seen within 90 seconds)
create table if not exists public.hearttalk_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_seen timestamptz not null default now()
);
alter table public.hearttalk_presence enable row level security;
grant select, insert, update on public.hearttalk_presence to authenticated;
drop policy if exists "presence readable by authenticated" on public.hearttalk_presence;
create policy "presence readable by authenticated"
  on public.hearttalk_presence for select to authenticated using (true);
drop policy if exists "presence own insert" on public.hearttalk_presence;
create policy "presence own insert"
  on public.hearttalk_presence for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "presence own update" on public.hearttalk_presence;
create policy "presence own update"
  on public.hearttalk_presence for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create index if not exists hearttalk_presence_last_seen_idx on public.hearttalk_presence(last_seen desc);
