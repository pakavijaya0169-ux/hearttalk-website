-- Safe Cashfree payout reconciliation metadata and verified non-acceptance recovery.
-- Additive only: no existing payout rows, wallet entries, or host earnings are removed.
alter table public.hearttalk_cashfree_payout_requests
  add column if not exists cashfree_initiation_http_status integer,
  add column if not exists cashfree_last_checked_at timestamptz;

create or replace function public.hearttalk_fail_cashfree_payout_unaccepted(
  p_request_id uuid,
  p_transfer_id text,
  p_http_status integer,
  p_lookup_status integer,
  p_event_hash text,
  p_admin_user_id uuid,
  p_failure_reason text default 'Cashfree did not create this transfer'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.hearttalk_cashfree_payout_requests%rowtype;
  v_net bigint;
  v_hold_count integer;
  v_inserted boolean;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Trusted payout reconciliation service required';
  end if;

  if p_request_id is null
     or p_transfer_id is null
     or p_transfer_id !~* '^HTP_[a-f0-9]{32}$'
     or p_lookup_status <> 404
     or p_http_status is null
     or p_http_status < 400
     or p_http_status >= 500
     or p_http_status in (408,409,425,429)
     or p_event_hash is null
     or p_event_hash !~ '^[a-f0-9]{64}$'
     or p_admin_user_id is null then
    raise exception 'Invalid verified non-acceptance recovery request';
  end if;

  select * into v_request
  from public.hearttalk_cashfree_payout_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Cashfree payout request not found'; end if;

  if v_request.status = 'failed'
     and v_request.cashfree_status = 'NOT_ACCEPTED' then
    return jsonb_build_object('status','already_released','request_id',v_request.id);
  end if;

  if v_request.status <> 'processing'
     or v_request.cashfree_reference_id <> p_transfer_id
     or v_request.cashfree_transfer_id is not null
     or v_request.cashfree_initiation_http_status is distinct from p_http_status then
    raise exception 'Payout is not eligible for non-acceptance recovery';
  end if;

  select coalesce(sum(amount_paise),0),
         count(*) filter (where entry_type='withdrawal_hold')::integer
    into v_net, v_hold_count
  from public.hearttalk_host_cash_ledger
  where reference_id = v_request.id
    and (
      entry_type in ('withdrawal_hold','withdrawal_release')
      or (entry_type='admin_adjustment'
          and source_reference like 'cashfree-payout-transition:'||v_request.id::text||':%')
    );

  if v_hold_count <> 1 or v_net <> -v_request.amount_paise then
    raise exception 'Reserved balance does not match payout amount; manual review required';
  end if;

  insert into public.hearttalk_cashfree_payout_webhook_events
    (event_hash, transfer_id, event_type, provider_status, processing_result)
  values
    (lower(p_event_hash), p_transfer_id, 'TRANSFER_INITIATION_REJECTED',
     'NOT_ACCEPTED', jsonb_build_object('request_id',v_request.id,'http_status',p_http_status,'lookup_status',p_lookup_status))
  on conflict (event_hash) do nothing;
  v_inserted := found;

  if not v_inserted then
    return jsonb_build_object('status','duplicate_recovery_event','request_id',v_request.id);
  end if;

  insert into public.hearttalk_host_cash_ledger
    (host_id, amount_paise, entry_type, reference_id, source_reference, note, created_by)
  values
    (v_request.host_id, v_request.amount_paise, 'withdrawal_release', v_request.id,
     'cashfree-initiation-rejected:'||v_request.id::text,
     'Cashfree definitively rejected initiation and status lookup confirmed no transfer; reserved earnings released',
     p_admin_user_id);

  update public.hearttalk_cashfree_payout_requests
  set status='failed',
      cashfree_status='NOT_ACCEPTED',
      failure_reason=left(coalesce(nullif(trim(p_failure_reason),''),'Cashfree did not create this transfer'),500),
      failed_at=now(),
      cashfree_last_checked_at=now(),
      updated_at=now()
  where id=v_request.id;

  insert into public.hearttalk_admin_audit_log
    (admin_user_id, action, target_type, target_id, details)
  values
    (p_admin_user_id, 'cashfree_payout_initiation_not_accepted', 'cashfree_payout', v_request.id::text,
     jsonb_build_object('amount_paise',v_request.amount_paise,'http_status',p_http_status,
                        'transfer_id',p_transfer_id,'lookup_status',p_lookup_status));

  update public.hearttalk_cashfree_payout_webhook_events
  set processing_result = jsonb_build_object('status','failed_and_released','request_id',v_request.id,
                                             'released_paise',v_request.amount_paise)
  where event_hash=lower(p_event_hash);

  return jsonb_build_object('status','failed_and_released','request_id',v_request.id,
                            'released_paise',v_request.amount_paise);
end;
$$;

revoke all on function public.hearttalk_fail_cashfree_payout_unaccepted(uuid,text,integer,integer,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.hearttalk_fail_cashfree_payout_unaccepted(uuid,text,integer,integer,text,uuid,text)
  to service_role;