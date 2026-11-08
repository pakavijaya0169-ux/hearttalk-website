# HeartTalk LiveKit setup

The browser must never receive the LiveKit API secret. The `livekit-token` Supabase Edge Function signs short-lived participant tokens on the server after checking the signed-in user and live-room permissions.

## 1. Create LiveKit credentials
1. Open https://cloud.livekit.io/ and create a LiveKit Cloud project.
2. Copy the project's WebSocket URL (starts with `wss://`), API key, and API secret.
3. Do not paste the API secret into GitHub, the website, or a chat message.

## 2. Add Supabase Edge Function secrets
In the Supabase project `dognojmymhlaewrjqswz`, open Edge Functions > Secrets and add:
- `LIVEKIT_URL` = the LiveKit project's `wss://...` URL
- `LIVEKIT_API_KEY` = LiveKit API key
- `LIVEKIT_API_SECRET` = LiveKit API secret

Supabase supplies `SUPABASE_URL` and `SUPABASE_ANON_KEY` to Edge Functions automatically.

## 3. Deploy the Edge Function
Deploy `supabase/functions/livekit-token/index.ts` as a function named `livekit-token`.
With the Supabase CLI:
```sh
supabase login
supabase link --project-ref dognojmymhlaewrjqswz
supabase functions deploy livekit-token
```
If deploying from the dashboard editor, create a function named exactly `livekit-token` and paste the full contents of `supabase/functions/livekit-token/index.ts`.

## 4. Apply the SQL permission migration
Run `supabase/migrations/202611080001_livekit_host_membership.sql` in Supabase Dashboard > SQL Editor.

## 5. Test
Sign in to HeartTalk with two separate accounts. Account A creates a room; account B joins from Live rooms. Allow microphone/camera permissions in the browser. The host can mute, turn off camera, and end the room.

The token function issues 15-minute tokens and only grants publishing permission to the room host. It checks the current Supabase user and room status before issuing a token.
