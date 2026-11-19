-- HeartTalk Step 1: persist onboarding language and Terms acceptance.
-- Apply after the existing profile/schema migrations.
begin;
alter table public.profiles
  add column if not exists preferred_language text,
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_version text;
alter table public.profiles
  add constraint profiles_preferred_language_check
  check (preferred_language is null or preferred_language in ('Telugu','Hindi','Tamil','English','Kannada','Malayalam'));
commit;
