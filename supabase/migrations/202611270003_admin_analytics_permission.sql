-- HeartTalk Admin Security Upgrade - Phase 3: analytics permission enforcement
-- Requires the Phase 1 permission foundation and Phase 2 finance security migration.
-- Keeps the existing analytics response fields and calculations unchanged.

create or replace function public.admin_get_analytics(days_back integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_days integer := greatest(7, least(coalesce(days_back, 7), 30));
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_hearttalk_admin_permission('analytics.finance') then
    raise exception 'Finance analytics permission required';
  end if;

  select jsonb_build_object(
    'period_days', v_days,
    'generated_at', now(),
    'users_total', (select count(*) from public.profiles),
    'users_new_period', (select count(*) from public.profiles where created_at >= now() - make_interval(days => v_days)),
    'messages_total', (select count(*) from public.messages),
    'messages_period', (select count(*) from public.messages where created_at >= now() - make_interval(days => v_days)),
    'calls_total', (select count(*) from public.call_sessions),
    'calls_period', (select count(*) from public.call_sessions where created_at >= now() - make_interval(days => v_days)),
    'live_rooms_total', (select count(*) from public.live_rooms),
    'live_rooms_active', (select count(*) from public.live_rooms where status = 'live'),
    'forum_posts_total', (select count(*) from public.forum_posts),
    'forum_posts_period', (select count(*) from public.forum_posts where created_at >= now() - make_interval(days => v_days)),
    'subscriptions_total', (select count(*) from public.subscriptions),
    'subscriptions_active', (select count(*) from public.subscriptions where status = 'active'),
    'wallet_purchase_credits', (select coalesce(sum(amount),0) from public.wallet_ledger where entry_type = 'purchase' and amount > 0),
    'wallet_spent_credits', (select coalesce(sum(abs(amount)),0) from public.wallet_ledger where entry_type = 'spend'),
    'wallet_refund_credits', (select coalesce(sum(amount),0) from public.wallet_ledger where entry_type = 'refund' and amount > 0),
    'payment_revenue_paise', (select coalesce(sum(amount_paise),0) from public.payment_transactions where status = 'succeeded' and currency = 'INR'),
    'payment_refunds_paise', (select coalesce(sum(amount_paise),0) from public.payment_transactions where status = 'refunded' and currency = 'INR'),
    'successful_payments', (select count(*) from public.payment_transactions where status = 'succeeded' and currency = 'INR'),
    'reports_open', (select count(*) from public.user_reports where status = 'open'),
    'reports_reviewing', (select count(*) from public.user_reports where status = 'reviewing'),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', d.day::date,
        'signups', (select count(*) from public.profiles p where p.created_at >= d.day and p.created_at < d.day + interval '1 day'),
        'messages', (select count(*) from public.messages m where m.created_at >= d.day and m.created_at < d.day + interval '1 day')
      ) order by d.day)
      from generate_series(current_date - (v_days - 1), current_date, interval '1 day') as d(day)
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_get_analytics(integer) from public, anon;
grant execute on function public.admin_get_analytics(integer) to authenticated;
