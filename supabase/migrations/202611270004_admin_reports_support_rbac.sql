-- HeartTalk Admin RBAC: reports, support inbox and app error center
-- Additive security migration. Preserves existing RPC signatures and response shapes.
-- Super Admin retains access through has_hearttalk_admin_permission().
create or replace function public.admin_list_user_reports()
returns table (
  report_id bigint, reporter_id uuid, reporter_name text, reporter_username text,
  reported_user_id uuid, reported_user_name text, reported_username text,
  reason text, details text, status text, created_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.has_hearttalk_admin_permission('reports.manage') then raise exception 'Reports permission required'; end if;
  return query
  select ur.id, ur.reporter_id, coalesce(rp.display_name, 'Unknown user'), rp.username,
         ur.reported_user_id, coalesce(tp.display_name, 'Unknown user'), tp.username,
         ur.reason, ur.details, ur.status, ur.created_at
  from public.user_reports ur
  left join public.profiles rp on rp.id = ur.reporter_id
  left join public.profiles tp on tp.id = ur.reported_user_id
  order by ur.created_at desc limit 500;
end;
$$;

create or replace function public.admin_set_report_status(target_report_id bigint,new_status text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare old_status text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.has_hearttalk_admin_permission('reports.manage') then raise exception 'Reports permission required'; end if;
  if new_status is null or new_status not in ('open','reviewing','resolved','dismissed') then raise exception 'Invalid report status'; end if;
  select status into old_status from public.user_reports where id=target_report_id for update;
  if not found then raise exception 'Report not found'; end if;
  update public.user_reports set status=new_status where id=target_report_id;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'report_status_changed','user_report',target_report_id::text,
         jsonb_build_object('from',old_status,'to',new_status));
  return true;
end;
$$;

create or replace function public.admin_list_recent_audit_log()
returns table(log_id bigint,admin_user_id uuid,action text,target_type text,target_id text,details jsonb,created_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not (public.has_hearttalk_admin_permission('reports.manage')
       or public.has_hearttalk_admin_permission('support.manage')
       or public.has_hearttalk_admin_permission('finance.view')) then
    raise exception 'Audit log permission required';
  end if;
  return query
  select l.id,l.admin_user_id,l.action,l.target_type,l.target_id,l.details,l.created_at
  from public.hearttalk_admin_audit_log l order by l.created_at desc limit 100;
end;
$$;

create or replace function public.admin_get_support_inbox()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_result jsonb;
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('support.manage') then raise exception 'Support permission required'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into v_result from (
  select jsonb_build_object(
   'thread_id',t.id,'user_id',t.user_id,'subject',t.subject,'status',t.status,
   'created_at',t.created_at,'updated_at',t.updated_at,
   'email',u.email,'display_name',p.display_name,'username',p.username,
   'messages',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'sender_role',m.sender_role,'message',m.message,'created_at',m.created_at) order by m.created_at)
      from public.support_messages m where m.thread_id=t.id),'[]'::jsonb)
  ) x from public.support_threads t
  left join auth.users u on u.id=t.user_id
  left join public.profiles p on p.id=t.user_id
  order by t.updated_at desc limit 100
 ) q;
 return v_result;
end;
$$;

create or replace function public.admin_reply_support_thread(p_thread_id uuid,p_message text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_admin uuid:=auth.uid(); v_status text;
begin
 if v_admin is null or not public.has_hearttalk_admin_permission('support.manage') then raise exception 'Support permission required'; end if;
 if p_message is null or char_length(trim(p_message))<1 or char_length(p_message)>4000 then raise exception 'Reply must be 1 to 4000 characters'; end if;
 select status into v_status from public.support_threads where id=p_thread_id for update;
 if not found then raise exception 'Support conversation not found'; end if;
 if v_status='closed' then raise exception 'This support conversation is closed'; end if;
 insert into public.support_messages(thread_id,sender_id,sender_role,message)
 values(p_thread_id,v_admin,'admin',trim(p_message));
 update public.support_threads set status='answered',updated_at=now() where id=p_thread_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(v_admin,'support_reply_sent','support_thread',p_thread_id::text,jsonb_build_object('message_length',char_length(trim(p_message))));
 return jsonb_build_object('success',true);
end;
$$;

create or replace function public.admin_set_support_status(p_thread_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_old_status text;
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('support.manage') then raise exception 'Support permission required'; end if;
 if p_status not in ('open','answered','closed') then raise exception 'Invalid support status'; end if;
 select status into v_old_status from public.support_threads where id=p_thread_id for update;
 if not found then raise exception 'Support conversation not found'; end if;
 update public.support_threads set status=p_status,updated_at=now() where id=p_thread_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'support_status_changed','support_thread',p_thread_id::text,jsonb_build_object('from',v_old_status,'to',p_status));
 return true;
end;
$$;

create or replace function public.admin_get_app_errors()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_result jsonb;
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('support.manage') then raise exception 'Support permission required'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into v_result from (
  select jsonb_build_object('id',e.id,'user_id',e.user_id,'source',e.source,
   'error_type',e.error_type,'message',e.message,'stack',e.stack,'page',e.page,
   'app_version',e.app_version,'status',e.status,'created_at',e.created_at,
   'email',u.email,'display_name',p.display_name) x
  from public.app_error_reports e
  left join auth.users u on u.id=e.user_id
  left join public.profiles p on p.id=e.user_id
  order by e.created_at desc limit 200
 ) q;
 return v_result;
end;
$$;

create or replace function public.admin_set_app_error_status(p_error_id bigint,p_status text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_old_status text;
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('support.manage') then raise exception 'Support permission required'; end if;
 if p_status not in ('open','investigating','resolved','ignored') then raise exception 'Invalid error status'; end if;
 select status into v_old_status from public.app_error_reports where id=p_error_id for update;
 if not found then raise exception 'Error report not found'; end if;
 update public.app_error_reports set status=p_status,
  resolved_at=case when p_status='resolved' then now() else null end,
  resolved_by=case when p_status='resolved' then auth.uid() else null end
 where id=p_error_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'app_error_status_changed','app_error',p_error_id::text,jsonb_build_object('from',v_old_status,'to',p_status));
 return true;
end;
$$;

revoke all on function public.admin_list_user_reports() from public,anon;
revoke all on function public.admin_set_report_status(bigint,text) from public,anon;
revoke all on function public.admin_list_recent_audit_log() from public,anon;
revoke all on function public.admin_get_support_inbox() from public,anon;
revoke all on function public.admin_reply_support_thread(uuid,text) from public,anon;
revoke all on function public.admin_set_support_status(uuid,text) from public,anon;
revoke all on function public.admin_get_app_errors() from public,anon;
revoke all on function public.admin_set_app_error_status(bigint,text) from public,anon;
grant execute on function public.admin_list_user_reports() to authenticated;
grant execute on function public.admin_set_report_status(bigint,text) to authenticated;
grant execute on function public.admin_list_recent_audit_log() to authenticated;
grant execute on function public.admin_get_support_inbox() to authenticated;
grant execute on function public.admin_reply_support_thread(uuid,text) to authenticated;
grant execute on function public.admin_set_support_status(uuid,text) to authenticated;
grant execute on function public.admin_get_app_errors() to authenticated;
grant execute on function public.admin_set_app_error_status(bigint,text) to authenticated;
