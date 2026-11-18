-- HeartTalk server-side metering and Host cash earnings.
-- Apply after 202611180004_hearttalk_final_pricing_settings.sql and the existing
-- Host KYC / manual UPI withdrawal migrations. This migration does not enable payouts.
begin;

create or replace function public.hearttalk_is_approved_female_host(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.hosts h
    join public.host_applications a on a.user_id = h.user_id and a.status = 'approved'
    join public.profiles p on p.id = h.user_id
    where h.user_id = p_user_id
      and h.host_status = 'active'
      and lower(coalesce(p.gender,'')) = 'female'
      and p.age >= 18
      and exists (
        select 1 from public.host_kyc_documents d
        where d.user_id = h.user_id
          and d.document_type = 'video_selfie'
          and d.status = 'approved'
      )
  );
$$;
revoke all on function public.hearttalk_is_approved_female_host(uuid) from public, anon;
grant execute on function public.hearttalk_is_approved_female_host(uuid) to authenticated;

create table if not exists public.hearttalk_call_settlements (
  call_id uuid primary key references public.call_sessions(id) on delete restrict,
  payer_id uuid not null references auth.users(id),
  host_id uuid not null references auth.users(id),
  minutes_billed integer not null check (minutes_billed > 0),
  coins_charged integer not null check (coins_charged > 0),
  host_amount_paise bigint not null check (host_amount_paise >= 0),
  created_at timestamptz not null default now()
);
alter table public.hearttalk_call_settlements enable row level security;
revoke all on public.hearttalk_call_settlements from public, anon, authenticated;

create table if not exists public.hearttalk_chat_billing_state (
  sender_id uuid not null references auth.users(id) on delete cascade,
  host_id uuid not null references auth.users(id) on delete cascade,
  last_charged_at timestamptz not null,
  primary key(sender_id, host_id),
  check(sender_id <> host_id)
);
alter table public.hearttalk_chat_billing_state enable row level security;
revoke all on public.hearttalk_chat_billing_state from public, anon, authenticated;

-- A call cannot be accepted unless the caller can afford at least one minute.
create or replace function public.hearttalk_check_call_funds()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rate integer;
  v_balance bigint;
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    select case when new.call_type = 'video' then video_coins_per_minute
                else voice_coins_per_minute end
      into v_rate
    from public.hearttalk_pricing_settings where id = true;
    select coalesce(sum(amount),0) into v_balance
      from public.wallet_ledger where user_id = new.caller_id;
    if v_balance < coalesce(v_rate,1) then
      raise exception 'Not enough coins to start this call. Please recharge your wallet.';
    end if;
    new.started_at := coalesce(new.started_at, now());
  end if;
  return new;
end;
$$;
drop trigger if exists hearttalk_call_funds_before_accept on public.call_sessions;
create trigger hearttalk_call_funds_before_accept
before update of status on public.call_sessions
for each row execute function public.hearttalk_check_call_funds();

-- Settle accepted calls once, using database timestamps, not browser duration.
create or replace function public.hearttalk_settle_ended_call()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_minutes integer;
  v_rate integer;
  v_due integer;
  v_balance bigint;
  v_charge integer;
  v_host uuid;
  v_host_paise bigint;
begin
  if new.status <> 'ended' or old.status = 'ended' or new.started_at is null then
    return new;
  end if;
  if not public.hearttalk_is_approved_female_host(new.callee_id) then
    return new;
  end if;

  v_minutes := greatest(1, ceil(extract(epoch from (coalesce(new.ended_at,now()) - new.started_at))/60.0)::integer);
  select case when new.call_type='video' then video_coins_per_minute
              else voice_coins_per_minute end
    into v_rate
  from public.hearttalk_pricing_settings where id=true;
  v_due := v_minutes * coalesce(v_rate,1);

  perform 1 from auth.users where id=new.caller_id for update;
  select coalesce(sum(amount),0) into v_balance
    from public.wallet_ledger where user_id=new.caller_id;
  v_charge := least(v_due, greatest(0,v_balance));
  if v_charge <= 0 then
    return new;
  end if;

  insert into public.hearttalk_call_settlements(call_id,payer_id,host_id,minutes_billed,coins_charged,host_amount_paise)
  values(new.id,new.caller_id,new.callee_id,v_minutes,v_charge,floor(v_charge*50)::bigint)
  on conflict(call_id) do nothing;
  if not found then return new; end if;

  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(new.caller_id,-v_charge,'spend','call:'||new.id::text);

  v_host_paise := floor(v_charge*50)::bigint; -- 50% of ₹1 per coin, in paise.
  if v_host_paise > 0 then
    insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,source_reference,note)
    values(new.callee_id,v_host_paise,'earning_credit',new.id,'call:'||new.id::text,'50% Host share from completed call')
    on conflict(host_id,source_reference) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists hearttalk_call_settle_after_end on public.call_sessions;
