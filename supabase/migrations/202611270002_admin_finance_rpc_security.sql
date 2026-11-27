-- HeartTalk Admin Security Upgrade - Phase 2: financial RPC enforcement
-- Keeps existing payout workflow; adds server-side Finance permission checks and audit entries.
-- Requires 202611270001_admin_permission_foundation.sql to have been run.

create or replace function public.has_hearttalk_admin_permission(p_permission text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (
  exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin')
  or exists(select 1 from public.hearttalk_admin_staff_roles s where s.user_id=auth.uid() and (
   (s.staff_role='finance' and p_permission in ('finance.view','finance.adjust','payments.manage','withdrawals.manage','analytics.finance'))
   or (s.staff_role='moderator' and p_permission in ('users.view','users.manage','reports.manage','profiles.review','security.manage'))
   or (s.staff_role='support' and p_permission in ('users.view','support.manage'))
   or (s.staff_role='agency_manager' and p_permission in ('agency.view','hosts.view'))
  ))
 );
$$;
revoke all on function public.has_hearttalk_admin_permission(text) from public,anon;
grant execute on function public.has_hearttalk_admin_permission(text) to authenticated;

create or replace function public.admin_credit_host_cash_earnings(
 p_host_id uuid,p_amount_paise bigint,p_source_reference text,p_note text default ''
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not public.has_hearttalk_admin_permission('finance.adjust') then raise exception 'Finance permission required'; end if;
 if p_host_id is null or p_amount_paise is null or p_amount_paise<1 or p_source_reference is null or char_length(trim(p_source_reference)) not between 4 and 160 then raise exception 'Invalid earnings credit'; end if;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,source_reference,note,created_by)
 values(p_host_id,p_amount_paise,'earning_credit',trim(p_source_reference),coalesce(p_note,''),auth.uid())
 returning id into v_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'host_cash_earnings_credited','host',p_host_id::text,
 jsonb_build_object('amount_paise',p_amount_paise,'source_reference',trim(p_source_reference),'ledger_id',v_id));
 return v_id;
exception when unique_violation then
 raise exception 'This source reference has already been credited to this host';
end; $$;
revoke all on function public.admin_credit_host_cash_earnings(uuid,bigint,text,text) from public,anon;
grant execute on function public.admin_credit_host_cash_earnings(uuid,bigint,text,text) to authenticated;

create or replace function public.admin_list_host_payout_requests(p_status text default 'all')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if not public.has_hearttalk_admin_permission('finance.view') then raise exception 'Finance permission required'; end if;
 if p_status not in ('all','pending','approved','paid','rejected') then raise exception 'Invalid status filter'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select r.id,r.host_id,r.amount_paise,r.upi_id,r.account_holder_name,r.status,r.utr,r.admin_note,r.created_at,r.reviewed_at,r.paid_at,
   coalesce(u.raw_user_meta_data->>'display_name',u.raw_user_meta_data->>'username',u.email,'HeartTalk Host') as host_name
  from public.hearttalk_host_payout_requests r
  left join auth.users u on u.id=r.host_id
  where p_status='all' or r.status=p_status
  order by r.created_at desc limit 500
 ) q;
 return v_rows;
end; $$;
revoke all on function public.admin_list_host_payout_requests(text) from public,anon;
grant execute on function public.admin_list_host_payout_requests(text) to authenticated;

create or replace function public.admin_approve_host_payout(p_request_id uuid,p_admin_note text default '')
returns boolean language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_host_payout_requests%rowtype;
begin
 if not public.has_hearttalk_admin_permission('withdrawals.manage') then raise exception 'Withdrawal management permission required'; end if;
 select * into v from public.hearttalk_host_payout_requests where id=p_request_id for update;
 if not found or v.status<>'pending' then raise exception 'Pending request not found'; end if;
 update public.hearttalk_host_payout_requests set status='approved',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=p_request_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'host_payout_approved','payout',p_request_id::text,jsonb_build_object('host_id',v.host_id,'amount_paise',v.amount_paise));
 return true;
end; $$;
revoke all on function public.admin_approve_host_payout(uuid,text) from public,anon;
grant execute on function public.admin_approve_host_payout(uuid,text) to authenticated;

create or replace function public.admin_mark_host_payout_paid(p_request_id uuid,p_utr text,p_admin_note text default '')
returns boolean language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_host_payout_requests%rowtype;
begin
 if not public.has_hearttalk_admin_permission('withdrawals.manage') then raise exception 'Withdrawal management permission required'; end if;
 if p_utr is null or char_length(trim(p_utr)) not between 6 and 100 then raise exception 'Enter valid UTR / UPI reference ID'; end if;
 select * into v from public.hearttalk_host_payout_requests where id=p_request_id for update;
 if not found or v.status not in ('pending','approved') then raise exception 'Request is not payable'; end if;
 if exists(select 1 from public.hearttalk_host_payout_requests where utr=trim(p_utr) and status='paid' and id<>p_request_id) then raise exception 'This UTR has already been used'; end if;
 update public.hearttalk_host_payout_requests set status='paid',utr=trim(p_utr),admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),paid_at=now(),updated_at=now() where id=p_request_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'host_payout_marked_paid','payout',p_request_id::text,jsonb_build_object('host_id',v.host_id,'amount_paise',v.amount_paise,'utr',trim(p_utr)));
 return true;
end; $$;
revoke all on function public.admin_mark_host_payout_paid(uuid,text,text) from public,anon;
grant execute on function public.admin_mark_host_payout_paid(uuid,text,text) to authenticated;

create or replace function public.admin_reject_host_payout(p_request_id uuid,p_admin_note text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_host_payout_requests%rowtype;
begin
 if not public.has_hearttalk_admin_permission('withdrawals.manage') then raise exception 'Withdrawal management permission required'; end if;
 select * into v from public.hearttalk_host_payout_requests where id=p_request_id for update;
 if not found or v.status not in ('pending','approved') then raise exception 'Request cannot be rejected'; end if;
 update public.hearttalk_host_payout_requests set status='rejected',admin_note=coalesce(p_admin_note,'Request rejected'),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=p_request_id;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v.host_id,v.amount_paise,'withdrawal_release',v.id,'Reserved funds released after rejection',auth.uid());
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'host_payout_rejected','payout',p_request_id::text,jsonb_build_object('host_id',v.host_id,'amount_paise',v.amount_paise,'note',coalesce(p_admin_note,'')));
 return true;
end; $$;
revoke all on function public.admin_reject_host_payout(uuid,text) from public,anon;
grant execute on function public.admin_reject_host_payout(uuid,text) to authenticated;
