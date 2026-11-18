-- HeartTalk final user-confirmed pricing configuration.
-- Chat/call rates are stored here; charging must be wired to server-side
-- message/call metering before these services can collect coins.
-- Bonus coins are eligible for the same 50:50 host/platform revenue split.

create table if not exists public.hearttalk_pricing_settings (
  id boolean primary key default true check (id),
  video_coins_per_minute integer not null check (video_coins_per_minute > 0),
  voice_coins_per_minute integer not null check (voice_coins_per_minute > 0),
  chat_coins_per_block integer not null check (chat_coins_per_block > 0),
  chat_block_minutes integer not null check (chat_block_minutes > 0),
  host_share_bps integer not null check (host_share_bps between 0 and 10000),
  platform_share_bps integer not null check (platform_share_bps between 0 and 10000),
  bonus_coins_earn_cash boolean not null default true,
  minimum_withdrawal_paise bigint not null check (minimum_withdrawal_paise > 0),
  withdrawal_cadence text not null check (withdrawal_cadence in ('weekly')),
  admin_approval_required boolean not null default true,
  updated_at timestamptz not null default now(),
  check (host_share_bps + platform_share_bps = 10000)
);

insert into public.hearttalk_pricing_settings (
  id, video_coins_per_minute, voice_coins_per_minute,
  chat_coins_per_block, chat_block_minutes,
  host_share_bps, platform_share_bps, bonus_coins_earn_cash,
  minimum_withdrawal_paise, withdrawal_cadence, admin_approval_required
) values (
  true, 2, 1, 4, 5, 5000, 5000, true, 50000, 'weekly', true
)
on conflict (id) do update set
  video_coins_per_minute = excluded.video_coins_per_minute,
  voice_coins_per_minute = excluded.voice_coins_per_minute,
  chat_coins_per_block = excluded.chat_coins_per_block,
  chat_block_minutes = excluded.chat_block_minutes,
  host_share_bps = excluded.host_share_bps,
  platform_share_bps = excluded.platform_share_bps,
  bonus_coins_earn_cash = excluded.bonus_coins_earn_cash,
  minimum_withdrawal_paise = excluded.minimum_withdrawal_paise,
  withdrawal_cadence = excluded.withdrawal_cadence,
  admin_approval_required = excluded.admin_approval_required,
  updated_at = now();

alter table public.hearttalk_pricing_settings enable row level security;
revoke all on public.hearttalk_pricing_settings from anon, authenticated, public;
grant select on public.hearttalk_pricing_settings to authenticated;
drop policy if exists "Signed-in users can read HeartTalk pricing" on public.hearttalk_pricing_settings;
create policy "Signed-in users can read HeartTalk pricing"
  on public.hearttalk_pricing_settings for select to authenticated using (true);

create or replace function public.hearttalk_get_pricing_settings()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'video_coins_per_minute', video_coins_per_minute,
    'voice_coins_per_minute', voice_coins_per_minute,
    'chat_coins_per_block', chat_coins_per_block,
    'chat_block_minutes', chat_block_minutes,
    'host_share_bps', host_share_bps,
    'platform_share_bps', platform_share_bps,
    'bonus_coins_earn_cash', bonus_coins_earn_cash,
    'minimum_withdrawal_paise', minimum_withdrawal_paise,
    'withdrawal_cadence', withdrawal_cadence,
    'admin_approval_required', admin_approval_required
  )
  from public.hearttalk_pricing_settings where id = true;
$$;
revoke all on function public.hearttalk_get_pricing_settings() from public, anon;
grant execute on function public.hearttalk_get_pricing_settings() to authenticated;

-- A 50:50 gift split. The existing wallet balance treats paid and bonus coins
-- as spendable coins; per the confirmed rule, both coin types earn host cash.
create or replace function public.hearttalk_send_gift(target_host_id uuid, selected_gift_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sender uuid := auth.uid();
  v_price integer;
  v_host_share integer;
  v_platform_share integer;
  v_balance bigint;
  v_event uuid;
begin
  if v_sender is null then raise exception 'Please log in first'; end if;
  if target_host_id is null or target_host_id = v_sender then
    raise exception 'Choose another member';
  end if;

  select coin_price into v_price
  from public.hearttalk_gift_catalog
  where gift_code = selected_gift_code and active = true;
  if v_price is null then raise exception 'Gift is unavailable'; end if;

  perform 1 from auth.users where id = v_sender for update;
  select coalesce(sum(amount), 0) into v_balance
  from public.wallet_ledger where user_id = v_sender;
  if v_balance < v_price then
    raise exception 'Not enough coins. Please add coins to your wallet.';
  end if;

  v_host_share := floor(v_price * 0.50)::integer;
  v_platform_share := v_price - v_host_share;

  insert into public.wallet_ledger(user_id, amount, entry_type, reference_id)
  values(v_sender, -v_price, 'spend', 'gift:' || selected_gift_code);

  insert into public.hearttalk_gift_events(
    sender_id, host_id, gift_code, coin_price, host_share_coins, platform_share_coins
  ) values (
    v_sender, target_host_id, selected_gift_code, v_price, v_host_share, v_platform_share
  ) returning id into v_event;

  insert into public.hearttalk_host_earnings(host_id, gift_event_id, earned_coins)
  values(target_host_id, v_event, v_host_share);

  return jsonb_build_object(
    'gift_event_id', v_event,
    'coin_price', v_price,
    'host_earned_coins', v_host_share,
    'host_earned_amount_paise', v_host_share * 100,
    'platform_share_coins', v_platform_share,
    'status', 'recorded'
  );
end;
$$;
revoke all on function public.hearttalk_send_gift(uuid, text) from public;
grant execute on function public.hearttalk_send_gift(uuid, text) to authenticated;

-- One earned host coin represents ₹1 after the 50:50 split has already been
-- applied to the user's coin spend. Keep withdrawals disabled pending compliance.
update public.hearttalk_payout_settings
set paise_per_host_coin = 100,
    requests_enabled = false,
    updated_at = now()
where id = true;

-- NOTE: This migration does not yet deduct coins for live calls or chat time.
-- It records the approved rates so the next server-side metering migration
-- can enforce them without trusting browser-supplied prices or durations.
