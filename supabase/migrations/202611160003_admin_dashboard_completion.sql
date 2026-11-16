-- HeartTalk Admin Dashboard completion: wallet controls, host queue, call/gift logs,
-- dynamic UPI settings, and push-notification queue.
-- Additive only. Manual UPI remains the only recharge method; no gateway is enabled.
-- Push notifications are queued here; actual device delivery requires FCM server integration.

create table if not exists public.hearttalk_admin_payment_settings (
  singleton boolean primary key default true check (singleton),
  upi_id text not null default 'pakavijaya0169-4@oksbi',
  qr_image_url text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint hearttalk_admin_payment_settings_upi_check
    check (upi_id ~* '^[a-z0-9._-]+@[a-z][a-z0-9]{1,20}$')
);
insert into public.hearttalk_admin_payment_settings(singleton,upi_id)
values(true,'pakavijaya0169-4@oksbi')
on conflict(singleton) do nothing;
alter table public.hearttalk_admin_payment_settings enable row level security;
revoke all on public.hearttalk_admin_payment_settings from anon,authenticated,public;

create or replace function public.admin_get_payment_settings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select jsonb_build_object('upi_id',upi_id,'qr_image_url',qr_image_url,'updated_at',updated_at)
 into v from public.hearttalk_admin_payment_settings where singleton=true;
 return coalesce(v,'{}'::jsonb);
end; $$;

create or replace function public.hearttalk_get_public_payment_settings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select jsonb_build_object('upi_id',upi_id,'qr_image_url',qr_image_url)
 into v from public.hearttalk_admin_payment_settings where singleton=true;
 return coalesce(v,'{}'::jsonb);
end; $$;

create or replace function public.admin_save_payment_settings(p_upi_id text,p_qr_image_url text default null)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]+@[a-z][a-z0-9]{1,20}$' then
   raise exception 'Enter a valid UPI ID';
 end if;
 if p_qr_image_url is not null and (length(p_qr_image_url)>2048 or p_qr_image_url !~* '^https://') then
   raise exception 'QR image must be an HTTPS URL';
 end if;
 insert into public.hearttalk_admin_payment_settings(singleton,upi_id,qr_image_url,updated_by,updated_at)
 values(true,trim(p_upi_id),nullif(trim(p_qr_image_url),''),auth.uid(),now())
 on conflict(singleton) do update set upi_id=excluded.upi_id,
   qr_image_url=excluded.qr_image_url,updated_by=excluded.updated_by,updated_at=now();
 return true;
end; $$;

create or replace function public.admin_adjust_wallet_balance(
 p_user_id uuid,p_amount integer,p_note text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ref text; v_balance bigint;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_user_id is null or p_amount is null or p_amount=0 then raise exception 'Enter a non-zero coin adjustment'; end if;
 if p_note is null or char_length(trim(p_note))<3 then raise exception 'Enter an adjustment reason'; end if;
 if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'User not found'; end if;
 v_ref:='admin-adjust:'||gen_random_uuid()::text;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
 values(p_user_id,p_amount,'admin_adjustment',v_ref);
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=p_user_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'wallet_balance_adjusted','user',p_user_id::text,
   jsonb_build_object('amount_coins',p_amount,'note',trim(p_note),'reference_id',v_ref,'new_balance',v_balance));
 return jsonb_build_object('reference_id',v_ref,'new_balance',v_balance);
end; $$;

create or replace function public.admin_list_host_review_queue()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.submitted_at desc),'[]'::jsonb) into v_rows
 from (
  select a.id as application_id,a.user_id,a.preferred_language,a.intro,a.status,a.submitted_at,
   p.display_name,p.username,p.age,p.gender,p.avatar_url,
   coalesce((select jsonb_agg(jsonb_build_object(
     'id',d.id,'document_type',d.document_type,'status',d.status,
     'masked_reference',d.masked_reference,'submitted_at',d.submitted_at
   ) order by d.submitted_at desc) from public.host_kyc_documents d where d.user_id=a.user_id),'[]'::jsonb) as documents
  from public.host_applications a
  left join public.profiles p on p.id=a.user_id
  where a.status in ('pending','under_review')
  order by a.submitted_at desc limit 300
 ) q;
 return v_rows;
end; $$;

