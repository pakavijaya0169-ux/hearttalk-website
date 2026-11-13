# HeartTalk secure OTP backend foundation

This branch adds a private OTP challenge store and provider-adapter Edge Functions.

## Important current boundary
This is a backend foundation only. It is NOT wired into the live login UI and does NOT create a Supabase Auth session. Do not switch production login to these endpoints until a trusted phone-verification-to-Supabase-session exchange is implemented and tested. Existing Supabase Phone Auth remains the only login/session mechanism.

## Apply database SQL
Run `supabase/hearttalk_secure_otp.sql` in the Supabase SQL Editor.

## Deploy functions
Deploy `request-phone-otp` and `verify-phone-otp` as Supabase Edge Functions.

## Required Edge Function secrets
- `OTP_PEPPER`: long random secret, distinct from all other keys.
- `SMS_GATEWAY_URL`: HTTPS endpoint for the selected SMS provider.
- `SMS_GATEWAY_API_KEY`: provider API key.

The provider adapter currently expects an HTTPS POST with Bearer auth and JSON body `{ "to": "+91...", "message": "..." }`; a 2xx response means accepted. This is a generic adapter contract, not a real configured provider. Never put provider credentials or the Supabase service-role key in browser code.

## Protections included
- HMAC-SHA256 OTP hashes (raw OTP is never stored).
- 5-minute expiry, 60-second resend cooldown.
- Maximum 5 requests per phone per hour.
- Maximum 5 verification attempts per challenge.
- Single-use challenge after success.
- RLS enabled and browser roles denied table access.

## Before production
1. Select and configure a real SMS gateway and confirm Indian sender/template/DLT requirements.
2. Add IP/device-level abuse controls and monitoring at the edge gateway/WAF.
3. Implement a trusted Supabase Auth session exchange after phone verification; do not trust a client-supplied `phone_verified` flag.
4. Add automated tests and end-to-end tests on real Indian mobile networks.
