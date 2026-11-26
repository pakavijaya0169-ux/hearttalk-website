-- HeartTalk Admin Step 1: Live Operations Control
-- Additive only. Read-only monitoring plus audited admin termination controls.
create or replace function public.admin_get_live_operations()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_calls jsonb; v_rooms jsonb; v_chats jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_calls
 from (
  select c.id,c.caller_id,c.callee_id,c.call_type,c.status,c.created_at,c.started_at,
   p1.display_name as caller_name,p2.display_name as callee_name
  from public.call_sessions c
  left join public.profiles p1 on p1.id=c.caller_id
  left join public.profiles p2 on p2.id=c.callee_id
  where c.status in ('ringing','accepted')
  order by c.created_at desc limit 100
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rooms
 from (
  select r.id,r.host_id,r.title,r.status,r.created_at,p.display_name as host_name,
   (select count(*) from public.live_room_members m where m.room_id=r.id and m.left_at is null)::integer as active_members
  from public.live_rooms r left join public.profiles p on p.id=r.host_id
  where r.status in ('live','scheduled')
  order by r.created_at desc limit 100
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc),'[]'::jsonb) into v_chats
 from (
  select s.id,s.user_id,s.host_id,s.started_at,p1.display_name as user_name,p2.display_name as host_name
  from public.hearttalk_chat_sessions s
  left join public.profiles p1 on p1.id=s.user_id
  left join public.profiles p2 on p2.id=s.host_id
  where s.status='active'
  order by s.started_at desc limit 100
 ) x;
 return jsonb_build_object('calls',v_calls,'rooms',v_rooms,'chats',v_chats,'generated_at',now());
end; $$;

create or replace function public.admin_end_live_call(p_call_id uuid,p_reason text default 'Admin ended call')
returns boolean language plpgsql security definer set search_path='' as $$
declare v_call public.call_sessions%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_call_id is null then raise exception 'Call ID is required'; end if;
 select * into v_call from public.call_sessions where id=p_call_id for update;
 if not found or v_call.status not in ('ringing','accepted') then raise exception 'Call is no longer active'; end if;
 update public.call_sessions set status='ended',ended_at=now() where id=p_call_id and status in ('ringing','accepted');
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'admin_ended_call','call',p_call_id::text,jsonb_build_object('reason',left(coalesce(p_reason,''),300),'previous_status',v_call.status));
 return true;
end; $$;

create or replace function public.admin_end_live_room(p_room_id uuid,p_reason text default 'Admin ended live room')
returns boolean language plpgsql security definer set search_path='' as $$
declare v_room public.live_rooms%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_room_id is null then raise exception 'Room ID is required'; end if;
 select * into v_room from public.live_rooms where id=p_room_id for update;
 if not found or v_room.status not in ('live','scheduled') then raise exception 'Room is already ended or unavailable'; end if;
 update public.live_rooms set status='ended',ended_at=now() where id=p_room_id and status in ('live','scheduled');
 update public.live_room_members set left_at=now() where room_id=p_room_id and left_at is null;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'admin_ended_live_room','live_room',p_room_id::text,jsonb_build_object('reason',left(coalesce(p_reason,''),300),'previous_status',v_room.status));
 return true;
end; $$;

revoke all on function public.admin_get_live_operations() from public,anon;
revoke all on function public.admin_end_live_call(uuid,text) from public,anon;
revoke all on function public.admin_end_live_room(uuid,text) from public,anon;
grant execute on function public.admin_get_live_operations() to authenticated;
grant execute on function public.admin_end_live_call(uuid,text) to authenticated;
grant execute on function public.admin_end_live_room(uuid,text) to authenticated;
