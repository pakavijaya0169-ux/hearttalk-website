-- HeartTalk 3-second live selfie host verification.
-- Apply after 202611100002_host_agency_foundation.sql and commerce/payout migrations.
-- Selfie files are private; admins review manually. No automated face/gender inference.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('host-verification','host-verification',false,10485760,array['video/webm','video/mp4','video/quicktime'])
on conflict(id) do update set public=false,file_size_limit=10485760,
  allowed_mime_types=array['video/webm','video/mp4','video/quicktime'];

drop policy if exists "Host applicants upload own verification video" on storage.objects;
create policy "Host applicants upload own verification video"
on storage.objects for insert to authenticated
with check (
  bucket_id='host-verification'
  and (storage.foldername(name))[1]=auth.uid()::text
  and exists(select 1 from public.host_applications a where a.user_id=auth.uid() and a.status in ('pending','under_review'))
);
drop policy if exists "Applicants and admins read verification video" on storage.objects;
create policy "Applicants and admins read verification video"
on storage.objects for select to authenticated
using (
  bucket_id='host-verification'
  and (
    (storage.foldername(name))[1]=auth.uid()::text
    or public.is_hearttalk_admin()
  )
);
drop policy if exists "Applicants delete own pending verification video" on storage.objects;
create policy "Applicants delete own pending verification video"
on storage.objects for delete to authenticated
using (
  bucket_id='host-verification'
  and (storage.foldername(name))[1]=auth.uid()::text
  and exists(select 1 from public.host_kyc_documents d where d.storage_object_path=name and d.user_id=auth.uid() and d.status in ('pending','rejected'))
);

-- Host application still requires the profile to self-identify as female and be 18+.
-- This is an eligibility declaration, not proof; the Admin must review the live video.
create or replace function public.admin_review_host_application(
  p_application_id uuid,
  p_decision text,
  p_review_note text default null
)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_user_id uuid; v_gender text; v_age integer;
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected'; end if;
  select a.user_id into v_user_id from public.host_applications a where a.id=p_application_id for update;
  if not found then raise exception 'Host application not found'; end if;
  select lower(coalesce(p.gender,'')),p.age into v_gender,v_age from public.profiles p where p.id=v_user_id;
  if p_decision='approved' and (v_gender<>'female' or v_age is null or v_age<18) then
    raise exception 'Applicant must meet the 18+ female host eligibility declaration';
  end if;
  if p_decision='approved' and not exists(
    select 1 from public.host_kyc_documents d
    where d.user_id=v_user_id and d.document_type='video_selfie' and d.status='approved'
  ) then raise exception 'The 3-second live selfie must be approved first'; end if;
  update public.host_applications set status=p_decision,reviewed_at=now(),reviewed_by=auth.uid(),
    review_note=left(coalesce(p_review_note,''),1000) where id=p_application_id;
  if p_decision='approved' then
    insert into public.hosts(user_id,host_status,approved_at,approved_by)
    values(v_user_id,'active',now(),auth.uid())
    on conflict(user_id) do update set host_status='active',approved_at=now(),approved_by=auth.uid(),updated_at=now();
  else
    update public.hosts set host_status='suspended',updated_at=now() where user_id=v_user_id;
  end if;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'host_application_'||p_decision,'host_application',p_application_id::text,
    jsonb_build_object('user_id',v_user_id,'review_note',left(coalesce(p_review_note,''),1000)));
  return true;
end; $$;
revoke all on function public.admin_review_host_application(uuid,text,text) from public,anon;
grant execute on function public.admin_review_host_application(uuid,text,text) to authenticated;

