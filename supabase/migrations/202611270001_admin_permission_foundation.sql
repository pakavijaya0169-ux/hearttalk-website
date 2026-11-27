-- HeartTalk Admin Security Upgrade - Phase 1: permission foundation
-- Additive migration. Preserves existing users, staff assignments, and admin modules.
-- Run in Supabase SQL Editor as project owner before enabling staff access.

-- Add the Finance role without removing or rewriting existing staff assignments.
alter table public.hearttalk_admin_staff_roles
  drop constraint if exists hearttalk_admin_staff_roles_staff_role_check;
alter table public.hearttalk_admin_staff_roles
  add constraint hearttalk_admin_staff_roles_staff_role_check
  check (staff_role in ('agency_manager','moderator','support','finance'));

-- Central permission check for future RPC enforcement.
-- Super Admin retains all existing access. Staff receive only explicit permissions.
create or replace function public.has_hearttalk_admin_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    auth.uid() is not null
    and (
      exists (
        select 1
        from public.hearttalk_user_roles r
        where r.user_id = auth.uid()
          and r.role = 'admin'
      )
      or exists (
        select 1
        from public.hearttalk_admin_staff_roles s
        where s.user_id = auth.uid()
          and (
            (s.staff_role = 'finance' and p_permission in (
              'finance.view','payments.manage','withdrawals.manage','analytics.finance'
            ))
            or
            (s.staff_role = 'moderator' and p_permission in (
              'users.view','users.manage','reports.manage','profiles.review','security.manage'
            ))
            or
            (s.staff_role = 'support' and p_permission in (
              'users.view','support.manage'
            ))
            or
            (s.staff_role = 'agency_manager' and p_permission in (
              'agency.view','hosts.view'
            ))
          )
      )
    );
$$;

revoke all on function public.has_hearttalk_admin_permission(text) from public, anon;
grant execute on function public.has_hearttalk_admin_permission(text) to authenticated;

-- Keep role assignment restricted to Super Admin and record every change.
create or replace function public.admin_set_staff_role(target_user_id uuid,new_staff_role text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.hearttalk_user_roles r
    where r.user_id = auth.uid() and r.role = 'admin'
  ) then raise exception 'Super Admin access required'; end if;
  if new_staff_role not in ('agency_manager','moderator','support','finance','remove') then
    raise exception 'Invalid staff role';
  end if;
  if exists (
    select 1 from public.hearttalk_user_roles r
    where r.user_id = target_user_id and r.role = 'admin'
  ) then
    raise exception 'Super Admin role cannot be changed here';
  end if;

  if new_staff_role = 'remove' then
    delete from public.hearttalk_admin_staff_roles where user_id = target_user_id;
  else
    insert into public.hearttalk_admin_staff_roles(user_id,staff_role,assigned_by)
    values(target_user_id,new_staff_role,auth.uid())
    on conflict(user_id) do update
      set staff_role = excluded.staff_role,
          assigned_by = auth.uid(),
          assigned_at = now();
  end if;

  insert into public.hearttalk_admin_audit_log
    (admin_user_id,action,target_type,target_id,details)
  values (
    auth.uid(),'staff_role_changed','user',target_user_id::text,
    jsonb_build_object('role',new_staff_role)
  );
  return true;
end;
$$;

revoke all on function public.admin_set_staff_role(uuid,text) from public, anon;
grant execute on function public.admin_set_staff_role(uuid,text) to authenticated;
