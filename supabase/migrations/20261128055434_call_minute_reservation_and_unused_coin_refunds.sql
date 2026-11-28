-- HeartTalk call-balance authorization.
-- New accepted Host calls reserve available user coins up front; end-call settles only
-- fully completed minutes and refunds any unused reservation. Historical calls keep the
-- legacy end-of-call billing path because reserved_coins defaults to zero.
alter table public.call_sessions
  add column if not exists reserved_coins integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.call_sessions'::regclass
      and conname='call_sessions_reserved_coins_nonnegative'
  ) then
    alter table public.call_sessions
      add constraint call_sessions_reserved_coins_nonnegative check (reserved_coins >= 0);
  end if;
end
$$;

create unique index if not exists wallet_ledger_call_reservation_unique_idx
  on public.wallet_ledger(reference_id)
  where entry_type='spend' and reference_id like 'call_reservation:%';

create unique index if not exists wallet_ledger_call_reservation_refund_unique_idx
  on public.wallet_ledger(reference_id)
  where entry_type='refund' and reference_id like 'call_reservation_refund:%';

create or replace function public.hearttalk_accept_call(target_call_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid:=auth.uid();
  v_call public.call_sessions%rowtype;
  v_host uuid;
  v_payer uuid;
  v_balance bigint;
  v_rate integer;
  v_reserve integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select * into v_call
  from public.call_sessions
  where id=target_call_id;

  if not found or v_call.callee_id<>v_user then
    raise exception 'Call not found';
  end if;

  if exists(
    select 1
    from public.hosts h
    where h.user_id in (v_call.caller_id,v_call.callee_id)
      and (
        h.host_status<>'active'
        or not exists(
          select 1 from public.host_applications a
          where a.user_id=h.user_id and a.status='approved'
        )
        or not exists(
          select 1 from public.host_kyc_documents d
          where d.user_id=h.user_id
            and d.document_type='video_selfie'
            and d.status='approved'
        )
      )
  ) then
    raise exception 'Host verification is not active';
  end if;

  -- Serialize calls for both participants before inspecting wallet or call state.
  perform 1 from auth.users
  where id in (v_call.caller_id,v_call.callee_id)
  order by id
  for update;

  select * into v_call
  from public.call_sessions
  where id=target_call_id
  for update;

  -- Duplicate accept requests are idempotent; never reserve twice.
  if v_call.status='accepted' then
    return jsonb_build_object(
      'accepted',true,
      'status','accepted',
      'reserved_coins',v_call.reserved_coins,
      'billing_status',v_call.billing_status
    );
  end if;

  if v_call.status<>'ringing' then
    return jsonb_build_object('accepted',false,'status',v_call.status);
  end if;

  if v_call.created_at<=now()-interval '50 seconds' then
    update public.call_sessions
    set status='missed',ended_at=now()
    where id=target_call_id and status='ringing';
    return jsonb_build_object('accepted',false,'status','missed');
  end if;

  update public.call_sessions
  set status='missed',ended_at=now()
  where status='ringing'
    and id<>target_call_id
    and created_at<=now()-interval '50 seconds'
    and (
      caller_id in (v_call.caller_id,v_call.callee_id)
      or callee_id in (v_call.caller_id,v_call.callee_id)
    );

  if exists(
    select 1
    from public.call_sessions
    where id<>target_call_id
      and status in ('ringing','accepted')
      and (
        caller_id in (v_call.caller_id,v_call.callee_id)
        or callee_id in (v_call.caller_id,v_call.callee_id)
      )
  ) then
    return jsonb_build_object('accepted',false,'status','busy');
  end if;

  -- Identify the approved active Host and the male User who pays in either call direction.
  select h.user_id into v_host
  from public.hosts h
  join public.host_applications a
    on a.user_id=h.user_id and a.status='approved'
  join public.host_kyc_documents d
    on d.user_id=h.user_id
   and d.document_type='video_selfie'
   and d.status='approved'
  where h.host_status='active'
    and h.user_id in (v_call.caller_id,v_call.callee_id)
  limit 1;

  if v_host is not null then
    v_payer:=case
      when v_call.caller_id=v_host then v_call.callee_id
      else v_call.caller_id
    end;

    if exists(
      select 1 from public.profiles p
      where p.id=v_payer and lower(coalesce(p.gender,''))='male'
    ) then
      v_rate:=case when v_call.call_type='voice' then 1 else 2 end;

      select coalesce(sum(amount),0)
        into v_balance
      from public.wallet_ledger
      where user_id=v_payer;

      v_reserve:=((greatest(0,least(v_balance,2147483647::bigint))/v_rate)*v_rate)::integer;

      if v_reserve<v_rate then
        update public.call_sessions
        set status='ended',
            ended_at=now(),
            billed_user_id=v_payer,
            billed_host_id=v_host,
            billed_seconds=0,
            charged_coins=0,
            host_earned_coins=0,
            platform_earned_coins=0,
            reserved_coins=0,
            billing_status='insufficient_coins'
        where id=target_call_id and status='ringing';

        return jsonb_build_object(
          'accepted',false,
          'status','insufficient_coins',
          'required_coins',v_rate,
          'available_coins',v_balance
        );
      end if;

      -- Reserve all currently spendable coins in full-minute increments.
      -- The wallet cannot spend these coins again while the call is active.
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
      values(v_payer,-v_reserve,'spend','call_reservation:'||target_call_id::text);

      update public.call_sessions
      set status='accepted',
          started_at=now(),
          billed_user_id=v_payer,
          billed_host_id=v_host,
          reserved_coins=v_reserve,
          billing_status='reserved'
      where id=target_call_id and status='ringing';

      return jsonb_build_object(
        'accepted',true,
        'status','accepted',
        'reserved_coins',v_reserve,
        'rate_per_minute',v_rate,
        'billing_status','reserved'
      );
    end if;
  end if;

  -- Calls outside the approved Host ↔ male User billing model remain non-billable.
  update public.call_sessions
  set status='accepted',
      started_at=now(),
      reserved_coins=0,
      billing_status='not_billable'
  where id=target_call_id and status='ringing';

  return jsonb_build_object(
    'accepted',true,
    'status','accepted',
    'reserved_coins',0,
    'billing_status','not_billable'
  );
end;
$$;

revoke all on function public.hearttalk_accept_call(uuid) from public,anon;
grant execute on function public.hearttalk_accept_call(uuid) to authenticated;


create or replace function public.hearttalk_end_call(
  target_call_id uuid,
  final_status text default 'ended'
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_call public.call_sessions%rowtype;
  v_host uuid;
  v_user uuid;
  v_seconds integer;
  v_completed_minutes integer;
  v_rate integer;
  v_required_coins integer;
  v_charged_coins integer;
  v_host_share integer;
  v_platform_share integer;
  v_balance bigint;
  v_refund_coins integer:=0;
  v_billing_status text;
begin
  if v_actor is null then raise exception 'Authentication required'; end if;
  if final_status not in ('rejected','ended','cancelled','busy') then
    raise exception 'Invalid final call status';
  end if;

  select * into v_call
  from public.call_sessions
  where id=target_call_id
    and (caller_id=v_actor or callee_id=v_actor)
  for update;

  if not found then raise exception 'Call not found'; end if;

  if v_call.status not in ('ringing','accepted') then
    return jsonb_build_object(
      'updated',false,
      'status',v_call.status,
      'charged_coins',v_call.charged_coins,
      'host_earned_coins',v_call.host_earned_coins,
      'billing_status',v_call.billing_status
    );
  end if;

  update public.call_sessions
  set status=final_status,ended_at=now()
  where id=target_call_id and status in ('ringing','accepted');

  -- Ringing/rejected/busy calls never consume a reservation.
  if v_call.status<>'accepted' or v_call.started_at is null then
    return jsonb_build_object(
      'updated',true,
      'status',final_status,
      'charged_coins',0,
      'host_earned_coins',0,
      'billing_status','not_billable'
    );
  end if;

  v_seconds:=greatest(0,floor(extract(epoch from(now()-v_call.started_at)))::integer);
  v_completed_minutes:=floor(v_seconds/60.0)::integer;
  v_rate:=case when v_call.call_type='voice' then 1 else 2 end;
  v_required_coins:=v_completed_minutes*v_rate;

  if v_call.reserved_coins>0 then
    -- New calls were already debited at acceptance. Charge only completed minutes,
    -- capped by the reserved amount; return every unused reserved coin.
    v_user:=v_call.billed_user_id;
    v_host:=v_call.billed_host_id;
    if v_user is null or v_host is null then
      raise exception 'Call reservation is missing its payer or Host';
    end if;

    v_charged_coins:=least(v_required_coins,v_call.reserved_coins);
    v_refund_coins:=v_call.reserved_coins-v_charged_coins;
    v_host_share:=v_charged_coins;
    v_platform_share:=v_charged_coins;
    v_billing_status:=case
      when v_required_coins>v_call.reserved_coins then 'reserved_limit_reached'
      when v_charged_coins=0 then 'no_charge'
      else 'charged'
    end;

    if v_refund_coins>0
       and not exists(
         select 1 from public.wallet_ledger
         where reference_id='call_reservation_refund:'||target_call_id::text
           and entry_type='refund'
       ) then
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
      values(v_user,v_refund_coins,'refund','call_reservation_refund:'||target_call_id::text);
    end if;
  else
    -- Backward-compatible settlement for calls created before this migration.
    select h.user_id into v_host
    from public.hosts h
    join public.host_applications a on a.user_id=h.user_id and a.status='approved'
    join public.host_kyc_documents d
      on d.user_id=h.user_id
     and d.document_type='video_selfie'
     and d.status='approved'
    where h.host_status='active'
      and h.user_id in (v_call.caller_id,v_call.callee_id)
    limit 1;

    if v_host is null then
      update public.call_sessions
      set billing_status='not_billable'
      where id=target_call_id;
      return jsonb_build_object('updated',true,'status','ended','charged_coins',0,'billing_status','not_billable');
    end if;

    v_user:=case when v_call.caller_id=v_host then v_call.callee_id else v_call.caller_id end;

    if not exists(
      select 1 from public.profiles p
      where p.id=v_user and lower(coalesce(p.gender,''))='male'
    ) then
      update public.call_sessions
      set billing_status='not_billable'
      where id=target_call_id;
      return jsonb_build_object('updated',true,'status','ended','charged_coins',0,'billing_status','not_billable');
    end if;

    perform 1 from auth.users where id=v_user for update;

    select coalesce(sum(amount),0)
      into v_balance
    from public.wallet_ledger
    where user_id=v_user;

    if v_balance<v_required_coins then
      update public.call_sessions
      set billed_user_id=v_user,
          billed_host_id=v_host,
          billed_seconds=v_seconds,
          charged_coins=0,
          host_earned_coins=0,
          platform_earned_coins=0,
          billing_status='insufficient_coins'
      where id=target_call_id;

      return jsonb_build_object(
        'updated',true,
        'status','ended',
        'billed_seconds',v_seconds,
        'completed_minutes',v_completed_minutes,
        'required_coins',v_required_coins,
        'charged_coins',0,
        'billing_status','insufficient_coins'
      );
    end if;

    v_charged_coins:=v_required_coins;
    v_host_share:=v_charged_coins;
    v_platform_share:=v_charged_coins;
    v_billing_status:=case when v_charged_coins=0 then 'no_charge' else 'charged' end;

    if v_charged_coins>0 then
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
      values(v_user,-v_charged_coins,'spend','call_session:'||target_call_id::text);
    end if;
  end if;

  update public.call_sessions
  set billed_user_id=v_user,
      billed_host_id=v_host,
      billed_seconds=v_seconds,
      charged_coins=v_charged_coins,
      host_earned_coins=v_host_share,
      platform_earned_coins=v_platform_share,
      billing_status=v_billing_status
  where id=target_call_id;

  if v_charged_coins>0 then
    insert into public.hearttalk_call_session_earnings(
      call_id,host_id,user_id,call_type,billed_seconds,charged_coins,earned_coins
    )
    values(
      target_call_id,v_host,v_user,v_call.call_type,v_seconds,v_charged_coins,v_host_share
    )
    on conflict(call_id) do nothing;
  end if;

  return jsonb_build_object(
    'updated',true,
    'status','ended',
    'billed_seconds',v_seconds,
    'completed_minutes',v_completed_minutes,
    'required_coins',v_required_coins,
    'reserved_coins',v_call.reserved_coins,
    'refunded_coins',v_refund_coins,
    'charged_coins',v_charged_coins,
    'host_earned_coins',v_host_share,
    'platform_earned_coins',v_platform_share,
    'host_earned_value_paise',v_host_share::bigint*50,
    'platform_earned_value_paise',v_platform_share::bigint*50,
    'billing_status',v_billing_status
  );
end;
$$;

revoke all on function public.hearttalk_end_call(uuid,text) from public,anon;
grant execute on function public.hearttalk_end_call(uuid,text) to authenticated;


create or replace function public.hearttalk_enforce_call_reservation(target_call_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid:=auth.uid();
  v_call public.call_sessions%rowtype;
  v_rate integer;
  v_reserved_minutes integer;
  v_elapsed_seconds integer;
  v_completed_minutes integer;
  v_end_result jsonb;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select * into v_call
  from public.call_sessions
  where id=target_call_id
    and (caller_id=v_user or callee_id=v_user)
  for update;

  if not found then raise exception 'Call not found'; end if;

  if v_call.status<>'accepted' or v_call.reserved_coins<=0 or v_call.started_at is null then
    return jsonb_build_object('ended_due_to_reservation',false,'status',v_call.status);
  end if;

  v_rate:=case when v_call.call_type='voice' then 1 else 2 end;
  v_reserved_minutes:=floor(v_call.reserved_coins::numeric/v_rate)::integer;
  v_elapsed_seconds:=greatest(0,floor(extract(epoch from(now()-v_call.started_at)))::integer);
  v_completed_minutes:=floor(v_elapsed_seconds/60.0)::integer;

  -- Permit the current prepaid whole-minute window, but end the call when the next
  -- complete minute would exceed the coins reserved at acceptance.
  if v_completed_minutes>v_reserved_minutes then
    v_end_result:=public.hearttalk_end_call(target_call_id,'ended');
    return jsonb_build_object(
      'ended_due_to_reservation',true,
      'status','ended',
      'billing',v_end_result
    );
  end if;

  return jsonb_build_object(
    'ended_due_to_reservation',false,
    'status','accepted',
    'reserved_minutes',v_reserved_minutes,
    'completed_minutes',v_completed_minutes,
    'seconds_remaining_in_reserved_window',greatest(0,(v_reserved_minutes*60)-v_elapsed_seconds)
  );
end;
$$;

revoke all on function public.hearttalk_enforce_call_reservation(uuid) from public,anon;
grant execute on function public.hearttalk_enforce_call_reservation(uuid) to authenticated;