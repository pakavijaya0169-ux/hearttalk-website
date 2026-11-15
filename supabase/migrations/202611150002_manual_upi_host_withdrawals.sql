-- HeartTalk manual UPI host withdrawals.
-- Payouts are manual only. No payment-provider API or automatic bank transfer is invoked.
-- INR earnings must be credited by an admin only after reconciling eligible, paid-coin gift earnings.
create table if not exists public.hearttalk_host_cash_ledger (
 id uuid primary key default gen_random_uuid(),
 host_id uuid not null references auth.users(id) on delete restrict,
 amount_paise bigint not null check(amount_paise<>0),
 entry_type text not null check(entry_type in ('earning_credit','withdrawal_hold','withdrawal_release','withdrawal_paid','admin_adjustment')),
 reference_id uuid,
 source_reference text,
 note text not null default '',
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(host_id,source_reference)
);
create index if not exists hearttalk_host_cash_ledger_host_idx on public.hearttalk_host_cash_ledger(host_id,created_at desc);
alter table public.hearttalk_host_cash_ledger enable row level security;
revoke all on public.hearttalk_host_cash_ledger from anon,authenticated,public;
grant select on public.hearttalk_host_cash_ledger to authenticated;
drop policy if exists "Hosts view own cash ledger" on public.hearttalk_host_cash_ledger;
create policy "Hosts view own cash ledger" on public.hearttalk_host_cash_ledger
for select to authenticated using(host_id=auth.uid());

create table if not exists public.hearttalk_host_payout_requests (
 id uuid primary key default gen_random_uuid(),
 host_id uuid not null references auth.users(id) on delete restrict,
 amount_paise bigint not null check(amount_paise>=50000),
 upi_id text not null check(char_length(upi_id) between 5 and 120),
 account_holder_name text not null check(char_length(trim(account_holder_name)) between 2 and 100),
 status text not null default 'pending' check(status in ('pending','approved','paid','rejected')),
 utr text,
 admin_note text not null default '',
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 paid_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists hearttalk_host_payout_requests_status_idx on public.hearttalk_host_payout_requests(status,created_at desc);
create index if not exists hearttalk_host_payout_requests_host_idx on public.hearttalk_host_payout_requests(host_id,created_at desc);
alter table public.hearttalk_host_payout_requests enable row level security;
revoke all on public.hearttalk_host_payout_requests from anon,authenticated,public;
grant select on public.hearttalk_host_payout_requests to authenticated;
drop policy if exists "Hosts view own payout requests" on public.hearttalk_host_payout_requests;
create policy "Hosts view own payout requests" on public.hearttalk_host_payout_requests
for select to authenticated using(host_id=auth.uid());

create or replace function public.hearttalk_request_manual_upi_withdrawal(
 p_amount_paise bigint,p_upi_id text,p_account_holder_name text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_available bigint; v_id uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_amount_paise is null or p_amount_paise<50000 then raise exception 'Minimum withdrawal is ₹500'; end if;
 if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]{2,256}@[a-z][a-z0-9]{1,20}$' then raise exception 'Enter a valid UPI ID'; end if;
 if p_account_holder_name is null or char_length(trim(p_account_holder_name)) not between 2 and 100 then raise exception 'Enter account holder name'; end if;
 perform 1 from auth.users where id=v_user for update;
 select coalesce(sum(amount_paise),0) into v_available from public.hearttalk_host_cash_ledger where host_id=v_user;
 if exists(select 1 from public.hearttalk_host_payout_requests where host_id=v_user and status in ('pending','approved')) then
   raise exception 'You already have an open withdrawal request';
 end if;
 if v_available<p_amount_paise then raise exception 'Insufficient available earnings'; end if;
 insert into public.hearttalk_host_payout_requests(host_id,amount_paise,upi_id,account_holder_name)
 values(v_user,p_amount_paise,trim(p_upi_id),trim(p_account_holder_name)) returning id into v_id;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v_user,-p_amount_paise,'withdrawal_hold',v_id,'Reserved for manual UPI withdrawal',v_user);
 return jsonb_build_object('request_id',v_id,'amount_paise',p_amount_paise,'status','pending');
