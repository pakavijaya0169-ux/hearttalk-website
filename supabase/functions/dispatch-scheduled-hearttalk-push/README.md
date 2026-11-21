# Scheduled HeartTalk push campaigns

## Deploy
Deploy both Edge Functions:
- `send-hearttalk-push`
- `dispatch-scheduled-hearttalk-push`

## Secret
Set the same high-entropy secret in Supabase Edge Function Secrets:
- `SCHEDULED_PUSH_SECRET`

The sender also requires:
- `FIREBASE_SERVICE_ACCOUNT_JSON`

## Schedule
Configure an external scheduler or Supabase scheduled invocation to POST to the dispatcher endpoint every minute:
`https://<project-ref>.supabase.co/functions/v1/dispatch-scheduled-hearttalk-push`

Header:
`Authorization: Bearer <SCHEDULED_PUSH_SECRET>`

Body:
`{}`

The dispatcher sends due campaigns with status `scheduled` and `scheduled_at <= now()`, up to 25 per run. It calls the sender, which atomically claims each campaign to avoid concurrent duplicate sends.

Do not commit the secret. Until a schedule is configured and both functions are deployed, scheduled campaigns will not automatically dispatch.
