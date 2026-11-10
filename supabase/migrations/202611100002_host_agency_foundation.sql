-- HeartTalk India Phase 1B: female host and agency foundation
-- Additive migration. Preserves existing profiles, auth users, rooms, wallets and admin roles.
-- Run in Supabase SQL Editor only after reviewing the existing project state.
-- Never store full Aadhaar/PAN numbers or public document URLs in these tables.

create table if not exists public.host_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  preferred_language text not null default 'te'
    check (preferred_language in ('te','hi','ta','kn','mr','pa','bn','ml','en')),
  intro text not null default '' check (char_length(intro) <= 1000),
  status text not null default 'pending'
    check (status in ('pending','under_review','approved','rejected','withdrawn')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text check (review_note is null or char_length(review_note) <= 1000)
);

create index if not exists host_applications_status_submitted_idx
  on public.host_applications(status, submitted_at);

create table if not exists public.hosts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  host_status text not null default 'active'
    check (host_status in ('active','paused','suspended','removed')),
  approved_at timestamptz not null default now(),
  approved_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists hosts_status_created_idx
  on public.hosts(host_status, created_at desc);

create table if not exists public.host_kyc_documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  document_type text not null
    check (document_type in ('aadhaar','pan','video_selfie')),
  storage_object_path text not null unique,
  masked_reference text,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','expired')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text check (review_note is null or char_length(review_note) <= 1000)
);

create index if not exists host_kyc_user_status_idx
  on public.host_kyc_documents(user_id, status, submitted_at desc);

