-- HeartTalk Cashfree Payouts foundation.
-- This migration adds a Cashfree-only withdrawal workflow and safely reserves earnings.
-- It does not delete legacy payout records; removal/disablement is a later migration.

create table if not exists public.hearttalk_cashfree_payout_requests (
 id uuid primary key default gen_random_uuid(),
 host_id uuid not null references auth.users(id) on delete restrict,
 amount_paise bigint not null check(amount_paise >= 50000),
 payout_method text not null check(payout_method in ('upi','bank')),
 upi_id text,
 account_holder_name text not null check(char_length(trim(account_holder_name)) between 2 and 100),
 bank_account_number text,
 bank_ifsc text,
 status text not null default 'pending' check(status in ('pending','approved','processing','paid','failed','rejected','cancelled')),
 cashfree_transfer_id text,
 cashfree_reference_id text,
 cashfree_beneficiary_id text,
 cashfree_status text,
 idempotency_key uuid not null,
 admin_note text not null default '',
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 paid_at timestamptz,
 failed_at timestamptz,
 failure_reason text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint ht_cf_payout_destination_check check (
  (payout_method='upi' and upi_id is not null and char_length(trim(upi_id)) between 5 and 120
    and bank_account_number is null and bank_ifsc is null)
  or
  (payout_method='bank' and upi_id is null and bank_account_number is not null
    and char_length(trim(bank_account_number)) between 6 and 34
    and bank_ifsc is not null and bank_ifsc ~* '^[A-Z]{4}0[A-Z0-9]{6}$')
 ),
 unique(host_id,idempotency_key),
 unique(cashfree_transfer_id)
);
create index if not exists ht_cf_payout_status_created_idx
 on public.hearttalk_cashfree_payout_requests(status,created_at desc);
create index if not exists ht_cf_payout_host_created_idx
 on public.hearttalk_cashfree_payout_requests(host_id,created_at desc);
alter table public.hearttalk_cashfree_payout_requests enable row level security;
revoke all on public.hearttalk_cashfree_payout_requests from public,anon,authenticated;
grant select on public.hearttalk_cashfree_payout_requests to authenticated;
drop policy if exists "Hosts view own Cashfree payouts" on public.hearttalk_cashfree_payout_requests;
create policy "Hosts view own Cashfree payouts" on public.hearttalk_cashfree_payout_requests
 for select to authenticated using(host_id=auth.uid());

-- Request and reserve in one transaction. Ledger holds make concurrent requests safe.
create or replace function public.hearttalk_request_cashfree_payout(
 p_amount_paise bigint,
 p_payout_method text,
 p_upi_id text,
 p_account_holder_name text,
 p_bank_account_number text,
 p_bank_ifsc text,
 p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid();
 v_available bigint;
 v_request_id uuid;
 v_existing public.hearttalk_cashfree_payout_requests%rowtype;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_idempotency_key is null then raise exception 'Idempotency key required'; end if;
 select * into v_existing from public.hearttalk_cashfree_payout_requests
 where host_id=v_user and idempotency_key=p_idempotency_key;
 if found then
  return jsonb_build_object('request_id',v_existing.id,'amount_paise',v_existing.amount_paise,'status',v_existing.status,'reused',true);
 end if;
 if p_amount_paise is null or p_amount_paise<50000 then raise exception 'Minimum withdrawal is ₹500'; end if;
 if p_payout_method not in ('upi','bank') then raise exception 'Unsupported payout method'; end if;
 if p_account_holder_name is null or char_length(trim(p_account_holder_name)) not between 2 and 100 then raise exception 'Enter account holder name'; end if;
 if p_payout_method='upi' then
  if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]{2,256}@[a-z][a-z0-9]{1,20}$' then raise exception 'Enter a valid UPI ID'; end if;
  if p_bank_account_number is not null or p_bank_ifsc is not null then raise exception 'Invalid UPI destination data'; end if;
 else
  if p_upi_id is not null or p_bank_account_number is null or char_length(trim(p_bank_account_number)) not between 6 and 34
   or p_bank_ifsc is null or p_bank_ifsc !~* '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Enter valid bank account and IFSC details'; end if;
 end if;
 -- Serialize requests for this host by locking their auth user row.
 perform 1 from auth.users where id=v_user for update;
 if exists(select 1 from public.hearttalk_cashfree_payout_requests
           where host_id=v_user and status in ('pending','approved','processing')) then
  raise exception 'You already have an open Cashfree payout request';
 end if;
 select coalesce(sum(amount_paise),0) into v_available
 from public.hearttalk_host_cash_ledger where host_id=v_user;
 if v_available<p_amount_paise then raise exception 'Insufficient available earnings'; end if;
 insert into public.hearttalk_cashfree_payout_requests
 (host_id,amount_paise,payout_method,upi_id,account_holder_name,bank_account_number,bank_ifsc,idempotency_key)
 values(v_user,p_amount_paise,p_payout_method,
  case when p_payout_method='upi' then trim(p_upi_id) else null end,
  trim(p_account_holder_name),
  case when p_payout_method='bank' then trim(p_bank_account_number) else null end,
  case when p_payout_method='bank' then upper(trim(p_bank_ifsc)) else null end,
  p_idempotency_key)
 returning id into v_request_id;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v_user,-p_amount_paise,'withdrawal_hold',v_request_id,'Reserved for Cashfree payout request',v_user);
 return jsonb_build_object('request_id',v_request_id,'amount_paise',p_amount_paise,'status','pending','reused',false);
