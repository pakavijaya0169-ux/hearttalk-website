-- HeartTalk push campaign audience expansion and FCM payload metadata
-- Run once in Supabase SQL Editor after the admin UI update.

alter table public.hearttalk_push_campaigns
  drop constraint if exists hearttalk_push_campaigns_audience_check;

alter table public.hearttalk_push_campaigns
  add constraint hearttalk_push_campaigns_audience_check
  check (audience in ('all','active','hosts','selected','female','male'));

alter table public.hearttalk_push_campaigns
  add column if not exists payload_json jsonb;

comment on column public.hearttalk_push_campaigns.payload_json is
  'FCM HTTP v1 message payload template. Actual device token and gender-filtered recipient list are supplied by the trusted sender Edge Function.';
