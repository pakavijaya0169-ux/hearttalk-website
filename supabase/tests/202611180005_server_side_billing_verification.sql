-- HeartTalk billing deployment verification (read-only).
-- Run only after applying 202611180005_server_side_chat_call_host_billing.sql.
do $$
begin
  if to_regprocedure('public.hearttalk_is_approved_female_host(uuid)') is null then
    raise exception 'Missing approved Host eligibility function';
  end if;
  if to_regprocedure('public.hearttalk_send_chat_message(uuid,text)') is null then
    raise exception 'Missing metered chat RPC';
  end if;
  if to_regclass('public.hearttalk_call_settlements') is null then
    raise exception 'Missing call settlement table';
  end if;
  if to_regclass('public.hearttalk_chat_billing_state') is null then
    raise exception 'Missing chat billing state table';
  end if;
  if not exists (
    select 1 from pg_trigger
    where tgname='hearttalk_call_funds_before_accept'
      and not tgisinternal
  ) then raise exception 'Missing call funds validation trigger'; end if;
  if not exists (
    select 1 from pg_trigger
    where tgname='hearttalk_call_settle_after_end'
      and not tgisinternal
  ) then raise exception 'Missing call settlement trigger'; end if;
  if has_table_privilege('authenticated','public.messages','INSERT') then
    raise exception 'Direct message inserts are still allowed; metering can be bypassed';
  end if;
  if coalesce((select requests_enabled from public.hearttalk_payout_settings where id=true),true) then
    raise exception 'Withdrawals must remain disabled until compliance approval';
  end if;
end $$;

select
  'billing_migration_verified' as result,
  (select count(*) from public.hearttalk_call_settlements) as settled_calls,
  (select count(*) from public.hearttalk_chat_billing_state) as active_chat_billing_pairs,
  (select count(*) from public.hearttalk_host_cash_ledger where entry_type='earning_credit') as host_earning_credits,
  (select requests_enabled from public.hearttalk_payout_settings where id=true) as withdrawals_enabled;
