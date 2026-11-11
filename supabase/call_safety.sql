-- HeartTalk call safety: one active call per user, atomic start/accept, 50-second ring timeout.
alter table public.call_sessions drop constraint if exists call_sessions_status_check;
alter table public.call_sessions add constraint call_sessions_status_check check (status in ('ringing','accepted','rejected','ended','missed','cancelled','busy'));
-- Run this migration in Supabase SQL Editor after the existing schema.sql.
create index if not exists call_sessions_caller_active_idx
  on public.call_sessions(caller_id, status, created_at desc);
create index if not exists call_sessions_callee_active_idx
  on public.call_sessions(callee_id, status, created_at desc);

create or replace function public.hearttalk_start_call(target_user_id uuid, requested_call_type text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_call_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if target_user_id is null or target_user_id = v_user then raise exception 'Choose another member'; end if;
  if requested_call_type not in ('voice','video') then raise exception 'Invalid call type'; end if;

  -- Serialize simultaneous call attempts involving either participant.
  perform 1 from auth.users
   where id in (v_user, target_user_id)
   order by id
   for update;

  -- Close expired ringing calls before checking availability.
  update public.call_sessions
     set status='missed', ended_at=now()
   where status='ringing'
     and created_at <= now() - interval '50 seconds'
     and (caller_id in (v_user,target_user_id) or callee_id in (v_user,target_user_id));

  if exists (
    select 1 from public.call_sessions
     where status in ('ringing','accepted')
       and (caller_id in (v_user,target_user_id) or callee_id in (v_user,target_user_id))
  ) then
    raise exception 'User is already on another call';
  end if;

  if exists(select 1 from public.user_blocks
     where (blocker_id=v_user and blocked_id=target_user_id)
        or (blocker_id=target_user_id and blocked_id=v_user)) then
    raise exception 'Calls are unavailable for blocked users';
  end if;

  insert into public.call_sessions(caller_id,callee_id,call_type,status)
  values(v_user,target_user_id,requested_call_type,'ringing')
  returning id into v_call_id;

  return jsonb_build_object('call_id',v_call_id,'status','ringing','ring_timeout_seconds',50);
end;
$$;

create or replace function public.hearttalk_accept_call(target_call_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_call public.call_sessions%rowtype;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_call from public.call_sessions where id=target_call_id;
  if not found or v_call.callee_id<>v_user then raise exception 'Call not found'; end if;

  perform 1 from auth.users
   where id in (v_call.caller_id,v_call.callee_id)
   order by id
   for update;

  select * into v_call from public.call_sessions where id=target_call_id for update;
  if v_call.status<>'ringing' or v_call.created_at<=now()-interval '50 seconds' then
    update public.call_sessions set status='missed',ended_at=now()
     where id=target_call_id and status='ringing';
    return jsonb_build_object('accepted',false,'status','missed');
  end if;

  update public.call_sessions
     set status='missed',ended_at=now()
   where status='ringing' and id<>target_call_id
     and created_at<=now()-interval '50 seconds'
     and (caller_id in (v_call.caller_id,v_call.callee_id) or callee_id in (v_call.caller_id,v_call.callee_id));

  if exists (
    select 1 from public.call_sessions
     where id<>target_call_id and status in ('ringing','accepted')
       and (caller_id in (v_call.caller_id,v_call.callee_id) or callee_id in (v_call.caller_id,v_call.callee_id))
  ) then
    return jsonb_build_object('accepted',false,'status','busy');
  end if;

  update public.call_sessions set status='accepted',started_at=now()
   where id=target_call_id and status='ringing';
  return jsonb_build_object('accepted',true,'status','accepted');
end;
$$;

create or replace function public.hearttalk_end_call(target_call_id uuid, final_status text default 'ended')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_updated integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if final_status not in ('rejected','ended','cancelled','busy') then raise exception 'Invalid final call status'; end if;
  update public.call_sessions
     set status=final_status,ended_at=now()
   where id=target_call_id
     and status in ('ringing','accepted')
     and (caller_id=v_user or callee_id=v_user);
  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated',v_updated=1,'status',final_status);
end;
$$;

create or replace function public.hearttalk_expire_call(target_call_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_updated integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  update public.call_sessions
     set status='missed',ended_at=now()
   where id=target_call_id and status='ringing'
     and created_at<=now()-interval '50 seconds'
     and (caller_id=v_user or callee_id=v_user);
  get diagnostics v_updated = row_count;
  return jsonb_build_object('expired',v_updated=1);
end;
$$;

revoke all on function public.hearttalk_start_call(uuid,text) from public, anon;
revoke all on function public.hearttalk_accept_call(uuid) from public, anon;
revoke all on function public.hearttalk_end_call(uuid,text) from public, anon;
revoke all on function public.hearttalk_expire_call(uuid) from public, anon;
grant execute on function public.hearttalk_start_call(uuid,text) to authenticated;
grant execute on function public.hearttalk_accept_call(uuid) to authenticated;
grant execute on function public.hearttalk_end_call(uuid,text) to authenticated;
grant execute on function public.hearttalk_expire_call(uuid) to authenticated;

-- Call state changes must go through the atomic RPCs above.
revoke insert, update, delete on public.call_sessions from anon, authenticated;
grant select on public.call_sessions to authenticated;