create or replace function public.admin_list_call_commission_logs(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select 'call'::text as record_type,c.id::text as record_id,c.caller_id,c.callee_id,
   c.call_type,c.status,
   case when c.started_at is not null and c.ended_at is not null
     then greatest(0,extract(epoch from (c.ended_at-c.started_at))::integer) else null end as duration_seconds,
   null::integer as total_coins,null::integer as host_share_coins,null::integer as platform_share_coins,
   c.created_at
  from public.call_sessions c
  union all
  select 'gift_commission',g.id::text,g.sender_id,g.host_id,
   g.gift_code,'settled',
   null::integer,g.coin_price,g.host_share_coins,g.platform_share_coins,g.created_at
  from public.hearttalk_gift_events g
  order by created_at desc limit greatest(1,least(coalesce(p_limit,100),500))
 ) q;
 return v_rows;
end; $$;

create table if not exists public.hearttalk_admin_push_queue (
 id uuid primary key default gen_random_uuid(),
 title text not null check(char_length(trim(title)) between 2 and 120),
 body text not null check(char_length(trim(body)) between 2 and 1000),
 image_url text,
 audience text not null default 'all' check(audience in ('all','active','hosts','specific')),
 target_user_id uuid references auth.users(id) on delete set null,
 status text not null default 'queued' check(status in ('queued','sent','failed','cancelled')),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 processed_at timestamptz,
 result_note text not null default '',
 check(image_url is null or image_url ~* '^https://'),
 check((audience='specific')=(target_user_id is not null))
);
create index if not exists hearttalk_admin_push_queue_created_idx
 on public.hearttalk_admin_push_queue(created_at desc);
alter table public.hearttalk_admin_push_queue enable row level security;
revoke all on public.hearttalk_admin_push_queue from anon,authenticated,public;

create or replace function public.admin_queue_push_notification(
 p_title text,p_body text,p_image_url text default null,
 p_audience text default 'all',p_target_user_id uuid default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_audience not in ('all','active','hosts','specific') then raise exception 'Invalid audience'; end if;
 if (p_audience='specific')<>(p_target_user_id is not null) then raise exception 'Select a target user for specific notifications'; end if;
 if p_image_url is not null and (length(p_image_url)>2048 or p_image_url !~* '^https://') then raise exception 'Image URL must be HTTPS'; end if;
 insert into public.hearttalk_admin_push_queue(title,body,image_url,audience,target_user_id,created_by)
 values(trim(p_title),trim(p_body),nullif(trim(p_image_url),''),p_audience,p_target_user_id,auth.uid())
 returning id into v_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'push_notification_queued','push_notification',v_id::text,
   jsonb_build_object('audience',p_audience,'has_image',p_image_url is not null));
 return v_id;
end; $$;

create or replace function public.admin_list_push_notifications()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (select id,title,body,image_url,audience,target_user_id,status,created_at,processed_at,result_note
       from public.hearttalk_admin_push_queue order by created_at desc limit 100) q;
 return v_rows;
end; $$;

revoke all on function public.admin_get_payment_settings() from public,anon;
revoke all on function public.hearttalk_get_public_payment_settings() from public,anon;
revoke all on function public.admin_save_payment_settings(text,text) from public,anon;
revoke all on function public.admin_adjust_wallet_balance(uuid,integer,text) from public,anon;
revoke all on function public.admin_list_host_review_queue() from public,anon;
revoke all on function public.admin_list_call_commission_logs(integer) from public,anon;
revoke all on function public.admin_queue_push_notification(text,text,text,text,uuid) from public,anon;
revoke all on function public.admin_list_push_notifications() from public,anon;
grant execute on function public.admin_get_payment_settings() to authenticated;
grant execute on function public.hearttalk_get_public_payment_settings() to authenticated;
grant execute on function public.admin_save_payment_settings(text,text) to authenticated;
grant execute on function public.admin_adjust_wallet_balance(uuid,integer,text) to authenticated;
grant execute on function public.admin_list_host_review_queue() to authenticated;
grant execute on function public.admin_list_call_commission_logs(integer) to authenticated;
grant execute on function public.admin_queue_push_notification(text,text,text,text,uuid) to authenticated;
grant execute on function public.admin_list_push_notifications() to authenticated;
