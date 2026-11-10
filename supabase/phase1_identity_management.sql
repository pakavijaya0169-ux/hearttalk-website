-- HeartTalk Phase 1: User Identity, Profile Review, Identity Blacklist, Staff RBAC
-- Additive migration for the existing Supabase PostgreSQL schema.
-- Run in Supabase SQL Editor while signed in as project owner.

alter table public.profiles
  add column if not exists state text,
  add column if not exists account_status text not null default 'active';

do $$
begin
  if not exists (select 1 from pg_constraint where conname='profiles_account_status_check' and conrelid='public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_account_status_check check (account_status in ('active','blocked'));
  end if;
end $$;

-- Profile approval queue. Existing profiles are approved to avoid unexpectedly
-- hiding the current user base; new/edited public profile content requires review.
create table if not exists public.profile_review_queue (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  submitted_snapshot jsonb not null default '{}'::jsonb,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text
);
alter table public.profile_review_queue enable row level security;
revoke all on public.profile_review_queue from anon, authenticated;

insert into public.profile_review_queue(profile_id,status,submitted_snapshot,reviewed_at)
select p.id,'approved',jsonb_build_object('display_name',p.display_name,'username',p.username,'bio',p.bio,'avatar_url',p.avatar_url),now()
from public.profiles p
on conflict(profile_id) do nothing;

create or replace function public.queue_profile_for_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profile_review_queue(profile_id,status,submitted_snapshot,submitted_at,reviewed_at,reviewed_by,review_note)
  values (
    new.id,
    'pending',
    jsonb_build_object('display_name',new.display_name,'username',new.username,'bio',new.bio,'avatar_url',new.avatar_url),
    now(),null,null,null
  )
  on conflict(profile_id) do update
    set status='pending',
        submitted_snapshot=excluded.submitted_snapshot,
        submitted_at=now(),
        reviewed_at=null,
        reviewed_by=null,
        review_note=null;
  return new;
end;
$$;

drop trigger if exists profiles_queue_review_insert on public.profiles;
create trigger profiles_queue_review_insert
after insert on public.profiles
for each row execute function public.queue_profile_for_review();

drop trigger if exists profiles_queue_review_update on public.profiles;
create trigger profiles_queue_review_update
after update of display_name,username,bio,avatar_url on public.profiles
for each row
when (
  old.display_name is distinct from new.display_name or
  old.username is distinct from new.username or
  old.bio is distinct from new.bio or
  old.avatar_url is distinct from new.avatar_url
)
execute function public.queue_profile_for_review();

-- SECURITY DEFINER lookup avoids profile_review_queue RLS blocking the
-- approval check when another authenticated user views a profile.
create or replace function public.is_profile_approved(target_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from public.profile_review_queue q
    where q.profile_id=target_profile_id and q.status='approved'
  );
$$;
revoke all on function public.is_profile_approved(uuid) from public;
grant execute on function public.is_profile_approved(uuid) to authenticated;

-- Hide unapproved profiles from other users; owners can always see their own.
drop policy if exists "Users can view profiles" on public.profiles;
drop policy if exists "Users can view approved profiles" on public.profiles;
create policy "Users can view approved profiles"
on public.profiles for select to authenticated
using (
  auth.uid() = id
  or public.is_profile_approved(profiles.id)
  or exists (
    select 1 from public.hearttalk_user_roles r
    where r.user_id = auth.uid() and r.role = 'admin'
  )
);

-- Secure searchable user master registry. Email and phone come from auth.users
-- and are returned only through this admin-checked function.
create or replace function public.admin_list_user_registry(
  search_term text default null,
  status_filter text default 'all',
  country_filter text default null,
  date_from timestamptz default null,
  date_to timestamptz default null,
  result_limit integer default 200
)
returns table (
  user_id uuid, display_name text, username text, age integer,
  country text, state text, bio text, avatar_url text,
  account_status text, registered_at timestamptz, email text, phone text
)
language plpgsql
security definer
set search_path = ''
as $$
declare q text := nullif(trim(coalesce(search_term,'')),'');
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then
    raise exception 'Admin access required';
  end if;
  if status_filter not in ('all','active','blocked') then raise exception 'Invalid status filter'; end if;
  return query
  select p.id,p.display_name,p.username,p.age,p.country,p.state,p.bio,p.avatar_url,p.account_status,p.created_at,
         u.email::text,u.phone::text
  from public.profiles p
  join auth.users u on u.id=p.id
  where (status_filter='all' or p.account_status=status_filter)
    and (country_filter is null or country_filter='' or lower(coalesce(p.country,''))=lower(country_filter) or lower(coalesce(p.state,''))=lower(country_filter))
    and (date_from is null or p.created_at>=date_from)
    and (date_to is null or p.created_at<date_to)
    and (q is null or p.id::text ilike '%'||q||'%' or coalesce(p.display_name,'') ilike '%'||q||'%' or coalesce(p.username,'') ilike '%'||q||'%' or coalesce(u.email,'') ilike '%'||q||'%' or coalesce(u.phone,'') ilike '%'||q||'%')
  order by p.created_at desc
  limit greatest(1,least(coalesce(result_limit,200),500));
end;
$$;

create or replace function public.admin_list_profile_review_queue()
returns table (
  user_id uuid, display_name text, username text, bio text, avatar_url text,
  country text, state text, status text, submitted_at timestamptz, review_note text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then
    raise exception 'Admin access required';
  end if;
  return query
  select p.id,p.display_name,p.username,p.bio,p.avatar_url,p.country,p.state,q.status,q.submitted_at,q.review_note
  from public.profile_review_queue q join public.profiles p on p.id=q.profile_id
  where q.status='pending'
  order by q.submitted_at asc limit 500;
end;
$$;

create or replace function public.admin_review_profile(
  target_user_id uuid, decision text, moderator_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then
    raise exception 'Admin access required';
  end if;
  if decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected'; end if;
  update public.profile_review_queue
  set status=decision,reviewed_at=now(),reviewed_by=auth.uid(),review_note=left(moderator_note,1000)
  where profile_id=target_user_id and status='pending';
  if not found then raise exception 'Pending profile review not found'; end if;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'profile_'||decision,'profile',target_user_id::text,jsonb_build_object('note',left(moderator_note,1000)));
  return true;
end;
$$;

-- Privacy-conscious blacklist. Store only SHA-256 hashes of app-generated
-- device tokens or normalized IP addresses. Never collect IMEI/MAC from a browser.
create table if not exists public.identity_blacklist (
  id bigint generated by default as identity primary key,
  identifier_type text not null check (identifier_type in ('device_token_hash','ip_hash')),
  identifier_hash text not null check (identifier_hash ~ '^[a-f0-9]{64}$'),
  reason text not null check (char_length(reason) between 3 and 500),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  active boolean not null default true,
  unique(identifier_type,identifier_hash)
);
alter table public.identity_blacklist enable row level security;
revoke all on public.identity_blacklist from anon,authenticated;

create or replace function public.admin_add_identity_blacklist(
  identifier_type text, identifier_hash text, reason text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare new_id bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then raise exception 'Admin access required'; end if;
  if identifier_type not in ('device_token_hash','ip_hash') or identifier_hash !~ '^[a-f0-9]{64}$' then raise exception 'Invalid hashed identifier'; end if;
  insert into public.identity_blacklist(identifier_type,identifier_hash,reason,created_by)
  values(identifier_type,identifier_hash,left(reason,500),auth.uid())
  on conflict(identifier_type,identifier_hash) do update set active=true,reason=excluded.reason
  returning id into new_id;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'identity_blacklisted','identity_hash',new_id::text,jsonb_build_object('type',identifier_type,'reason',left(reason,500)));
  return new_id;
end;
$$;

create or replace function public.admin_list_identity_blacklist()
returns table(id bigint,identifier_type text,identifier_hash text,reason text,created_at timestamptz,active boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then raise exception 'Admin access required'; end if;
  return query select b.id,b.identifier_type,b.identifier_hash,b.reason,b.created_at,b.active from public.identity_blacklist b order by b.created_at desc limit 500;
end;
$$;

create or replace function public.admin_set_blacklist_active(target_id bigint, is_active boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then raise exception 'Admin access required'; end if;
  update public.identity_blacklist set active=is_active where id=target_id;
  if not found then raise exception 'Blacklist entry not found'; end if;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'identity_blacklist_toggled','identity_hash',target_id::text,jsonb_build_object('active',is_active));
  return true;
end;
$$;

-- Prevent ordinary users from bypassing the admin account-status RPC.
create or replace function public.guard_profile_account_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.account_status is distinct from old.account_status
     and not exists (
       select 1 from public.hearttalk_user_roles r
       where r.user_id=auth.uid() and r.role='admin'
     ) then
    raise exception 'Only an administrator can change account status';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_guard_account_status on public.profiles;
create trigger profiles_guard_account_status
before update of account_status on public.profiles
for each row execute function public.guard_profile_account_status();

-- RBAC staff assignments. Existing hearttalk_user_roles role='admin' remains
-- the Super Admin authority; these narrower roles do not grant admin RPC access.
create table if not exists public.hearttalk_admin_staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  staff_role text not null check (staff_role in ('agency_manager','moderator','support')),
  assigned_by uuid not null references auth.users(id),
  assigned_at timestamptz not null default now()
);
alter table public.hearttalk_admin_staff_roles enable row level security;
revoke all on public.hearttalk_admin_staff_roles from anon,authenticated;

create or replace function public.admin_list_staff_roles()
returns table(user_id uuid,email text,staff_role text,assigned_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then raise exception 'Admin access required'; end if;
  return query select s.user_id,u.email::text,s.staff_role,s.assigned_at
  from public.hearttalk_admin_staff_roles s join auth.users u on u.id=s.user_id order by s.assigned_at desc;
end;
$$;

create or replace function public.admin_set_staff_role(target_user_id uuid,new_staff_role text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.hearttalk_user_roles r where r.user_id=auth.uid() and r.role='admin') then raise exception 'Admin access required'; end if;
  if new_staff_role not in ('agency_manager','moderator','support','remove') then raise exception 'Invalid staff role'; end if;
  if exists(select 1 from public.hearttalk_user_roles r where r.user_id=target_user_id and r.role='admin') then raise exception 'Super Admin role cannot be changed here'; end if;
  if new_staff_role='remove' then
    delete from public.hearttalk_admin_staff_roles where user_id=target_user_id;
  else
    insert into public.hearttalk_admin_staff_roles(user_id,staff_role,assigned_by)
    values(target_user_id,new_staff_role,auth.uid())
    on conflict(user_id) do update set staff_role=excluded.staff_role,assigned_by=auth.uid(),assigned_at=now();
  end if;
  insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
  values(auth.uid(),'staff_role_changed','user',target_user_id::text,jsonb_build_object('role',new_staff_role));
  return true;
end;
$$;

revoke all on function public.admin_list_user_registry(text,text,text,timestamptz,timestamptz,integer) from public;
revoke all on function public.admin_list_profile_review_queue() from public;
revoke all on function public.admin_review_profile(uuid,text,text) from public;
revoke all on function public.admin_add_identity_blacklist(text,text,text) from public;
revoke all on function public.admin_list_identity_blacklist() from public;
revoke all on function public.admin_set_blacklist_active(bigint,boolean) from public;
revoke all on function public.admin_list_staff_roles() from public;
revoke all on function public.admin_set_staff_role(uuid,text) from public;
grant execute on function public.admin_list_user_registry(text,text,text,timestamptz,timestamptz,integer) to authenticated;
grant execute on function public.admin_list_profile_review_queue() to authenticated;
grant execute on function public.admin_review_profile(uuid,text,text) to authenticated;
grant execute on function public.admin_add_identity_blacklist(text,text,text) to authenticated;
grant execute on function public.admin_list_identity_blacklist() to authenticated;
grant execute on function public.admin_set_blacklist_active(bigint,boolean) to authenticated;
grant execute on function public.admin_list_staff_roles() to authenticated;
grant execute on function public.admin_set_staff_role(uuid,text) to authenticated;
