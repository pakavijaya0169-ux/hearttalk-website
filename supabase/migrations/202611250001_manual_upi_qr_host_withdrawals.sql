-- Host manual UPI QR withdrawal flow.
-- Requests continue to reserve eligible host cash earnings at creation time.
-- QR is a fixed-amount UPI payment intent; final payment is recorded only by an admin with a unique UTR.

create or replace function public.hearttalk_get_manual_upi_withdrawals()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid := auth.uid();
  v_balance bigint;
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(sum(amount_paise), 0)
    into v_balance
  from public.hearttalk_host_cash_ledger
  where host_id = v_user;

  select coalesce(
    jsonb_agg(to_jsonb(q) order by q.created_at desc),
    '[]'::jsonb
  )
    into v_rows
  from (
    select id, amount_paise, upi_id, account_holder_name, status,
           utr, admin_note, created_at, updated_at, paid_at
    from public.hearttalk_host_payout_requests
    where host_id = v_user
    order by created_at desc
    limit 30
  ) q;

  return jsonb_build_object(
    'available_amount_paise', v_balance,
    'minimum_amount_paise', 50000,
    'requests', v_rows
  );
end;
$$;

revoke all on function public.hearttalk_get_manual_upi_withdrawals() from public, anon;
grant execute on function public.hearttalk_get_manual_upi_withdrawals() to authenticated;

-- Keep the QR reference deterministic and unique per withdrawal request.
create unique index if not exists hearttalk_host_payout_qr_reference_unique
on public.hearttalk_host_payout_requests (id);
