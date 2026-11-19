-- Additive safety guard: a user may have only one active billable chat session.
-- No existing chat, wallet, message, or earnings data is deleted.

create unique index if not exists hearttalk_chat_sessions_one_active_per_user_idx
 on public.hearttalk_chat_sessions(user_id)
 where status='active';

create or replace function public.hearttalk_start_chat_billing(p_host_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid(); v_session uuid; v_active_host uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_host_id is null or p_host_id=v_user then raise exception 'Invalid chat partner'; end if;
 perform 1 from auth.users where id=v_user for update;

 select id,host_id into v_session,v_active_host
 from public.hearttalk_chat_sessions
 where user_id=v_user and status='active'
 order by started_at desc limit 1;

 if v_session is not null then
  if v_active_host=p_host_id then
   return jsonb_build_object('session_id',v_session,'started',false,'already_active',true);
  else
   raise exception 'You already have an active chat billing session. End it before starting another.';
  end if;
 end if;

 insert into public.hearttalk_chat_sessions(user_id,host_id)
 values(v_user,p_host_id) returning id into v_session;
 return jsonb_build_object('session_id',v_session,'started',true);
end; $$;

revoke all on function public.hearttalk_start_chat_billing(uuid) from public;
grant execute on function public.hearttalk_start_chat_billing(uuid) to authenticated;
