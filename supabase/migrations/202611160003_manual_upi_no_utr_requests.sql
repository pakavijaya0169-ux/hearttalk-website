-- HeartTalk: customer-friendly manual UPI recharge without UTR entry.
-- Customers submit a pending request after returning from their UPI app.
-- Admins must verify the exact bank credit before approving coins.
alter table public.hearttalk_manual_upi_recharges
  alter column utr drop not null;

create or replace function public.hearttalk_submit_manual_upi_recharge_request(p_package_code text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid := auth.uid();
  v_package public.coin_packages%rowtype;
  v_id uuid;
begin
  if v_user is null then
    raise exception 'Please log in first';
  end if;
  if p_package_code is null or char_length(trim(p_package_code)) not between 2 and 40 then
    raise exception 'Select a valid coin package';
  end if;

  select * into v_package
  from public.coin_packages
  where package_code = trim(p_package_code) and active = true;

  if not found then
    raise exception 'This coin package is unavailable';
  end if;

  insert into public.hearttalk_manual_upi_recharges
    (user_id, package_code, package_title, amount_paise, coins, paid_coins, bonus_coins, utr)
  values
    (v_user, v_package.package_code, v_package.title, v_package.amount_paise,
     v_package.coins, v_package.paid_coins, v_package.bonus_coins, null)
  returning id into v_id;

  return jsonb_build_object(
    'request_id', v_id,
    'status', 'pending',
    'amount_paise', v_package.amount_paise,
    'coins', v_package.coins,
    'paid_coins', v_package.paid_coins,
    'bonus_coins', v_package.bonus_coins
  );
end;
$$;

revoke all on function public.hearttalk_submit_manual_upi_recharge_request(text) from public, anon;
grant execute on function public.hearttalk_submit_manual_upi_recharge_request(text) to authenticated;
