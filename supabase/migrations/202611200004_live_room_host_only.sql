-- Only approved active adult Hosts can create Live rooms.
-- Preserve all existing room records; tighten the creation policy only.
drop policy if exists "Hosts can create live rooms" on public.live_rooms;
create policy "Hosts can create live rooms" on public.live_rooms
for insert to authenticated
with check (
 host_id=auth.uid()
 and status='scheduled'
 and provider='livekit'
 and exists(select 1 from public.hosts h where h.user_id=auth.uid() and h.host_status='active')
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.account_status='active' and p.age>=18)
);
