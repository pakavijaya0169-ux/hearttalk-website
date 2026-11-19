-- HeartTalk Step 2.1 login bonus deployment verification (read-only).
-- Run after applying 202611190002_login_bonus_10_coins.sql.
do $$
begin
  if to_regprocedure('public.hearttalk_claim_login_bonus()') is null then
    raise exception 'Missing login bonus RPC';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname='public'
      and indexname='wallet_ledger_one_login_bonus_per_user'
  ) then
    raise exception 'Missing one-login-bonus-per-user unique index';
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.wallet_ledger'::regclass
      and conname='wallet_ledger_entry_type_check'
      and pg_get_constraintdef(oid) like '%login_bonus%'
  ) then
    raise exception 'wallet_ledger entry_type constraint does not allow login_bonus';
  end if;
  if has_function_privilege('anon','public.hearttalk_claim_login_bonus()','EXECUTE') then
    raise exception 'Anonymous users must not execute the login bonus RPC';
  end if;
  if not has_function_privilege('authenticated','public.hearttalk_claim_login_bonus()','EXECUTE') then
    raise exception 'Authenticated users must be able to execute the login bonus RPC';
  end if;
end $$;

select 'login_bonus_migration_verified' as result,
       (select count(*) from public.wallet_ledger where entry_type='login_bonus') as credited_users;
