-- Correct capacity accounting: count distinct active members plus the room Host exactly once.
-- This fixes double-counting when the Host membership is inserted and handles membership leave updates.
create or replace function public.hearttalk_enforce_live_room_capacity()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_host uuid; v_active_count integer;
begin
 select host_id into v_host from public.live_rooms where id=new.room_id for update;
 if v_host is null then raise exception 'Live room not found'; end if;

 select count(*) into v_active_count from (
   select m.user_id
   from public.live_room_members m
   where m.room_id=new.room_id
     and m.left_at is null
     and m.user_id<>new.user_id
   union
   select v_host
   union
   select new.user_id where new.left_at is null
 ) participants;

 if v_active_count>5 then
   raise exception 'This Live room is full (maximum 5 people including Host).';
 end if;
 return new;
end;$$;

drop trigger if exists hearttalk_live_room_capacity on public.live_room_members;
create trigger hearttalk_live_room_capacity
before insert or update of left_at,role on public.live_room_members
for each row execute function public.hearttalk_enforce_live_room_capacity();
revoke all on function public.hearttalk_enforce_live_room_capacity() from public,anon,authenticated;
