-- HeartTalk Cashfree Payouts V2 webhook reconciliation and finance access controls.
-- Additive only: preserves existing payout requests, balances, and legacy withdrawal workflows.

alter table public.hearttalk_cashfree_payout_requests
  add column if not exists cashfree_utr text,
  add column if not exists cashfree_status_code text,
  add column if not exists cashfree_last_event_type text,
  add column if not exists cashfree_event_time timestamptz;

create table if not exists public.hearttalk_cashfree_payout_webhook_events (
  event_hash text primary key check (event_hash ~ '^[a-f0-9]{64}$'),
  transfer_id text not null,
  event_type text not null,
  provider_status text not null,
  event_time timestamptz,
  received_at timestamptz not null default now(),
  processing_result jsonb not null default '{}'::jsonb
);
create index if not exists ht_cashfree_payout_webhook_transfer_idx
  on public.hearttalk_cashfree_payout_webhook_events(transfer_id, received_at desc);
alter table public.hearttalk_cashfree_payout_webhook_events enable row level security;
revoke all on public.hearttalk_cashfree_payout_webhook_events from public, anon, authenticated;

-- This RPC is callable only from the service-role Edge Function after Cashfree signature
-- verification AND an independent Cashfree GET /transfers status lookup.
create or replace function public.hearttalk_apply_cashfree_payout_status(
  p_event_hash text,
  p_transfer_id text,
  p_cf_transfer_id text,
  p_provider_status text,
  p_status_code text,
  p_amount_paise bigint,
  p_utr text,
  p_failure_reason text,
  p_event_type text,
  p_event_time timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.hearttalk_cashfree_payout_requests%rowtype;
  v_next_status text;
  v_net bigint;
  v_desired_net bigint;
  v_delta bigint;
  v_result jsonb;
  v_inserted boolean;
begin
  if p_event_hash is null or p_event_hash !~ '^[a-f0-9]{64}$'
     or p_transfer_id is null or p_transfer_id !~* '^HTP_[a-f0-9]{32}$'
     or p_provider_status is null
     or p_amount_paise is null or p_amount_paise < 1 then
    raise exception 'Invalid verified Cashfree payout event';
  end if;

  if upper(p_provider_status) not in
    ('SUCCESS','FAILED','REVERSED','REJECTED','CANCELLED','RECEIVED','PENDING','QUEUED','PROCESSING') then
    raise exception 'Unsupported Cashfree transfer status';
  end if;

  insert into public.hearttalk_cashfree_payout_webhook_events
    (event_hash,transfer_id,event_type,provider_status,event_time)
  values
    (lower(p_event_hash),p_transfer_id,coalesce(p_event_type,'UNKNOWN'),
     upper(p_provider_status),p_event_time)
  on conflict (event_hash) do nothing;
  v_inserted := found;

  if not v_inserted then
    return jsonb_build_object('status','duplicate_event');
  end if;

  select * into v_request
  from public.hearttalk_cashfree_payout_requests
  where cashfree_reference_id=p_transfer_id
     or cashfree_transfer_id=p_transfer_id
  for update;

  if not found then
    v_result := jsonb_build_object('status','unknown_transfer');
    update public.hearttalk_cashfree_payout_webhook_events
      set processing_result=v_result where event_hash=lower(p_event_hash);
    return v_result;
  end if;

  if v_request.amount_paise <> p_amount_paise then
    v_result := jsonb_build_object('status','amount_mismatch','request_id',v_request.id);
    update public.hearttalk_cashfree_payout_webhook_events
      set processing_result=v_result where event_hash=lower(p_event_hash);
    return v_result;
  end if;

  if p_cf_transfer_id is not null
     and v_request.cashfree_transfer_id is not null
     and v_request.cashfree_transfer_id <> p_cf_transfer_id then
    v_result := jsonb_build_object('status','provider_reference_mismatch','request_id',v_request.id);
    update public.hearttalk_cashfree_payout_webhook_events
      set processing_result=v_result where event_hash=lower(p_event_hash);
    return v_result;
  end if;

  if upper(p_provider_status)='SUCCESS' then
    v_next_status := 'paid';
  elsif upper(p_provider_status)='CANCELLED' then
    v_next_status := 'cancelled';
  elsif upper(p_provider_status) in ('FAILED','REVERSED','REJECTED') then
    v_next_status := 'failed';
  else
    v_next_status := 'processing';
  end if;

  -- Keep the host ledger equal to the real payout state. The initial withdrawal_hold
  -- is already negative. Release the reservation on failure/cancellation and re-adjust
  -- it if a later verified provider state changes again. Event hashes prevent duplicate delivery.
  if v_next_status in ('paid','failed','cancelled') then
    select coalesce(sum(amount_paise),0) into v_net
    from public.hearttalk_host_cash_ledger
    where reference_id=v_request.id
      and (
        entry_type in ('withdrawal_hold','withdrawal_release')
        or (entry_type='admin_adjustment'
            and source_reference like 'cashfree-payout-transition:'||v_request.id::text||':%')
      );

    v_desired_net := case when v_next_status='paid' then -v_request.amount_paise else 0 end;
    v_delta := v_desired_net-v_net;

    if v_delta <> 0 then
      if v_delta > 0
         and not exists (
           select 1 from public.hearttalk_host_cash_ledger
           where reference_id=v_request.id and entry_type='withdrawal_release'
         ) then
        insert into public.hearttalk_host_cash_ledger
          (host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
        values
          (v_request.host_id,v_delta,'withdrawal_release',v_request.id,
           'cashfree-payout-release:'||v_request.id::text,
           'Cashfree verified payout failure/cancellation released reserved earnings',null);
      else
        insert into public.hearttalk_host_cash_ledger
          (host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
        values
          (v_request.host_id,v_delta,'admin_adjustment',v_request.id,
           'cashfree-payout-transition:'||v_request.id::text||':'||lower(p_event_hash),
           'Cashfree verified payout status reconciliation adjustment',null);
      end if;
    end if;
  end if;

  update public.hearttalk_cashfree_payout_requests
  set
    status = case
      when v_request.status in ('rejected','cancelled') and v_next_status='paid' then v_request.status
      when v_request.status in ('paid','failed','rejected','cancelled') and v_next_status='processing' then v_request.status
      else v_next_status
    end,
    cashfree_transfer_id=coalesce(p_cf_transfer_id,cashfree_transfer_id),
    cashfree_status=upper(p_provider_status),
    cashfree_status_code=coalesce(p_status_code,cashfree_status_code),
    cashfree_utr=coalesce(p_utr,cashfree_utr),
    cashfree_last_event_type=coalesce(p_event_type,cashfree_last_event_type),
    cashfree_event_time=coalesce(p_event_time,cashfree_event_time),
    paid_at=case when v_next_status='paid' and v_request.status not in ('rejected','cancelled')
                 then coalesce(p_event_time,now()) else paid_at end,
    failed_at=case when v_next_status in ('failed','cancelled')
                    then coalesce(p_event_time,now()) else failed_at end,
    failure_reason=case when v_next_status in ('failed','cancelled')
                        then nullif(left(coalesce(p_failure_reason,''),500),'')
                        else failure_reason end,
    updated_at=now()
  where id=v_request.id;

  v_result := jsonb_build_object(
    'status','updated',
    'request_id',v_request.id,
    'previous_status',v_request.status,
    'current_status',case
      when v_request.status in ('rejected','cancelled') and v_next_status='paid' then v_request.status
      when v_request.status in ('paid','failed','rejected','cancelled') and v_next_status='processing' then v_request.status
      else v_next_status end,
    'ledger_adjustment_paise',coalesce(v_delta,0)
  );
  update public.hearttalk_cashfree_payout_webhook_events
    set processing_result=v_result where event_hash=lower(p_event_hash);
  return v_result;
end;
$$;
revoke all on function public.hearttalk_apply_cashfree_payout_status(text,text,text,text,text,bigint,text,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.hearttalk_apply_cashfree_payout_status(text,text,text,text,text,bigint,text,text,text,timestamptz)
  to service_role;

-- Finance staff can read Cashfree payout requests; withdrawal managers can approve/reject.
create or replace function public.admin_list_cashfree_payout_requests(p_status text default 'all')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
  if not public.has_hearttalk_admin_permission('finance.view') then
    raise exception 'Finance permission required';
  end if;
  if p_status not in ('all','pending','approved','processing','paid','failed','rejected','cancelled') then
    raise exception 'Invalid status filter';
  end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
  from (
    select r.id,r.host_id,r.amount_paise,r.payout_method,r.upi_id,r.account_holder_name,
      r.bank_account_number,r.bank_ifsc,r.status,r.cashfree_transfer_id,r.cashfree_reference_id,
      r.cashfree_status,r.cashfree_status_code,r.cashfree_utr,r.cashfree_last_event_type,
      r.cashfree_event_time,r.admin_note,r.created_at,r.reviewed_at,r.paid_at,r.failure_reason,
      coalesce(u.raw_user_meta_data->>'display_name',u.raw_user_meta_data->>'username',u.email,'HeartTalk Host') as host_name
    from public.hearttalk_cashfree_payout_requests r
    left join auth.users u on u.id=r.host_id
    where p_status='all' or r.status=p_status
    order by r.created_at desc limit 500
  ) q;
  return v_rows;
end;
$$;
revoke all on function public.admin_list_cashfree_payout_requests(text) from public,anon;
grant execute on function public.admin_list_cashfree_payout_requests(text) to authenticated;

create or replace function public.admin_approve_cashfree_payout_request(p_request_id uuid,p_admin_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_cashfree_payout_requests%rowtype;
begin
  if not public.has_hearttalk_admin_permission('withdrawals.manage') then
    raise exception 'Withdrawal management permission required';
  end if;
  select * into v from public.hearttalk_cashfree_payout_requests where id=p_request_id for update;
  if not found or v.status<>'pending' then raise exception 'Pending Cashfree payout request not found'; end if;
  update public.hearttalk_cashfree_payout_requests
  set status='approved',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
  where id=p_request_id and status='pending';
  if not found then raise exception 'Request changed before approval'; end if;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'cashfree_host_payout_approved','cashfree_payout',p_request_id::text,
    jsonb_build_object('host_id',v.host_id,'amount_paise',v.amount_paise));
  return jsonb_build_object('request_id',p_request_id,'status','approved');
end;
$$;
revoke all on function public.admin_approve_cashfree_payout_request(uuid,text) from public,anon;
grant execute on function public.admin_approve_cashfree_payout_request(uuid,text) to authenticated;

create or replace function public.admin_reject_cashfree_payout_request(p_request_id uuid,p_admin_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_cashfree_payout_requests%rowtype;
begin
  if not public.has_hearttalk_admin_permission('withdrawals.manage') then
    raise exception 'Withdrawal management permission required';
  end if;
  select * into v from public.hearttalk_cashfree_payout_requests where id=p_request_id for update;
  if not found or v.status not in ('pending','approved') then
    raise exception 'Only pending or approved Cashfree payout requests can be rejected';
  end if;
  update public.hearttalk_cashfree_payout_requests
  set status='rejected',admin_note=coalesce(nullif(trim(p_admin_note),''),'Request rejected'),
      reviewed_by=auth.uid(),reviewed_at=now(),failed_at=now(),updated_at=now()
  where id=p_request_id and status in ('pending','approved');
  if not found then raise exception 'Request changed before rejection'; end if;

  if not exists(select 1 from public.hearttalk_host_cash_ledger
                where reference_id=v.id and entry_type='withdrawal_release') then
    insert into public.hearttalk_host_cash_ledger
      (host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
    values(v.host_id,v.amount_paise,'withdrawal_release',v.id,
      'cashfree-admin-reject:'||v.id::text,
      'Reserved earnings released after admin rejected Cashfree payout request',auth.uid());
  end if;

  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'cashfree_host_payout_rejected','cashfree_payout',p_request_id::text,
    jsonb_build_object('host_id',v.host_id,'amount_paise',v.amount_paise,'admin_note',coalesce(p_admin_note,'')));
  return jsonb_build_object('request_id',p_request_id,'status','rejected');
end;
$$;
revoke all on function public.admin_reject_cashfree_payout_request(uuid,text) from public,anon;
grant execute on function public.admin_reject_cashfree_payout_request(uuid,text) to authenticated;
