-- HeartTalk Step 2.1: idempotent one-time 10 coin login bonus.
-- This migration adds a ledger guard and an authenticated RPC. Frontend must call
-- hearttalk_claim_login_bonus() after successful sign-in.
begin;

-- Allow the new ledger entry type (the base schema only permits purchase/spend/refund/admin_adjustment).
alter table public.wallet_ledger drop constraint if exists wallet_ledger_entry_type_check;
alter table public.wallet_ledger
  add constraint wallet_ledger_entry_type_check
  check (entry_type in ('purchase','spend','refund','admin_adjustment','login_bonus'));

create unique index if not exists wallet_ledger_one_login_bonus_per_user
  on public.wallet_ledger(user_id)
  where entry_type = 'login_bonus';

create or replace function public.hearttalk_claim_login_bonus()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_inserted integer;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  insert into public.wallet_ledger(user_id, amount, entry_type, reference_id)
  values (v_user, 10, 'login_bonus', 'welcome_bonus_10')
  on conflict (user_id) where entry_type = 'login_bonus' do nothing;

  get diagnostics v_inserted = row_count;

  return jsonb_build_object(
    'success', true,
    'credited', (v_inserted = 1),
    'bonus_coins', case when v_inserted = 1 then 10 else 0 end,
    'message', case when v_inserted = 1 then '10 coins credited' else 'Login bonus already claimed' end
  );
end;
$$;

revoke all on function public.hearttalk_claim_login_bonus() from public, anon;
grant execute on function public.hearttalk_claim_login_bonus() to authenticated;

commit;
