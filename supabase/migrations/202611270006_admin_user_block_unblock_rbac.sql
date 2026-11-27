-- HeartTalk Admin RBAC: secure account block/unblock
-- Preserves the original status validation, self-protection, Super Admin protection,
-- profile update and Supabase Auth ban behavior.
create or replace function public.admin_set_user_status(
  target_user_id uuid,
  new_status text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_hearttalk_admin_permission('users.manage') then
    raise exception 'User management permission required';
  end if;

  if new_status is null or new_status not in ('active','blocked') then
    raise exception 'Invalid account status';
  end if;

  if target_user_id = auth.uid() then
    raise exception 'Admins cannot change their own account status';
  end if;

  if exists (
    select 1 from public.hearttalk_user_roles r
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

  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'user_account_status_changed','user',target_user_id::text,
         jsonb_build_object('status',new_status));

  return true;
end;
$$;

-- Keep the table trigger aligned with the authorized RPC permission model.
create or replace function public.guard_profile_account_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.account_status is distinct from old.account_status
     and not public.has_hearttalk_admin_permission('users.manage') then
    raise exception 'User management permission required to change account status';
  end if;
  return new;
end;
$$;

revoke all on function public.admin_set_user_status(uuid,text) from public,anon;
grant execute on function public.admin_set_user_status(uuid,text) to authenticated;
