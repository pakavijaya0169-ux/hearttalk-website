-- Enforce 5 total active participants per Live room, including the Host.
-- Lock the room row to serialize simultaneous joins. Existing memberships are preserved.
create or replace function public.hearttalk_enforce_live_room_capacity()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_host uuid; v_active_count integer; v_host_active boolean; v_user_active boolean;
begin
 if new.left_at is not null then return new; end if;
 select host_id into v_host from public.live_rooms where id=new.room_id for update;
 if v_host is null then raise exception 'Live room not found'; end if;
 select count(*) into v_active_count from public.live_room_members where room_id=new.room_id and left_at is null;
 select exists(select 1 from public.live_room_members where room_id=new.room_id and user_id=v_host and left_at is null) into v_host_active;
 select exists(select 1 from public.live_room_members where room_id=new.room_id and user_id=new.user_id and left_at is null) into v_user_active;
 if not v_host_active and new.user_id<>v_host then v_active_count:=v_active_count+1; end if;
 if not v_user_active then v_active_count:=v_active_count+1; end if;
 if v_active_count>5 then raise exception 'This Live room is full (maximum 5 people including Host).'; end if;
 return new;
end;$$;
drop trigger if exists hearttalk_live_room_capacity on public.live_room_members;
create trigger hearttalk_live_room_capacity before insert or update of left_at,role on public.live_room_members
for each row execute function public.hearttalk_enforce_live_room_capacity();
revoke all on function public.hearttalk_enforce_live_room_capacity() from public,anon,authenticated;
