-- HeartTalk manual host payout workflow
-- Host earnings conversion: 1 earned host coin = INR 0.50 (50 paise).
-- Coin wallet purchases remain non-cash-redeemable. Payout requests stay disabled
-- until Cashfree/another provider approves the complete model and compliance is complete.

create table if not exists public.hearttalk_payout_settings (
  id boolean primary key default true check (id),
  paise_per_host_coin integer not null default 50 check (paise_per_host_coin > 0),
  requests_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.hearttalk_payout_settings(id,paise_per_host_coin,requests_enabled)
values(true,50,false)
on conflict(id) do update set paise_per_host_coin=50;

alter table public.host_payout_requests
  add column if not exists requested_amount_paise bigint,
  add column if not exists payout_reference text,
  add column if not exists paid_at timestamptz;
update public.host_payout_requests r
set requested_amount_paise = r.requested_coins * 50
where requested_amount_paise is null;
alter table public.host_payout_requests
  alter column requested_amount_paise set not null;

create index if not exists host_payout_requests_status_created_idx
  on public.host_payout_requests(status,created_at desc);

alter table public.hearttalk_payout_settings enable row level security;
revoke all on public.hearttalk_payout_settings from anon,authenticated,public;
grant select on public.hearttalk_payout_settings to authenticated;
drop policy if exists "Authenticated can read payout conversion" on public.hearttalk_payout_settings;
create policy "Authenticated can read payout conversion"
  on public.hearttalk_payout_settings for select to authenticated using(true);

-- Host requests withdrawal by earned coin quantity; the server calculates INR.
create or replace function public.hearttalk_request_host_payout(p_coins integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_host uuid := auth.uid();
  v_rate integer;
  v_enabled boolean;
  v_earned bigint;
  v_reserved bigint;
  v_amount bigint;
  v_request uuid;
begin
  if v_host is null then raise exception 'Please log in first'; end if;
  if p_coins is null or p_coins <= 0 then raise exception 'Enter a valid coin amount'; end if;
  perform 1 from auth.users where id=v_host for update;
  select paise_per_host_coin,requests_enabled into v_rate,v_enabled
    from public.hearttalk_payout_settings where id=true;
  if not coalesce(v_enabled,false) then
    raise exception 'Host withdrawals are not enabled yet. Please wait for HeartTalk payout approval.';
  end if;
  select coalesce(sum(earned_coins),0) into v_earned
    from public.hearttalk_host_earnings where host_id=v_host;
  select coalesce(sum(requested_coins),0) into v_reserved
    from public.host_payout_requests
    where host_id=v_host and status in ('pending','approved','paid');
  if p_coins > v_earned-v_reserved then raise exception 'Insufficient available host earnings'; end if;
  v_amount := p_coins::bigint * v_rate;
  insert into public.host_payout_requests(host_id,requested_coins,requested_amount_paise,status)
    values(v_host,p_coins,v_amount,'pending') returning id into v_request;
  return jsonb_build_object('request_id',v_request,'requested_coins',p_coins,
    'amount_paise',v_amount,'amount_inr',v_amount::numeric/100,'status','pending');
end;
$$;
revoke all on function public.hearttalk_request_host_payout(integer) from public,anon;
grant execute on function public.hearttalk_request_host_payout(integer) to authenticated;

create or replace function public.hearttalk_get_host_earnings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_user uuid:=auth.uid();
  v_total bigint;
  v_count bigint;
  v_recent jsonb;
  v_rate integer;
  v_reserved bigint;
  v_requests jsonb;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select coalesce(sum(earned_coins),0),count(*) into v_total,v_count
    from public.hearttalk_host_earnings where host_id=v_user;
  select paise_per_host_coin into v_rate from public.hearttalk_payout_settings where id=true;
  select coalesce(sum(requested_coins),0) into v_reserved
    from public.host_payout_requests
    where host_id=v_user and status in ('pending','approved','paid');
  select coalesce(jsonb_agg(x),'[]'::jsonb) into v_recent from (
    select jsonb_build_object('gift_event_id',e.gift_event_id,'earned_coins',e.earned_coins,
      'created_at',e.created_at,'gift_title',c.title,'emoji',c.emoji) x
    from public.hearttalk_host_earnings e
    join public.hearttalk_gift_events g on g.id=e.gift_event_id
    join public.hearttalk_gift_catalog c on c.gift_code=g.gift_code
    where e.host_id=v_user order by e.created_at desc limit 50
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'requested_coins',requested_coins,
    'amount_paise',requested_amount_paise,'status',status,'created_at',created_at,
    'payout_reference',payout_reference)),'[]'::jsonb)
    into v_requests from public.host_payout_requests where host_id=v_user;
  return jsonb_build_object('earned_coins',v_total,'gift_count',v_count,'history',v_recent,
    'coin_value_paise',v_rate,'earned_amount_paise',v_total*v_rate,
    'available_coins',greatest(v_total-v_reserved,0),
    'available_amount_paise',greatest(v_total-v_reserved,0)*v_rate,
    'cash_withdrawal_enabled',(select requests_enabled from public.hearttalk_payout_settings where id=true),
    'payout_requests',v_requests);