-- Host calls are allowed only when the receiving host has an approved application,
-- active host record and an approved live selfie. Ordinary member-to-member calls remain open.
create or replace function public.hearttalk_start_call(target_user_id uuid, requested_call_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_call_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if target_user_id is null or target_user_id=v_user then raise exception 'Choose another member'; end if;
  if requested_call_type not in ('voice','video') then raise exception 'Invalid call type'; end if;
  if exists(select 1 from public.hosts h where h.user_id in (v_user,target_user_id)
    and (h.host_status<>'active' or not exists(
      select 1 from public.host_applications a where a.user_id=h.user_id and a.status='approved'
    ) or not exists(select 1 from public.host_kyc_documents d where d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'))
  ) then raise exception 'Host verification is not active'; end if;
  perform 1 from auth.users where id in (v_user,target_user_id) order by id for update;
  update public.call_sessions set status='missed',ended_at=now()
  where status='ringing' and created_at<=now()-interval '50 seconds'
    and (caller_id in (v_user,target_user_id) or callee_id in (v_user,target_user_id));
  if exists(select 1 from public.call_sessions where status in ('ringing','accepted')
    and (caller_id in (v_user,target_user_id) or callee_id in (v_user,target_user_id))) then
    raise exception 'User is already on another call';
  end if;
  if exists(select 1 from public.user_blocks where (blocker_id=v_user and blocked_id=target_user_id)
    or (blocker_id=target_user_id and blocked_id=v_user)) then raise exception 'Calls are unavailable for blocked users'; end if;
  insert into public.call_sessions(caller_id,callee_id,call_type,status)
  values(v_user,target_user_id,requested_call_type,'ringing') returning id into v_call_id;
  return jsonb_build_object('call_id',v_call_id,'status','ringing','ring_timeout_seconds',50);
end; $$;
revoke all on function public.hearttalk_start_call(uuid,text) from public,anon;
grant execute on function public.hearttalk_start_call(uuid,text) to authenticated;

create or replace function public.hearttalk_accept_call(target_call_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_call public.call_sessions%rowtype;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_call from public.call_sessions where id=target_call_id;
  if not found or v_call.callee_id<>v_user then raise exception 'Call not found'; end if;
  if exists(select 1 from public.hosts h where h.user_id in (v_call.caller_id,v_call.callee_id)
    and (h.host_status<>'active' or not exists(
      select 1 from public.host_applications a where a.user_id=h.user_id and a.status='approved'
    ) or not exists(select 1 from public.host_kyc_documents d where d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'))
  ) then raise exception 'Host verification is not active'; end if;
  perform 1 from auth.users where id in (v_call.caller_id,v_call.callee_id) order by id for update;
  select * into v_call from public.call_sessions where id=target_call_id for update;
  if v_call.status<>'ringing' or v_call.created_at<=now()-interval '50 seconds' then
    update public.call_sessions set status='missed',ended_at=now() where id=target_call_id and status='ringing';
    return jsonb_build_object('accepted',false,'status','missed');
  end if;
  update public.call_sessions set status='missed',ended_at=now()
    where status='ringing' and id<>target_call_id and created_at<=now()-interval '50 seconds'
    and (caller_id in (v_call.caller_id,v_call.callee_id) or callee_id in (v_call.caller_id,v_call.callee_id));
  if exists(select 1 from public.call_sessions where id<>target_call_id and status in ('ringing','accepted')
    and (caller_id in (v_call.caller_id,v_call.callee_id) or callee_id in (v_call.caller_id,v_call.callee_id))) then
    return jsonb_build_object('accepted',false,'status','busy');
  end if;
  update public.call_sessions set status='accepted',started_at=now() where id=target_call_id and status='ringing';
  return jsonb_build_object('accepted',true,'status','accepted');
end; $$;
revoke all on function public.hearttalk_accept_call(uuid) from public,anon;
grant execute on function public.hearttalk_accept_call(uuid) to authenticated;

-- Gifts cannot create host earnings for an account that has not passed selfie review.
create or replace function public.hearttalk_send_gift(target_host_id uuid, selected_gift_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_sender uuid:=auth.uid(); v_price integer; v_host_share integer; v_platform_share integer; v_event bigint;
begin
  if v_sender is null then raise exception 'Authentication required'; end if;
  if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;
  if not exists(select 1 from public.hosts h join public.host_applications a on a.user_id=h.user_id
    join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'
    where h.user_id=target_host_id and h.host_status='active' and a.status='approved') then
    raise exception 'This host is not verified for gifts yet';
  end if;
  select coin_price into v_price from public.hearttalk_gift_catalog where gift_code=selected_gift_code and active=true;
  if not found then raise exception 'Gift is unavailable'; end if;
  if v_price<=0 then raise exception 'Invalid gift price'; end if;
  perform 1 from auth.users where id=v_sender for update;
  if (select coalesce(sum(amount),0) from public.wallet_ledger where user_id=v_sender)<v_price then
    raise exception 'Not enough coins';
  end if;
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_sender,-v_price,'spend','gift:'||gen_random_uuid()::text);
  v_host_share:=floor(v_price*0.60)::integer; v_platform_share:=v_price-v_host_share;
  insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins)
  values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share) returning id into v_event;
  insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins)
  values(target_host_id,v_event,v_host_share);
  return jsonb_build_object('gift_event_id',v_event,'coin_price',v_price,'host_earned_coins',v_host_share,
    'platform_earned_coins',v_platform_share);
end; $$;
revoke all on function public.hearttalk_send_gift(uuid,text) from public,anon;
grant execute on function public.hearttalk_send_gift(uuid,text) to authenticated;

-- Withdrawal RPC checks verification again at the server boundary.
create or replace function public.hearttalk_request_manual_upi_withdrawal(
 p_amount_paise bigint,p_upi_id text,p_account_holder_name text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_available bigint; v_id uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from public.hosts h join public.host_applications a on a.user_id=h.user_id
   join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'
   where h.user_id=v_user and h.host_status='active' and a.status='approved') then
   raise exception 'Host verification is required before withdrawal';
 end if;
 if p_amount_paise is null or p_amount_paise<50000 then raise exception 'Minimum withdrawal is ₹500'; end if;
 if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]{2,256}@[a-z][a-z0-9]{1,20}$' then raise exception 'Enter a valid UPI ID'; end if;
 if p_account_holder_name is null or char_length(trim(p_account_holder_name)) not between 2 and 100 then raise exception 'Enter account holder name'; end if;
 perform 1 from auth.users where id=v_user for update;
 select coalesce(sum(amount_paise),0) into v_available from public.hearttalk_host_cash_ledger where host_id=v_user;
 if exists(select 1 from public.hearttalk_host_payout_requests where host_id=v_user and status in ('pending','approved')) then raise exception 'You already have an open withdrawal request'; end if;
 if v_available<p_amount_paise then raise exception 'Insufficient available earnings'; end if;
 insert into public.hearttalk_host_payout_requests(host_id,amount_paise,upi_id,account_holder_name)
 values(v_user,p_amount_paise,trim(p_upi_id),trim(p_account_holder_name)) returning id into v_id;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v_user,-p_amount_paise,'withdrawal_hold',v_id,'Reserved for manual UPI withdrawal',v_user);
 return jsonb_build_object('request_id',v_id,'amount_paise',p_amount_paise,'status','pending');
end; $$;
revoke all on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) from public,anon;
grant execute on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) to authenticated;

-- Admin-only helper returns pending video object paths for signed URL generation in browser.
create or replace function public.admin_get_host_video_path(p_document_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_path text;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select storage_object_path into v_path from public.host_kyc_documents
 where id=p_document_id and document_type='video_selfie';
 if v_path is null then raise exception 'Selfie video not found'; end if;
 return v_path;
end; $$;
revoke all on function public.admin_get_host_video_path(uuid) from public,anon;
grant execute on function public.admin_get_host_video_path(uuid) to authenticated;
