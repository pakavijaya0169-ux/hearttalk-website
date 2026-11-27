-- HeartTalk admin usage monitor (read-only metrics; no user/payment data changes)
create or replace function public.hearttalk_admin_usage_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_db_bytes bigint := 0;
  v_storage_bytes bigint := 0;
  v_bucket jsonb := '{}'::jsonb;
begin
  select r.role into v_role
  from public.hearttalk_user_roles r
  where r.user_id = auth.uid()
  limit 1;

  if coalesce(v_role, '') <> 'admin' then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select pg_catalog.pg_database_size(current_database()) into v_db_bytes;

  select coalesce(sum((o.metadata->>'size')::bigint), 0)
    into v_storage_bytes
  from storage.objects o
  where o.metadata ? 'size'
    and (o.metadata->>'size') ~ '^[0-9]+$';

  select coalesce(jsonb_object_agg(bucket_id, bytes), '{}'::jsonb)
    into v_bucket
  from (
    select o.bucket_id, sum((o.metadata->>'size')::bigint) as bytes
    from storage.objects o
    where o.metadata ? 'size'
      and (o.metadata->>'size') ~ '^[0-9]+$'
    group by o.bucket_id
  ) b;

  return jsonb_build_object(
    'measured_at', now(),
    'database_bytes', v_db_bytes,
    'storage_bytes', v_storage_bytes,
    'storage_by_bucket_bytes', v_bucket,
    'limits', jsonb_build_object(
      'database_bytes', 524288000,
      'storage_bytes', 1073741824,
      'egress_bytes', 5368709120
    ),
    'external_metrics', jsonb_build_object(
      'supabase_egress', 'Not available from this SQL snapshot; check Supabase Usage dashboard',
      'livekit_minutes', 'Not connected to LiveKit usage API; check LiveKit Cloud Usage dashboard',
      'monthly_active_users', 'Not available from this SQL snapshot; check Supabase Usage dashboard'
    )
  );
end;
$$;

revoke all on function public.hearttalk_admin_usage_snapshot() from public;
grant execute on function public.hearttalk_admin_usage_snapshot() to authenticated;
