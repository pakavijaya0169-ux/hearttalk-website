-- HeartTalk Phase 1: secure role foundation for Admin Panel and moderation.
-- Additive migration. Safe to run more than once.
-- IMPORTANT: never grant admin from the browser/client. Assign roles only from Supabase SQL
-- Editor while signed in as project owner, or from a trusted server using service_role.

create table if not exists public.hearttalk_user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'moderator', 'support')),
  created_at timestamptz not null default now()
);

alter table public.hearttalk_user_roles enable row level security;

-- A member can see only their own role. Admins can inspect all roles.
create or replace function public.is_hearttalk_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.hearttalk_user_roles r
    where r.user_id = auth.uid()
      and r.role = 'admin'
  );
$$;

revoke all on function public.is_hearttalk_admin() from public;
grant execute on function public.is_hearttalk_admin() to authenticated;

drop policy if exists "Members can read own HeartTalk role" on public.hearttalk_user_roles;
create policy "Members can read own HeartTalk role"
on public.hearttalk_user_roles
for select to authenticated
using (user_id = auth.uid() or public.is_hearttalk_admin());

drop policy if exists "Admins can read all HeartTalk roles" on public.hearttalk_user_roles;
create policy "Admins can read all HeartTalk roles"
on public.hearttalk_user_roles
for select to authenticated
using (public.is_hearttalk_admin());

-- No authenticated/anonymous client can grant or change roles.
revoke insert, update, delete, truncate, references, trigger
on public.hearttalk_user_roles from anon, authenticated;
grant select on public.hearttalk_user_roles to authenticated;

-- Admins/moderators can review reports. Ordinary users retain the existing
-- policy that lets them submit and view only reports they created.
drop policy if exists "HeartTalk admins can review reports" on public.user_reports;
create policy "HeartTalk admins can review reports"
on public.user_reports
for select to authenticated
using (public.is_hearttalk_admin());

drop policy if exists "HeartTalk admins can update report status" on public.user_reports;
create policy "HeartTalk admins can update report status"
on public.user_reports
for update to authenticated
using (public.is_hearttalk_admin())
with check (public.is_hearttalk_admin());

grant select, update on public.user_reports to authenticated;

-- Helpful indexes for moderation queue and role lookups.
create index if not exists user_reports_status_created_idx
on public.user_reports(status, created_at desc);

-- Verification queries (run separately after this migration):
-- select public.is_hearttalk_admin();
-- select * from public.hearttalk_user_roles where user_id = auth.uid();
-- select id, reporter_id, reported_user_id, reason, status, created_at
-- from public.user_reports order by created_at desc limit 20;