end; $$;
revoke all on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) from public,anon;
grant execute on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) to authenticated;

create or replace function public.hearttalk_get_manual_upi_withdrawals()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_balance bigint; v_rows jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select coalesce(sum(amount_paise),0) into v_balance from public.hearttalk_host_cash_ledger where host_id=v_user;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (select id,amount_paise,status,utr,admin_note,created_at,updated_at from public.hearttalk_host_payout_requests where host_id=v_user order by created_at desc limit 30) q;
 return jsonb_build_object('available_amount_paise',v_balance,'minimum_amount_paise',50000,'requests',v_rows);
end; $$;
revoke all on function public.hearttalk_get_manual_upi_withdrawals() from public,anon;
grant execute on function public.hearttalk_get_manual_upi_withdrawals() to authenticated;

create or replace function public.admin_credit_host_cash_earnings(
 p_host_id uuid,p_amount_paise bigint,p_source_reference text,p_note text default ''
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_host_id is null or p_amount_paise is null or p_amount_paise<1 or p_source_reference is null or char_length(trim(p_source_reference)) not between 4 and 160 then raise exception 'Invalid earnings credit'; end if;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,source_reference,note,created_by)
 values(p_host_id,p_amount_paise,'earning_credit',trim(p_source_reference),coalesce(p_note,''),auth.uid())
 returning id into v_id;
 return v_id;
end; $$;
revoke all on function public.admin_credit_host_cash_earnings(uuid,bigint,text,text) from public,anon;
grant execute on function public.admin_credit_host_cash_earnings(uuid,bigint,text,text) to authenticated;

create or replace function public.admin_list_host_payout_requests(p_status text default 'all')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
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
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 update public.hearttalk_host_payout_requests set status='approved',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
 where id=p_request_id and status='pending';
 if not found then raise exception 'Pending request not found'; end if;
 return true;
end; $$;
revoke all on function public.admin_approve_host_payout(uuid,text) from public,anon;
grant execute on function public.admin_approve_host_payout(uuid,text) to authenticated;

create or replace function public.admin_mark_host_payout_paid(p_request_id uuid,p_utr text,p_admin_note text default '')
returns boolean language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_host_payout_requests%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_utr is null or char_length(trim(p_utr)) not between 6 and 100 then raise exception 'Enter valid UTR / UPI reference ID'; end if;
 select * into v from public.hearttalk_host_payout_requests where id=p_request_id for update;
 if not found or v.status not in ('pending','approved') then raise exception 'Request is not payable'; end if;
 update public.hearttalk_host_payout_requests set status='paid',utr=trim(p_utr),admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),paid_at=now(),updated_at=now() where id=p_request_id;
 return true;
end; $$;
revoke all on function public.admin_mark_host_payout_paid(uuid,text,text) from public,anon;
grant execute on function public.admin_mark_host_payout_paid(uuid,text,text) to authenticated;

create or replace function public.admin_reject_host_payout(p_request_id uuid,p_admin_note text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_host_payout_requests%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select * into v from public.hearttalk_host_payout_requests where id=p_request_id for update;
 if not found or v.status not in ('pending','approved') then raise exception 'Request cannot be rejected'; end if;
 update public.hearttalk_host_payout_requests set status='rejected',admin_note=coalesce(p_admin_note,'Request rejected'),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=p_request_id;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v.host_id,v.amount_paise,'withdrawal_release',v.id,'Reserved funds released after rejection',auth.uid());
 return true;
end; $$;
revoke all on function public.admin_reject_host_payout(uuid,text) from public,anon;
grant execute on function public.admin_reject_host_payout(uuid,text) to authenticated;
