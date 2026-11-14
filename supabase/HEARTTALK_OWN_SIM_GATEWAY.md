# HeartTalk own-SIM SMS gateway (development)

This is a private, owner-operated SMS relay. Supabase Auth still creates and verifies the OTP and creates the user session. The Auth Send SMS hook queues the OTP; a separate Android phone with the owner's SIM polls the queue and submits SMS through that SIM.

## Important limitations
- This is not a new mobile network and does not make SMS free. The SIM's carrier must allow outgoing SMS and may charge for each message.
- The Android gateway phone must be online, powered, have SMS permission, and keep the gateway app open. This initial build polls only while the app is open; it is not a production always-on service.
- Do not install the gateway app on ordinary HeartTalk users' phones. It belongs only on a dedicated phone controlled by the operator.
- Android may restrict sideloaded apps using SEND_SMS; Google Play distribution of SMS-permission apps is heavily restricted. This gateway app is for private operator-side testing.
- SMS sending is not proof of handset delivery; the Android API submission callback is not wired to delivery reports in this prototype.
- OTP queue rows contain the OTP message briefly. Access is service-role only; queued messages expire after 60 seconds.

## Setup
1. Run `supabase/hearttalk_sim_sms_queue.sql` once in the Supabase SQL editor.
2. Deploy `hearttalk-send-sms` and `hearttalk-sms-gateway` Edge Functions from this branch. Keep JWT verification disabled for both: the first is authenticated by Supabase's signed Auth Hook; the second checks its own bearer token.
3. In Edge Function Secrets, add `HEARTTALK_SIM_GATEWAY_TOKEN` with a long random secret (at least 32 characters). Do not share it in chat or commit it to GitHub.
4. Keep the existing `SEND_SMS_HOOK_SECRETS` secret. Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions automatically.
5. In Authentication > Hooks, set Send SMS hook URL to `https://<project-ref>.supabase.co/functions/v1/hearttalk-send-sms` and use the same generated signing secret already stored as `SEND_SMS_HOOK_SECRETS`.
6. Build/install the separate Android project in `sms-gateway-android` on the dedicated SIM phone. Enter gateway URL `https://<project-ref>.supabase.co/functions/v1/hearttalk-sms-gateway` and the same `HEARTTALK_SIM_GATEWAY_TOKEN`. Grant SMS permission and tap Start gateway.
7. Test with a real phone number. Confirm carrier SMS charges and local telecom/DLT requirements before sending messages to other people.

## Current state
Source code is committed to branch `feature/hearttalk-own-sim-sms-gateway`. It is not yet deployed to Supabase and the Android APK has not been built. Do not switch the live Auth Hook until both functions and the database table are deployed and tested.