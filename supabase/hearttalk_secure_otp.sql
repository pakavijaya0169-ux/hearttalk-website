-- HeartTalk secure phone OTP foundation.
-- Apply in Supabase SQL Editor. Edge Functions use service-role access only.
create extension if not exists pgcrypto;

create table if not exists public.hearttalk_phone_otps (
  id uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  otp_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  attempts smallint not null default 0 check (attempts between 0 and 5),
  request_ip_hash text
);

create index if not exists hearttalk_phone_otps_phone_created_idx
  on public.hearttalk_phone_otps (phone_e164, created_at desc);

alter table public.hearttalk_phone_otps enable row level security;
revoke all on public.hearttalk_phone_otps from anon, authenticated;
grant all on public.hearttalk_phone_otps to service_role;

comment on table public.hearttalk_phone_otps is
  'Private OTP challenge store. Never expose rows to browser clients; service role only.';
