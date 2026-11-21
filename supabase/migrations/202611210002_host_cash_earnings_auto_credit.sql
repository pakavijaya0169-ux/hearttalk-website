-- Automatically convert newly recorded Host gift/chat coin earnings into cash-ledger
-- credits using the approved conversion: 1 Host earning coin = 50 paise.
-- Historical rows are intentionally NOT backfilled here to avoid double-crediting
-- balances that may already have been manually reconciled by Admin.

create or replace function public.hearttalk_credit_host_cash_from_gift_earning()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.earned_coins > 0 then
    insert into public.hearttalk_host_cash_ledger
      (host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
    values
      (new.host_id,new.earned_coins::bigint*50,'earning_credit',new.gift_event_id,
       'gift:'||new.gift_event_id::text,'Gift earnings converted at ₹0.50 per Host coin',null)
    on conflict (host_id,source_reference) do nothing;
  end if;
  return new;
end; $$;
revoke all on function public.hearttalk_credit_host_cash_from_gift_earning() from public,anon,authenticated;
drop trigger if exists hearttalk_host_cash_credit_gift on public.hearttalk_host_earnings;
create trigger hearttalk_host_cash_credit_gift
after insert on public.hearttalk_host_earnings
for each row execute function public.hearttalk_credit_host_cash_from_gift_earning();

create or replace function public.hearttalk_credit_host_cash_from_chat_earning()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.earned_coins > 0 then
    insert into public.hearttalk_host_cash_ledger
      (host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
    values
      (new.host_id,new.earned_coins::bigint*50,'earning_credit',new.session_id,
       'chat:'||new.session_id::text,'Chat earnings converted at ₹0.50 per Host coin',null)
    on conflict (host_id,source_reference) do nothing;
  end if;
  return new;
end; $$;
revoke all on function public.hearttalk_credit_host_cash_from_chat_earning() from public,anon,authenticated;
drop trigger if exists hearttalk_host_cash_credit_chat on public.hearttalk_chat_session_earnings;
create trigger hearttalk_host_cash_credit_chat
after insert on public.hearttalk_chat_session_earnings
for each row execute function public.hearttalk_credit_host_cash_from_chat_earning();