create trigger hearttalk_call_settle_after_end
after update of status on public.call_sessions
for each row execute function public.hearttalk_settle_ended_call();

-- One charge per active 5-minute chat block. All message types use this RPC.
create or replace function public.hearttalk_send_chat_message(p_receiver_id uuid,p_message text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sender uuid := auth.uid();
  v_price integer;
  v_block integer;
  v_balance bigint;
  v_charge boolean := false;
  v_host_paise bigint;
  v_message_id bigint;
begin
  if v_sender is null then raise exception 'Authentication required'; end if;
  if p_receiver_id is null or p_receiver_id=v_sender then raise exception 'Invalid recipient'; end if;
  if p_message is null or char_length(p_message) not between 1 and 2000 then raise exception 'Message must contain 1 to 2000 characters'; end if;
  if not exists (
    select 1 from public.profiles where id=p_receiver_id
  ) then raise exception 'Recipient not found'; end if;

  if public.hearttalk_is_approved_female_host(p_receiver_id) then
    select chat_coins_per_block,chat_block_minutes into v_price,v_block
      from public.hearttalk_pricing_settings where id=true;
    perform 1 from auth.users where id=v_sender for update;
    perform 1 from public.hearttalk_chat_billing_state
      where sender_id=v_sender and host_id=p_receiver_id for update;
    if not exists(select 1 from public.hearttalk_chat_billing_state where sender_id=v_sender and host_id=p_receiver_id)
       or exists(select 1 from public.hearttalk_chat_billing_state
          where sender_id=v_sender and host_id=p_receiver_id
            and last_charged_at <= now() - make_interval(mins => v_block)) then
      v_charge := true;
    end if;
    if v_charge then
      select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
      if v_balance < v_price then raise exception 'Not enough coins. Chat requires % coins for the next % minutes.',v_price,v_block; end if;
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
      values(v_sender,-v_price,'spend','chat:'||v_sender::text||':'||p_receiver_id::text||':'||extract(epoch from now())::bigint::text);
      insert into public.hearttalk_chat_billing_state(sender_id,host_id,last_charged_at)
      values(v_sender,p_receiver_id,now())
      on conflict(sender_id,host_id) do update set last_charged_at=excluded.last_charged_at;
      v_host_paise := floor(v_price*50)::bigint;
      if v_host_paise > 0 then
        insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,source_reference,note)
        values(p_receiver_id,v_host_paise,'earning_credit',
          'chat:'||v_sender::text||':'||p_receiver_id::text||':'||extract(epoch from now())::bigint::text,
          '50% Host share from chat block');
      end if;
    end if;
  end if;

  insert into public.messages(sender_id,receiver_id,message)
  values(v_sender,p_receiver_id,p_message) returning id into v_message_id;
  return jsonb_build_object('message_id',v_message_id,'charged',v_charge,
    'coins_charged',case when v_charge then coalesce(v_price,0) else 0 end);
end;
$$;
revoke all on function public.hearttalk_send_chat_message(uuid,text) from public, anon;
grant execute on function public.hearttalk_send_chat_message(uuid,text) to authenticated;

-- Prevent direct inserts bypassing the metering RPC.
drop policy if exists "Users can send messages as themselves" on public.messages;
revoke insert on public.messages from anon, authenticated;

