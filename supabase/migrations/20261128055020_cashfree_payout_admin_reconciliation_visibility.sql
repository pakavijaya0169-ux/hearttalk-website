create or replace function public.admin_list_cashfree_payout_requests(p_status text default 'all')
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_rows jsonb;
begin
  if not public.has_hearttalk_admin_permission('finance.view') then
    raise exception 'Finance permission required';
  end if;
  if p_status not in ('all','pending','approved','processing','paid','failed','rejected','cancelled') then
    raise exception 'Invalid status filter';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb)
    into v_rows
  from (
    select
      r.id,r.host_id,r.amount_paise,r.payout_method,r.upi_id,r.account_holder_name,
      r.bank_account_number,r.bank_ifsc,r.status,r.cashfree_transfer_id,r.cashfree_reference_id,
      r.cashfree_status,r.cashfree_status_code,r.cashfree_utr,r.cashfree_last_event_type,
      r.cashfree_event_time,r.cashfree_initiation_http_status,r.cashfree_last_checked_at,
      r.admin_note,r.created_at,r.reviewed_at,r.paid_at,r.failure_reason,
      coalesce(u.raw_user_meta_data->>'display_name',u.raw_user_meta_data->>'username',u.email,'HeartTalk Host') as host_name
    from public.hearttalk_cashfree_payout_requests r
    left join auth.users u on u.id=r.host_id
    where p_status='all' or r.status=p_status
    order by r.created_at desc
    limit 500
  ) q;
  return v_rows;
end;
$$;

revoke all on function public.admin_list_cashfree_payout_requests(text) from public,anon;
grant execute on function public.admin_list_cashfree_payout_requests(text) to authenticated;