create table if not exists public.agencies (
  id uuid primary key default gen_random_uuid(),
  agency_name text not null check (char_length(agency_name) between 2 and 120),
  referral_code text not null unique
    check (referral_code ~ '^[A-Z0-9]{6,16}$'),
  contact_email text,
  contact_phone text,
  state text not null,
  status text not null default 'pending'
    check (status in ('pending','active','suspended','closed')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists agencies_state_status_idx
  on public.agencies(state, status);

create table if not exists public.agency_host_assignments (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete restrict,
  host_user_id uuid not null references public.hosts(user_id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  ended_at timestamptz,
  active boolean not null default true,
  unique (agency_id, host_user_id, assigned_at),
  check (ended_at is null or ended_at >= assigned_at)
);

create unique index if not exists one_active_agency_per_host_idx
  on public.agency_host_assignments(host_user_id) where active = true;

create table if not exists public.host_commission_rules (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid references public.agencies(id) on delete restrict,
  platform_bps integer not null check (platform_bps between 0 and 10000),
  agency_bps integer not null check (agency_bps between 0 and 10000),
  host_bps integer not null check (host_bps between 0 and 10000),
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (platform_bps + agency_bps + host_bps = 10000),
  check (effective_to is null or effective_to > effective_from),
  check (agency_id is not null or agency_bps = 0)
);

create index if not exists host_commission_rules_active_idx
  on public.host_commission_rules(active, effective_from desc);

create table if not exists public.host_attendance_sessions (
  id uuid primary key default gen_random_uuid(),
  host_user_id uuid not null references public.hosts(user_id) on delete restrict,
  started_at timestamptz not null,
  ended_at timestamptz,
  source text not null default 'live_room'
    check (source in ('live_room','one_to_one_call','manual_adjustment')),
  source_id uuid,
  created_at timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at)
);

create index if not exists host_attendance_host_started_idx
  on public.host_attendance_sessions(host_user_id, started_at desc);

-- RLS: host applications and KYC are private. Admin access is checked using
-- the existing public.is_hearttalk_admin() security-definer helper.
alter table public.host_applications enable row level security;
alter table public.hosts enable row level security;
alter table public.host_kyc_documents enable row level security;
alter table public.agencies enable row level security;
alter table public.agency_host_assignments enable row level security;
alter table public.host_commission_rules enable row level security;
alter table public.host_attendance_sessions enable row level security;

revoke all on public.host_applications, public.hosts, public.host_kyc_documents,
  public.agencies, public.agency_host_assignments, public.host_commission_rules,
  public.host_attendance_sessions from anon, authenticated;

grant select on public.host_applications, public.hosts, public.host_kyc_documents
  to authenticated;

drop policy if exists "Applicants and admins can read host applications" on public.host_applications;
create policy "Applicants and admins can read host applications"
on public.host_applications for select to authenticated
using (user_id = auth.uid() or public.is_hearttalk_admin());

drop policy if exists "Hosts and admins can read host status" on public.hosts;
create policy "Hosts and admins can read host status"
on public.hosts for select to authenticated
using (user_id = auth.uid() or (host_status = 'active') or public.is_hearttalk_admin());

drop policy if exists "Applicants and admins can read KYC metadata" on public.host_kyc_documents;
create policy "Applicants and admins can read KYC metadata"
on public.host_kyc_documents for select to authenticated
using (user_id = auth.uid() or public.is_hearttalk_admin());

-- Host applications are submitted through this checked RPC, not direct table writes.
create or replace function public.submit_host_application(
  p_preferred_language text default 'te',
  p_intro text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gender text;
  v_age integer;
  v_account_status text;
  v_application_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select lower(coalesce(p.gender,'')), p.age, p.account_status
    into v_gender, v_age, v_account_status
  from public.profiles p
  where p.id = auth.uid();

  if not found then raise exception 'Profile not found'; end if;
  if v_gender <> 'female' then raise exception 'Only eligible female profiles can apply for official hosting'; end if;
  if v_age is null or v_age < 18 then raise exception 'Applicants must be at least 18 years old'; end if;
  if v_account_status <> 'active' then raise exception 'Account is not active'; end if;
  if p_preferred_language not in ('te','hi','ta','kn','mr','pa','bn','ml','en') then
    raise exception 'Unsupported language';
  end if;

  insert into public.host_applications(user_id, preferred_language, intro)
  values(auth.uid(), p_preferred_language, left(coalesce(p_intro,''),1000))
  returning id into v_application_id;

  return v_application_id;
exception
  when unique_violation then
    raise exception 'A host application already exists for this account';
end;
$$;

revoke all on function public.submit_host_application(text,text) from public;
grant execute on function public.submit_host_application(text,text) to authenticated;

-- Only Super Admin can approve/reject an application. Approval creates the host
-- record; applicants cannot grant themselves host status.
create or replace function public.admin_review_host_application(
  p_application_id uuid,
  p_decision text,
  p_review_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_gender text;
  v_age integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected';
  end if;

  select a.user_id into v_user_id
  from public.host_applications a
  where a.id = p_application_id
  for update;

  if not found then raise exception 'Host application not found'; end if;

  select lower(coalesce(p.gender,'')), p.age
    into v_gender, v_age
  from public.profiles p
  where p.id = v_user_id;

  if p_decision = 'approved' and (v_gender <> 'female' or v_age is null or v_age < 18) then
    raise exception 'Applicant no longer meets female host eligibility requirements';
  end if;

  update public.host_applications
  set status = p_decision,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = left(p_review_note,1000)
  where id = p_application_id;

  if p_decision = 'approved' then
    insert into public.hosts(user_id, host_status, approved_at, approved_by)
    values(v_user_id, 'active', now(), auth.uid())
    on conflict(user_id) do update
      set host_status = 'active',
          approved_at = now(),
          approved_by = auth.uid(),
          updated_at = now();
  end if;

  insert into public.hearttalk_admin_audit_log
    (admin_user_id, action, target_type, target_id, details)
  values
    (auth.uid(), 'host_application_' || p_decision, 'host_application',
     p_application_id::text,
     jsonb_build_object('user_id', v_user_id, 'review_note', left(p_review_note,1000)));

  return true;
end;
$$;

revoke all on function public.admin_review_host_application(uuid,text,text) from public;
grant execute on function public.admin_review_host_application(uuid,text,text) to authenticated;

-- KYC metadata can be added only by the applicant and only for their own application.
-- The actual object must be uploaded to a PRIVATE Supabase Storage bucket; bucket
-- policies are a separate setup step and must restrict paths to auth.uid().
grant insert on public.host_kyc_documents to authenticated;
drop policy if exists "Applicants can submit own KYC metadata" on public.host_kyc_documents;
create policy "Applicants can submit own KYC metadata"
on public.host_kyc_documents for insert to authenticated
with check (
  user_id = auth.uid()
  and status = 'pending'
  and reviewed_at is null
  and reviewed_by is null
  and exists (
    select 1 from public.host_applications a
    where a.user_id = auth.uid()
      and a.status in ('pending','under_review')
  )
);

-- Attendance is written only by trusted server functions (service_role), not by browsers.
revoke all on public.host_attendance_sessions from anon, authenticated;
grant all on public.host_attendance_sessions to service_role;

-- Agency, assignment and commission configuration is admin-only for this phase.
drop policy if exists "Admins can read agencies" on public.agencies;
create policy "Admins can read agencies"
on public.agencies for select to authenticated using (public.is_hearttalk_admin());

drop policy if exists "Admins can read agency host assignments" on public.agency_host_assignments;
create policy "Admins can read agency host assignments"
on public.agency_host_assignments for select to authenticated using (public.is_hearttalk_admin());

drop policy if exists "Admins can read host commission rules" on public.host_commission_rules;
create policy "Admins can read host commission rules"
on public.host_commission_rules for select to authenticated using (public.is_hearttalk_admin());

grant select on public.agencies, public.agency_host_assignments, public.host_commission_rules
  to authenticated;

-- Verification: these should list the new tables and RPCs after the migration.
-- select table_name from information_schema.tables
-- where table_schema='public' and table_name in
-- ('host_applications','hosts','host_kyc_documents','agencies',
--  'agency_host_assignments','host_commission_rules','host_attendance_sessions');