-- Gifts also credit the withdrawable cash ledger, only for verified Hosts.
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
  if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;
  if not public.hearttalk_is_approved_female_host(target_host_id) then raise exception 'Gifts can only be sent to approved female Hosts'; end if;
  select coin_price into v_price from public.hearttalk_gift_catalog where gift_code=selected_gift_code and active=true;
  if v_price is null then raise exception 'Gift is unavailable'; end if;
  perform 1 from auth.users where id=v_sender for update;
  select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
  if v_balance<v_price then raise exception 'Not enough coins. Please add coins to your wallet.'; end if;
  v_host_share:=floor(v_price*0.50)::integer;
  v_platform_share:=v_price-v_host_share;
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_sender,-v_price,'spend','gift:'||selected_gift_code);
  insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins)
  values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share)
  returning id into v_event;
  insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins)
  values(target_host_id,v_event,v_host_share);
  if v_host_share>0 then
    insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,source_reference,note)
    values(target_host_id,v_host_share*50,'earning_credit',v_event,'gift:'||v_event::text,'50% Host share from gift');
  end if;
  return jsonb_build_object('gift_event_id',v_event,'coin_price',v_price,
    'host_earned_coins',v_host_share,'host_earned_amount_paise',v_host_share*50,
    'platform_share_coins',v_platform_share,'status','recorded');
end;
$$;
revoke all on function public.hearttalk_send_gift(uuid,text) from public, anon;
grant execute on function public.hearttalk_send_gift(uuid,text) to authenticated;

-- Enforce one withdrawal request in any rolling seven-day period.
create or replace function public.hearttalk_request_manual_upi_withdrawal(
 p_amount_paise bigint,p_upi_id text,p_account_holder_name text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_available bigint; v_id uuid; v_requests_enabled boolean;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select requests_enabled into v_requests_enabled from public.hearttalk_payout_settings where id=true;
 if coalesce(v_requests_enabled,false)=false then raise exception 'Host withdrawals are temporarily disabled pending compliance approval'; end if;
 if not public.hearttalk_is_approved_female_host(v_user) then raise exception 'Only approved female Hosts can withdraw'; end if;
 if p_amount_paise is null or p_amount_paise<50000 then raise exception 'Minimum withdrawal is ₹500'; end if;
 if p_upi_id is null or p_upi_id !~* '^[a-z0-9._-]{2,256}@[a-z][a-z0-9]{1,20}$' then raise exception 'Enter a valid UPI ID'; end if;
 if p_account_holder_name is null or char_length(trim(p_account_holder_name)) not between 2 and 100 then raise exception 'Enter account holder name'; end if;
 perform 1 from auth.users where id=v_user for update;
 if exists(select 1 from public.hearttalk_host_payout_requests where host_id=v_user and created_at>now()-interval '7 days') then
   raise exception 'You can request withdrawal only once every 7 days'; end if;
 if exists(select 1 from public.hearttalk_host_payout_requests where host_id=v_user and status in ('pending','approved')) then
   raise exception 'You already have an open withdrawal request'; end if;
 select coalesce(sum(amount_paise),0) into v_available from public.hearttalk_host_cash_ledger where host_id=v_user;
 if v_available<p_amount_paise then raise exception 'Insufficient available earnings'; end if;
 insert into public.hearttalk_host_payout_requests(host_id,amount_paise,upi_id,account_holder_name)
 values(v_user,p_amount_paise,trim(p_upi_id),trim(p_account_holder_name)) returning id into v_id;
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,note,created_by)
 values(v_user,-p_amount_paise,'withdrawal_hold',v_id,'Reserved for manual UPI withdrawal',v_user);
 return jsonb_build_object('request_id',v_id,'amount_paise',p_amount_paise,'status','pending');
end; $$;
revoke all on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) from public,anon;
grant execute on function public.hearttalk_request_manual_upi_withdrawal(bigint,text,text) to authenticated;

-- Withdrawals remain disabled until compliance review is complete.
update public.hearttalk_payout_settings set requests_enabled=false,updated_at=now() where id=true;

commit;
