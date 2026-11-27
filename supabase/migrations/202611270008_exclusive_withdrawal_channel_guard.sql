-- Prevent simultaneous manual UPI and Cashfree withdrawal reservations for the same host.
-- Both request RPCs lock auth.users first, then check the other workflow before reserving funds.

create or replace function public.hearttalk_request_cashfree_payout(
 p_amount_paise bigint,
 p_payout_method text,
 p_upi_id text,
 p_account_holder_name text,
 p_bank_account_number text,
 p_bank_ifsc text,
 p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_available bigint;
 v_request_id uuid;
 v_existing public.hearttalk_cashfree_payout_requests%rowtype;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_idempotency_key is null then raise exception 'Idempotency key required'; end if;

 perform 1 from auth.users where id=v_user for update;

 if not exists (
  select 1
  from public.hosts h
  join public.host_applications a on a.user_id=h.user_id
  join public.host_kyc_documents d on d.user_id=h.user_id
  join public.profiles p on p.id=h.user_id
  where h.user_id=v_user
    and h.host_status='active'
    and a.status='approved'
    and d.document_type='video_selfie'
    and d.status='approved'
    and p.account_status='active'
    and p.age>=18
 ) then
  raise exception 'Approved active host verification required';
 end if;

 select * into v_existing
 from public.hearttalk_cashfree_payout_requests
 where host_id=v_user and idempotency_key=p_idempotency_key;
 if found then
  return jsonb_build_object('request_id',v_existing.id,'amount_paise',v_existing.amount_paise,'status',v_existing.status,'reused',true);
 end if;

 if p_amount_paise is null or p_amount_paise<50000 then raise exception 'Minimum withdrawal is ₹500'; end if;
 if p_payout_method is null or p_payout_method not in ('upi','bank') then raise exception 'Unsupported payout method'; end if;
 if p_account_holder_name is null or char_length(trim(p_account_holder_name)) not between 2 and 100 then
  raise exception 'Enter account holder name';
 end if;

 if p_payout_method='upi' then
  if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]{2,256}@[a-z][a-z0-9]{1,20}$' then
   raise exception 'Enter a valid UPI ID';
  end if;
  if p_bank_account_number is not null or p_bank_ifsc is not null then
   raise exception 'Invalid UPI destination data';
  end if;
 else
  if p_upi_id is not null
    or p_bank_account_number is null
    or char_length(trim(p_bank_account_number)) not between 6 and 34
    or p_bank_ifsc is null
    or p_bank_ifsc !~* '^[A-Z]{4}0[A-Z0-9]{6}$' then
   raise exception 'Enter valid bank account and IFSC details';
  end if;
 end if;

 if exists (
  select 1 from public.hearttalk_cashfree_payout_requests
  where host_id=v_user and status in ('pending','approved','processing')
 ) then
  raise exception 'You already have an open Cashfree payout request';
 end if;

 -- Protect the shared cash ledger from overlapping legacy/manual withdrawals.
 if exists (
  select 1 from public.hearttalk_host_payout_requests
  where host_id=v_user and status in ('pending','approved')
 ) then
  raise exception 'You already have an open manual UPI withdrawal request';
 end if;

 select coalesce(sum(amount_paise),0) into v_available
 from public.hearttalk_host_cash_ledger where host_id=v_user;
 if v_available<p_amount_paise then raise exception 'Insufficient available earnings'; end if;

 insert into public.hearttalk_cashfree_payout_requests
 (host_id,amount_paise,payout_method,upi_id,account_holder_name,bank_account_number,bank_ifsc,idempotency_key)
 values(
  v_user,p_amount_paise,p_payout_method,
  case when p_payout_method='upi' then trim(p_upi_id) else null end,
  trim(p_account_holder_name),
  case when p_payout_method='bank' then trim(p_bank_account_number) else null end,
  case when p_payout_method='bank' then upper(trim(p_bank_ifsc)) else null end,
  p_idempotency_key
 ) returning id into v_request_id;

 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v_user,-p_amount_paise,'withdrawal_hold',v_request_id,'Reserved for Cashfree payout request',v_user);

 return jsonb_build_object('request_id',v_request_id,'amount_paise',p_amount_paise,'status','pending','reused',false);
end;
$$;
revoke all on function public.hearttalk_request_cashfree_payout(bigint,text,text,text,text,text,uuid) from public,anon;
grant execute on function public.hearttalk_request_cashfree_payout(bigint,text,text,text,text,text,uuid) to authenticated;

create or replace function public.hearttalk_request_manual_upi_withdrawal(
 p_amount_paise bigint,
 p_upi_id text,
 p_account_holder_name text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_available bigint;
 v_id uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if not exists(
  select 1
  from public.hosts h
  join public.host_applications a on a.user_id=h.user_id
  join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'
  where h.user_id=v_user and h.host_status='active' and a.status='approved'
 ) then
  raise exception 'Host verification is required before withdrawal';
 end if;
 if p_amount_paise is null or p_amount_paise<50000 then raise exception 'Minimum withdrawal is ₹500'; end if;
 if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]{2,256}@[a-z][a-z0-9]{1,20}$' then
  raise exception 'Enter a valid UPI ID';
 end if;
 if p_account_holder_name is null or char_length(trim(p_account_holder_name)) not between 2 and 100 then
  raise exception 'Enter account holder name';
 end if;

 perform 1 from auth.users where id=v_user for update;

 if exists(
  select 1 from public.hearttalk_host_payout_requests
  where host_id=v_user and status in ('pending','approved')
 ) then
  raise exception 'You already have an open withdrawal request';
 end if;

 -- Do not allow the legacy workflow to reserve cash already held by a Cashfree request.
 if exists(
  select 1 from public.hearttalk_cashfree_payout_requests
  where host_id=v_user and status in ('pending','approved','processing')
 ) then
  raise exception 'You already have an open Cashfree payout request';
 end if;

 select coalesce(sum(amount_paise),0) into v_available
 from public.hearttalk_host_cash_ledger where host_id=v_user;
 if v_available<p_amount_paise then raise exception 'Insufficient available earnings'; end if;

 insert into public.hearttalk_host_payout_requests(host_id,amount_paise,upi_id,account_holder_name)
 values(v_user,p_amount_paise,trim(p_upi_id),trim(p_account_holder_name))
 returning id into v_id;

 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v_user,-p_amount_paise,'withdrawal_hold',v_id,'Reserved for manual UPI withdrawal',v_user);

 return jsonb_build_object('request_id',v_id,'amount_paise',p_amount_paise,'status','pending');
end;
$$;
revoke all on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) from public,anon;
grant execute on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) to authenticated;
