-- HeartTalk own-SIM SMS gateway queue.
-- Run once in Supabase SQL Editor. OTP values are private to service-role Edge Functions.
create table if not exists public.hearttalk_sms_queue (
  id bigint generated always as identity primary key,
  phone text not null check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  message text not null,
  status text not null default 'pending' check (status in ('pending','processing','sent','failed')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '60 seconds'),
  locked_at timestamptz,
  sent_at timestamptz,
  error text
);
create index if not exists hearttalk_sms_queue_pending_idx
  on public.hearttalk_sms_queue (created_at) where status = 'pending';
alter table public.hearttalk_sms_queue enable row level security;
revoke all on public.hearttalk_sms_queue from anon, authenticated;
