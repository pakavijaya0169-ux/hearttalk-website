-- HeartTalk onboarding terms acceptance. Additive: no existing profile data is deleted or rewritten.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS terms_accepted_at timestamptz;

COMMENT ON COLUMN public.profiles.terms_accepted_at IS
  'Timestamp when the authenticated user accepted HeartTalk Terms and Conditions.';
