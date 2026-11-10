-- HeartTalk Admin User Management
-- Run once in Supabase Dashboard > SQL Editor.
-- The existing admin dashboard uses public.hearttalk_user_roles(user_id, role).

alter table public.profiles
  add column if not exists account_status text not null default 'active';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_account_status_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_account_status_check
      check (account_status in ('active','blocked'));
  end if;
end $$;

-- Only an authenticated admin can change another non-admin user's status.
-- The Auth ban is server-side; the anon/authenticated client cannot write auth.users.
create or replace function public.admin_set_user_status(
  target_user_id uuid,
  new_status text
)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if new_status not in ('active','blocked') then
    raise exception 'Invalid account status';
  end if;

  if target_user_id = auth.uid() then
    raise exception 'Admins cannot change their own account status';
  end if;

  if not exists (
    select 1
    from public.hearttalk_user_roles r
    where r.user_id = auth.uid() and r.role = 'admin'
  ) then
    raise exception 'Admin access required';
  end if;

  if exists (
    select 1
    from public.hearttalk_user_roles r
    where r.user_id = target_user_id and r.role = 'admin'
  ) then
    raise exception 'Admin accounts cannot be blocked from this screen';
  end if;

  update public.profiles
  set account_status = new_status,
      updated_at = now()
  where id = target_user_id;

  if not found then
    raise exception 'User profile not found';
  end if;

  update auth.users
  set banned_until = case
    when new_status = 'blocked' then now() + interval '100 years'
    else null
  end
  where id = target_user_id;

  return true;
end;
$$;

revoke all on function public.admin_set_user_status(uuid,text) from public;
grant execute on function public.admin_set_user_status(uuid,text) to authenticated;

-- The app reads public profile fields through the existing authenticated
-- profiles SELECT policy. Account status is displayed only in the admin UI.
