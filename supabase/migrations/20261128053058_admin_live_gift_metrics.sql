-- Restore the admin aggregate RPC referenced by the existing Admin Dashboard.
-- Returns aggregate totals only and requires an authenticated HeartTalk admin.
create or replace function public.admin_get_live_gift_metrics()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_host_coins bigint;
  v_gift_count bigint;
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then
    raise exception 'Admin access required';
  end if;

  select coalesce(sum(earned_coins), 0)
    into v_host_coins
  from public.hearttalk_host_earnings;

  select count(*)
    into v_gift_count
  from public.hearttalk_gift_events;

  return jsonb_build_object(
    'host_earned_coins', v_host_coins,
    'gift_count', v_gift_count
  );
end;
$$;

revoke all on function public.admin_get_live_gift_metrics() from public, anon;
grant execute on function public.admin_get_live_gift_metrics() to authenticated;