-- Permit signed-in members to read only active, public gift catalogue items.
-- Catalogue entries contain display metadata and prices; gift purchases remain
-- server-validated by hearttalk_send_gift / hearttalk_send_live_room_gift.
alter table public.hearttalk_gift_catalog enable row level security;

grant select on table public.hearttalk_gift_catalog to authenticated;

drop policy if exists "Authenticated members can read active gifts"
  on public.hearttalk_gift_catalog;

create policy "Authenticated members can read active gifts"
  on public.hearttalk_gift_catalog
  for select
  to authenticated
  using (active = true);