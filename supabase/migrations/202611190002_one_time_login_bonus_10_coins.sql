-- HeartTalk: one-time 10-coin first-login bonus, enforced by the database.
begin;
alter table public.wallet_ledger drop constraint if exists wallet_ledger_entry_type_check;
alter table public.wallet_ledger add constraint wallet_ledger_entry_type_check
  check (entry_type in ('purchase','spend','refund','admin_adjustment','login_bonus'));
create unique index if not exists wallet_ledger_one_login_bonus_per_user
  on public.wallet_ledger(user_id) where entry_type='login_bonus';
create or replace function public.hearttalk_claim_login_bonus()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_rows integer := 0;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  insert into public.wallet_ledger(user_id, amount, entry_type, reference_id)
  values (v_user, 10, 'login_bonus', 'first-login')
  on conflict (user_id) where entry_type='login_bonus' do nothing;
  get diagnostics v_rows = row_count;
  return case when v_rows=1 then 10 else 0 end;
end;
$$;
revoke all on function public.hearttalk_claim_login_bonus() from public, anon;
grant execute on function public.hearttalk_claim_login_bonus() to authenticated;
commit;
