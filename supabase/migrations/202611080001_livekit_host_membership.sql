-- HeartTalk LiveKit room host membership permissions.
-- Run once in Supabase Dashboard > SQL Editor.
drop policy if exists "Hosts can add themselves as live hosts" on public.live_room_members;
create policy "Hosts can add themselves as live hosts"
on public.live_room_members for insert to authenticated
with check (
  user_id = auth.uid()
  and role = 'host'
  and exists (
    select 1 from public.live_rooms r
    where r.id = room_id and r.host_id = auth.uid()
  )
);
