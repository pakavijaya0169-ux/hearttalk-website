-- HeartTalk Cashfree Test Mode payment support.
-- Cashfree credentials are stored only as Supabase Edge Function secrets.
-- This migration keeps the existing Razorpay/manual-UPI flows intact.

create or replace function public.credit_verified_cashfree_coin_purchase(
  p_provider_order_id text,
  p_provider_payment_id text,
  p_amount_paise bigint,
  p_currency text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_order public.payment_orders%rowtype;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted payment service required';
  end if;

  select * into v_order
  from public.payment_orders
  where provider_order_id = p_provider_order_id
    and provider = 'cashfree'
  for update;

  if not found then
    raise exception 'Cashfree payment order not found';
  end if;

  if v_order.status = 'paid' and v_order.provider_payment_id = p_provider_payment_id then
    return jsonb_build_object('status', 'already_credited', 'coins', v_order.coins);
  end if;

  if v_order.status <> 'created' then
    raise exception 'Payment order is not payable';
  end if;

  if v_order.amount_paise <> p_amount_paise or v_order.currency <> p_currency then
    raise exception 'Payment amount or currency mismatch';
  end if;

  insert into public.payment_transactions(
    user_id, provider, provider_transaction_id, amount_paise, currency, status
  ) values (
    v_order.user_id, 'cashfree', p_provider_payment_id, p_amount_paise, p_currency, 'succeeded'
  );

  insert into public.wallet_ledger(user_id, amount, entry_type, reference_id)
  values(v_order.user_id, v_order.coins, 'purchase', 'cashfree:' || p_provider_payment_id);

  update public.payment_orders
  set status = 'paid',
      provider_payment_id = p_provider_payment_id,
      paid_at = now()
  where id = v_order.id;

  return jsonb_build_object('status', 'credited', 'coins', v_order.coins);
end;
$$;

revoke all on function public.credit_verified_cashfree_coin_purchase(text, text, bigint, text)
  from public, anon, authenticated;
grant execute on function public.credit_verified_cashfree_coin_purchase(text, text, bigint, text)
  to service_role;