end;
$$;
revoke all on function public.hearttalk_get_host_earnings() from public;
grant execute on function public.hearttalk_get_host_earnings() to authenticated;

create or replace function public.admin_list_host_payout_requests()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then
    raise exception 'Admin access required';
  end if;
  select coalesce(jsonb_agg(x),'[]'::jsonb) into v_result from (
    select jsonb_build_object('id',r.id,'host_id',r.host_id,'host_email',u.email,
      'requested_coins',r.requested_coins,'amount_paise',r.requested_amount_paise,
      'status',r.status,'admin_note',r.admin_note,'payout_reference',r.payout_reference,
      'created_at',r.created_at,'reviewed_at',r.reviewed_at,'paid_at',r.paid_at) x
    from public.host_payout_requests r
    join auth.users u on u.id=r.host_id
    order by r.created_at desc limit 200
  ) q;
  return v_result;
end;
$$;
revoke all on function public.admin_list_host_payout_requests() from public,anon;
grant execute on function public.admin_list_host_payout_requests() to authenticated;

create or replace function public.admin_mark_host_payout_paid(p_request_id uuid,p_payout_reference text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_row public.host_payout_requests%rowtype;
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then
    raise exception 'Admin access required';
  end if;
  if nullif(trim(p_payout_reference),'') is null then
    raise exception 'Enter the bank transfer UTR/reference before marking paid';
  end if;
  select * into v_row from public.host_payout_requests where id=p_request_id for update;
  if not found then raise exception 'Payout request not found'; end if;
  if v_row.status not in ('pending','approved') then
    raise exception 'Only pending or approved requests can be marked paid';
  end if;
  update public.host_payout_requests set status='paid',payout_reference=trim(p_payout_reference),
    reviewed_at=now(),reviewed_by=auth.uid(),paid_at=now() where id=p_request_id;
  return jsonb_build_object('status','paid','request_id',p_request_id);
end;
$$;
revoke all on function public.admin_mark_host_payout_paid(uuid,text) from public,anon;
grant execute on function public.admin_mark_host_payout_paid(uuid,text) to authenticated;

create or replace function public.admin_set_host_payout_requests_enabled(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then
    raise exception 'Admin access required';
  end if;
  update public.hearttalk_payout_settings set requests_enabled=coalesce(p_enabled,false),updated_at=now()
    where id=true;
  return jsonb_build_object('requests_enabled',coalesce(p_enabled,false));
end;
$$;
revoke all on function public.admin_set_host_payout_requests_enabled(boolean) from public,anon;
grant execute on function public.admin_set_host_payout_requests_enabled(boolean) to authenticated;

create or replace function public.admin_review_host_payout_request(
  p_request_id uuid,p_status text,p_note text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_row public.host_payout_requests%rowtype;
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then
    raise exception 'Admin access required';
  end if;
  if p_status not in ('approved','rejected') then
    raise exception 'Review status must be approved or rejected';
  end if;
  select * into v_row from public.host_payout_requests where id=p_request_id for update;
  if not found then raise exception 'Payout request not found'; end if;
  if v_row.status <> 'pending' then raise exception 'Only pending requests can be reviewed'; end if;
  update public.host_payout_requests set status=p_status,admin_note=left(coalesce(p_note,''),500),
    reviewed_at=now(),reviewed_by=auth.uid() where id=p_request_id;
  return jsonb_build_object('status',p_status,'request_id',p_request_id);
end;
$$;
revoke all on function public.admin_review_host_payout_request(uuid,text,text) from public,anon;
grant execute on function public.admin_review_host_payout_request(uuid,text,text) to authenticated;
