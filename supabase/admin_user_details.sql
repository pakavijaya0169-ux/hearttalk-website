-- HeartTalk: admin-only account detail lookup
-- Run this in Supabase SQL Editor after reviewing the function.
-- Email and last sign-in are read from auth.users and are never exposed
-- through the public profiles table or the browser's direct table query.

create or replace function public.admin_get_user_account_details(target_user_id uuid)
returns table (
  user_id uuid,
  email text,
  phone text,
  auth_created_at timestamptz,
  last_sign_in_at timestamptz,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.hearttalk_user_roles r
    where r.user_id = auth.uid()
      and r.role = 'admin'
  ) then
    raise exception 'Admin access required';
  end if;

  return query
  select
    u.id,
    u.email::text,
    u.phone::text,
    u.created_at,
    u.last_sign_in_at,
    u.email_confirmed_at,
    u.phone_confirmed_at
  from auth.users u
  where u.id = target_user_id
  limit 1;
end;
$$;

revoke all on function public.admin_get_user_account_details(uuid) from public;
grant execute on function public.admin_get_user_account_details(uuid) to authenticated;