end; $$;
revoke all on function public.hearttalk_request_cashfree_payout(bigint,text,text,text,text,text,uuid) from public,anon;
grant execute on function public.hearttalk_request_cashfree_payout(bigint,text,text,text,text,text,uuid) to authenticated;

create or replace function public.hearttalk_get_cashfree_payouts()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_balance bigint; v_rows jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select coalesce(sum(amount_paise),0) into v_balance from public.hearttalk_host_cash_ledger where host_id=v_user;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (select id,amount_paise,payout_method,status,cashfree_status,admin_note,created_at,updated_at,paid_at,failure_reason
       from public.hearttalk_cashfree_payout_requests where host_id=v_user order by created_at desc limit 30) q;
 return jsonb_build_object('available_amount_paise',v_balance,'minimum_amount_paise',50000,'requests',v_rows);
end; $$;
revoke all on function public.hearttalk_get_cashfree_payouts() from public,anon;
grant execute on function public.hearttalk_get_cashfree_payouts() to authenticated;

-- Admin can review requests. Initiating the actual Cashfree transfer is handled by
-- a privileged Edge Function in a later step; no manual "paid" RPC exists here.
create or replace function public.admin_list_cashfree_payout_requests(p_status text default 'all')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('all','pending','approved','processing','paid','failed','rejected','cancelled') then raise exception 'Invalid status filter'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (select r.id,r.host_id,r.amount_paise,r.payout_method,r.upi_id,r.account_holder_name,
       r.bank_account_number,r.bank_ifsc,r.status,r.cashfree_transfer_id,r.cashfree_reference_id,
       r.cashfree_status,r.admin_note,r.created_at,r.reviewed_at,r.paid_at,r.failure_reason,
       coalesce(u.raw_user_meta_data->>'display_name',u.raw_user_meta_data->>'username',u.email,'HeartTalk Host') as host_name
       from public.hearttalk_cashfree_payout_requests r left join auth.users u on u.id=r.host_id
       where p_status='all' or r.status=p_status limit 500) q;
 return v_rows;
end; $$;
revoke all on function public.admin_list_cashfree_payout_requests(text) from public,anon;
grant execute on function public.admin_list_cashfree_payout_requests(text) to authenticated;

create or replace function public.admin_approve_cashfree_payout_request(p_request_id uuid,p_admin_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_cashfree_payout_requests%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select * into v from public.hearttalk_cashfree_payout_requests where id=p_request_id for update;
 if not found or v.status<>'pending' then raise exception 'Pending Cashfree payout request not found'; end if;
 update public.hearttalk_cashfree_payout_requests
 set status='approved',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
 where id=p_request_id and status='pending';
 if not found then raise exception 'Request changed before approval'; end if;
 return jsonb_build_object('request_id',p_request_id,'status','approved');
end; $$;
revoke all on function public.admin_approve_cashfree_payout_request(uuid,text) from public,anon;
grant execute on function public.admin_approve_cashfree_payout_request(uuid,text) to authenticated;
