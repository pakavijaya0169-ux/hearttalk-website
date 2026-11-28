# HEARTTALK — MASTER PROGRESS

Last updated: 2026-11-26
Repository: https://github.com/pakavijaya0169-ux/hearttalk-website
Live website: https://pakavijaya0169-ux.github.io/hearttalk-website/
Supabase project: `dognojmymhlaewrjqswz`
Supabase dashboard: https://supabase.com/dashboard/project/dognojmymhlaewrjqswz

> Purpose: This file is the handoff record for continuing HeartTalk work across ChatGPT conversations. Update it after every meaningful code, database, deployment, or testing change. Never store API keys, passwords, access tokens, or other secrets here.

## Working preferences
- User prefers Telugu / simple transliterated Telugu.
- Work one step at a time; be concise and avoid unnecessary explanations.
- User is a beginner and does not use a terminal.
- When possible, inspect and modify the GitHub repository directly rather than asking the user to edit code manually.
- Never claim deployment or testing succeeded unless verified.
- Never ask the user to paste secrets into chat.
- Explain exactly what the user needs to click or verify, one step at a time.

## Technology
- Frontend: HTML/CSS/JavaScript PWA hosted with GitHub Pages.
- Backend: Supabase (Postgres, Auth, Edge Functions).
- Payments: Cashfree Payment Gateway integration (do not confuse with Cashfree Payouts).
- Other planned/used services: Firebase messaging and LiveKit.

## Verified completed work

### Coin packages
The seven active coin packages and UI display were implemented. User confirmed the SQL migrations ran successfully and verified seven active rows.

| Price | Base coins | Bonus coins | Total coins |
|---:|---:|---:|---:|
| ₹20 | 20 | 5 | 25 |
| ₹40 | 40 | 10 | 50 |
| ₹100 | 100 | 20 | 120 |
| ₹150 | 150 | 20 | 170 |
| ₹200 | 200 | 25 | 225 |
| ₹500 | 500 | 30 | 530 |
| ₹1000 | 1000 | 50 | 1050 |

Related migrations:
- `supabase/migrations/202611240002_replace_coin_packages.sql`
- `supabase/migrations/202611240003_coin_packages_public_read_policy.sql`

Relevant commits:
- `0d438d18b62182ea19781c8a20835ab429823788` — initial package UI
- `42f306df218d0119a0609b055e36d4c0ec0b8bbb` — base/bonus display
- `eb790b8d886c460a7969bd7af198936fa09a9a16` — final seven-package migration
- `3a49584e6f914e8ba97af54c87e690d46bae5c5e` — public read policy migration

### Cashfree webhook deployment automation
- GitHub Actions workflow: `.github/workflows/deploy-cashfree-webhook.yml` (updated to deploy both `cashfree-webhook` and `create-cashfree-order`; supports manual `workflow_dispatch` and push changes to the workflow file).
- Repository secret `SUPABASE_ACCESS_TOKEN` was configured by the user. Do not request or expose its value.
- Workflow was corrected to use `--yes` and Supabase CLI version `2.58.5`.
- Latest workflow commits: `c800a52b9c370a157af6c11e1afe7780f4733af4` (adds `create-cashfree-order` deployment step), `2411d1235f9cbe651696e4179c9300224e88faa8` (adds workflow-file push trigger).
- Earlier verified runs: `45538444752` (`cashfree-webhook`) and `45539058729` (`cashfree-webhook` + `create-cashfree-order`).
- Latest workflow commit: `660d7d77bed95b1df51f2c44a3476e18ea17cb12`.
- Latest deployment run: `45539338698` — https://github.com/pakavijaya0169-ux/hearttalk-website/actions/runs/45539338698.
- **Verified success on 2026-11-25:** all three deployment steps succeeded in run `45539338698`: `cashfree-webhook`, `create-cashfree-order`, and `verify-cashfree-payment`. The overall `deploy` job completed with conclusion `success`.

### Cashfree webhook code/config notes
- Webhook handler was fixed so `clientSecret` is declared before use.
- Test events without a HeartTalk order ID are acknowledged with HTTP 200 after signature verification.
- Webhook secret lookup supports `CASHFREE_WEBHOOK_SECRET` with fallback to `CASHFREE_CLIENT_SECRET`.
- Recommended before production: set `CASHFREE_WEBHOOK_SECRET` to the actual webhook signing secret from Cashfree.
- `supabase/config.toml` contains:
  ```toml
  [functions.cashfree-webhook]
  verify_jwt = false
  ```
  This allows Cashfree server-to-server webhook requests.

## Current Cashfree integration state

### Code
- GitHub version of `create-cashfree-order` supports both sandbox and production API endpoints:
  - Sandbox: `https://sandbox.cashfree.com/pg/orders`
  - Production: `https://api.cashfree.com/pg/orders`
- GitHub version of `verify-cashfree-payment` also supports sandbox and production and verifies payment server-side before crediting coins.
- Frontend invokes `create-cashfree-order` and starts Cashfree checkout using the returned environment.
- The earlier sandbox-only `create-cashfree-order` deployment has been superseded by the successful deployment in run `45539338698`.
- User previously reported `CASHFREE_ENV=production`. The actual credential environment and approval status still need verification; do not assume live credentials are valid.

### Account / approval
- Cashfree Payouts product was rejected. This does not automatically mean Cashfree Payment Gateway is rejected.
- Cashfree dashboard previously showed no transactions.
- Do not initiate a real-money production payment until Cashfree Payment Gateway live approval, live API credentials, webhook signing secret, and production configuration are confirmed.
- Sandbox testing should be done first.
- Never misrepresent HeartTalk's business model to a payment provider. The app is a social communication platform with chat/audio/video and host earnings/withdrawals; disclose this accurately.

## Next work — do in this order

1. **Completed:** latest `cashfree-webhook`, `create-cashfree-order`, and `verify-cashfree-payment` deployed successfully to Supabase via GitHub Actions run `45539338698` (all three deploy steps individually verified successful).
2. **Code review completed:** frontend return URL invokes `verify-cashfree-payment` with the order ID after the signed-in session initializes; the Edge Function checks the authenticated owner, Cashfree PAID order, amount/currency, successful payment, then calls the service-role-only RPC.
3. **Verified on 2026-11-25:** user ran a read-only query in the Supabase Production SQL Editor; it returned `credit_verified_cashfree_coin_purchase` as a `FUNCTION`. A second read-only query confirmed `SECURITY DEFINER = true`, `anon EXECUTE = false`, `authenticated EXECUTE = false`, and `service_role EXECUTE = true`.
4. **Production readiness blockers:** Cashfree Payment Gateway live approval, live API credentials, correct webhook signing secret (`CASHFREE_WEBHOOK_SECRET`), `CASHFREE_ENV=production`, and remote RPC migration status must be confirmed before a real charge.
5. Do not test real money until all blockers are verified. Then perform one small controlled live payment and verify exactly-once wallet credit.

### Manual UPI QR host withdrawal implementation (2026-11-25)
- Added migration `supabase/migrations/202611250001_manual_upi_qr_host_withdrawals.sql`; it updates `hearttalk_get_manual_upi_withdrawals()` to return host UPI ID and account holder name with each request. Existing request RPC reserves earnings in `hearttalk_host_cash_ledger` at creation; rejection releases the reserve; paid requests require an approved status and unique UTR.
- Updated host withdrawal history to display a fixed-amount UPI QR for active pending/approved requests, using UPI ID, exact INR amount, account holder name, and a request-specific transaction reference.
- Updated admin withdrawal queue to display the QR only after approval; admin scans/pays manually, enters bank/UPI UTR, then marks the request paid.
- QR is a payment intent, not an automatic transfer or a technical one-time payment token. HeartTalk prevents duplicate request finalization and duplicate UTR; it cannot prevent a payer from scanning the same UPI QR repeatedly. Admin must verify actual bank debit/credit and use the correct unique UTR.
- **Deployment verified:** GitHub Pages run `45550755796` completed with `success` for commit `d977812d962d14948b38aaa67e6979b1efc5c6b4`.
- **User confirmed:** the new migration `202611250001_manual_upi_qr_host_withdrawals.sql` was run successfully in Supabase Production SQL Editor.
- **Still needs functional verification:** test a valid host withdrawal request, confirm QR amount/UPI details, approve it in admin, record a real UTR only after an actual transfer, and verify the balance/reservation lifecycle. No withdrawal has been paid or tested.

## Other product decisions / requirements to preserve
- **Current business rule (2026-11-26):** eligible User↔approved Host call and gift revenue share is Host 50%, HeartTalk 50%. This supersedes older 60/40 and 70/30 notes for new eligible earnings.
- Chat is completely free: 0 coin deductions and 0 new Host earnings. Preserve all historical chat earnings and cash-ledger rows.
- Call pricing (superseded on 2026-11-28): voice 1 coin per completed 60 seconds; video 2 coins per completed 60 seconds; partial minutes are not rounded up. The male User pays for calls in either direction; Host wallet is never charged. The `hearttalk_end_call` function uses floor-based completed-minute billing.
- New eligible call/gift revenue split: 50% Host / 50% HeartTalk. This supersedes prior 60/40 and 70/30 splits for new earnings.
- Login bonus: 10 coins for male Users only; female Hosts receive 0 login bonus. Recharge UI/packages are visible only to male Users; Hosts cannot recharge.
- Product goals include chat, audio/video calls, live streaming, wallet/coins, gifts, admin dashboard, host earnings, withdrawals, moderation and safety.
- User wants horizontal scrolling host profiles on the home screen and language-based host discovery.
- App store positioning must accurately describe social communication/friendship. Do not disguise a dating or paid-host model if that is what the actual functionality amounts to; review platform policies carefully.

## Important security rules
- Never write secrets or tokens into this file, source code, logs, screenshots, or chat.
- The GitHub Actions secret name is `SUPABASE_ACCESS_TOKEN`; its value must remain private.
- The user created a Supabase Personal Access Token with broad project access and no expiry. Recommend revoking/rotating it if it is exposed or no longer needed; do not request its value.
- Do not run production payment tests without explicit confirmation of provider approval and correct live credentials.

## Handoff instruction for the next ChatGPT conversation
Read this file first, then inspect the live GitHub repository and latest GitHub Actions runs before changing anything. All three Cashfree Edge Functions are deployed successfully (run `45539338698`). Frontend verification invocation has been inspected. The 2026-11-26 business-rules migration execution result is unconfirmed; verify the SQL Editor result and inspect production schema before further billing work. Verify Cashfree live approval/credentials/webhook signing secret before any live charge. Never expose secrets or run a production payment without those checks.


### Google sign-in implementation (2026-11-25)
- Added a **Continue with Google** button to the main HeartTalk email-auth modal in `index.html`, preserving the existing email OTP login.
- Added Supabase Auth OAuth call using provider `google` and redirect back to the current HeartTalk page. This adds the frontend flow only.
- **Required manual configuration before Google login can succeed:** enable Google provider in Supabase Authentication > Providers, add Google OAuth Client ID/Secret from Google Cloud, and allow the deployed website redirect URL in Supabase Authentication URL Configuration. Do not put OAuth client secret in frontend code.
- GitHub Pages deployment must complete after the commit; then test Google sign-in on website and APK WebView.

### Admin dashboard audit + Step 1 implementation (2026-11-26)
- Inspected the current `admin/index.html`, the admin foundation/completion migrations, support/error center, analytics SQL, rich push campaign SQL, call session schema, live-room schema, live-room membership schema, chat billing migration, and call/live-room policy migrations.
- Existing Admin modules found: User Registry, Coin Recharge, Profile Review, Host Approvals, Security & RBAC, Reports + audit history, Customer Support, App Errors, Analytics & Revenue, Host Withdrawals, Notifications, Offers, and Commerce.
- Audit gaps confirmed in current code/schema:
  - Staff role records exist, but the Admin UI itself states these roles do not yet grant scoped tool permissions.
  - Push campaigns can be saved/queued, but real delivery depends on device token registration, FCM sender configuration, and scheduled worker health.
  - Analytics reads verified payment transaction records; manual UPI revenue still requires bank reconciliation.
  - Existing admin call/commission logs are historical; there was no unified live operations view for active calls, chats, and rooms.
  - Live-room admin termination needs separate provider-side LiveKit cleanup verification; updating the database room status alone must not be described as proof that the provider room was destroyed.
- **Step 1 code added:** migration `supabase/migrations/202611260001_admin_live_operations_control.sql` adds admin-only RPCs for active call/chat/live-room monitoring and audited admin end-call/end-room actions. It is additive and does not delete or rewrite historical records.
- **Step 1 UI added:** `admin/index.html` now has a Live Operations tab showing active calls, active chat billing sessions, live/scheduled rooms, active member counts, and audited end controls.
- Git commits: SQL migration `c60c2296b09283b5ec368f1c4bc71e42821b2d6c`; Admin UI `19c985da0da6a65635a215dc33ac20be4fa22fe8`.
- **Not yet live/verified:** user must run the new migration in Supabase SQL Editor, then test the Admin Live Operations tab. Do not claim its RPCs are active until SQL execution succeeds.
- **Important limitation:** admin end-call changes `call_sessions.status`; clients poll status and should exit. Admin end-room updates `live_rooms` and member `left_at`; LiveKit provider-side teardown still needs verification.
- Next implementation after Step 1 verification: Step 2 Financial Control Center with read-only reconciliation first, then guarded adjustments/exports; do not change existing wallet, host ledger, or withdrawal history.


### Business rules implementation — free chat and 50/50 call/gift split (2026-11-26)
- Added migration `supabase/migrations/202611260004_free_chat_50_50_call_billing.sql` (commits `dda39312971514f3fe9a3f13d1c8c1ffb7b711a4`, amended `7d58961a937c599da0ef0fcbdea5ac9fd84aeb4a`).
- Chat end-billing now records elapsed time but charges 0 coins and awards 0 new chat earnings. Existing chat sessions, earnings, wallet entries, and cash ledger history are preserved. The trigger that would turn future chat earnings into withdrawable cash is removed; historical rows are not deleted.
- Eligible call billing is server-side in `hearttalk_end_call`: male User is payer regardless of who initiated; only an approved/active Host with approved live-selfie can earn. Voice = 2 coins per started minute; video = 5 coins per started minute; partial minutes round up. If User balance is insufficient at call end, the call still ends but no coins are charged or earned; billing status is marked `insufficient_coins`. This end-of-call-only check is a known billing risk; implement pre-call balance reservation/authorization before production.
- New call earnings are recorded once per call and converted into Host cash ledger at the existing ₹0.50 per Host earning coin. Gift RPC keeps the existing 3-argument idempotency key used by the frontend and applies 50/50 to new gifts.
- **Execution status:** user reported running this migration in Supabase SQL Editor, but the SQL Editor result has not yet been confirmed. Do not mark it applied until the user shares `Success. No rows returned` or the actual error output. A GitHub commit alone does not change the production database.
- **Important verification still required:** confirm exact production schema/permissions and migration result, then test both call directions (male calls Host and Host calls male), audio/video durations, insufficient balance, duplicate end-call retry, free chat, gift retry, and verify the cash ledger/withdrawal balance. Existing balances and withdrawal records must remain unchanged.
- **Migration review correction:** `public.hearttalk_gift_requests` is already created by earlier migration `202611190006_gift_duplicate_charge_protection.sql`, and `hearttalk_chat_sessions.status` explicitly allows `no_charge` in `202611190007_chat_billing_sessions.sql`. For safety, the 2026-11-26 billing migration was amended to create the idempotency table with `IF NOT EXISTS` as well. The call table status constraint does not include `busy`; the migration now maps a requested `busy` end state to the valid database status `missed`.
- **Live database limitation:** repository files confirm these definitions exist in the migration history, but do not prove the corresponding migrations were applied to the user's Supabase project. Verify live table/function state in Supabase before testing calls or gifts.
- Cashfree Payment Gateway remains the coin-recharge provider already integrated through `create-cashfree-order`, `verify-cashfree-payment`, and `cashfree-webhook`. Production readiness still depends on provider live approval, live credentials, actual webhook signing secret, and production environment. Cashfree Payouts remains restricted; do not represent payout transfers as enabled.

## 2026-11-28 — Full audit, native background calls, push path and startup race fixes

### Android background call support (code merged; Gradle build verified)
- Added native HeartTalkCallService in android-app/app/src/main/java/com/hearttalk/app/HeartTalkCallService.java.
- Native foreground service posts an ongoing HeartTalk call notification and holds a partial CPU wake lock while the call is active; it releases the lock when the call ends.
- MainActivity exposes a trusted-origin-only JavaScript bridge (HeartTalkNative.startCall/stopCall).
- Video calls enable Android Picture-in-Picture (auto-enter on Android 12+, onUserLeaveHint fallback on Android 8–11); PiP WebView layout keeps remote video and self-preview visible.
- Manifest declares foreground microphone/camera service types, WAKE_LOCK and PiP activity configuration.
- App version 1.2.0 / versionCode 3. WebRTC local media calls native bridge in APK; cleanup stops the native service. Ordinary web behavior remains unchanged.
- Verified: Android Gradle build run 46109514778 completed success; artifact 15249172204 (debug APK), extracted to /mnt/data/HeartTalk-debug.apk.
- Not yet verified: physical-device continuity switching to WhatsApp/Gallery, screen off, battery optimization, incoming calls while app closed, or PiP across Android/OEM versions. Gradle build alone does not prove device-level media continuity. APK is debug, not signed release.

### Web frontend/PWA
- Updated frontend version to hearttalk-web-2026.11.28 and Service Worker cache to hearttalk-v11.
- Added heartTalkInvokeWhenAvailable guard for races where auth callbacks/view selection call promptHostSelfieAfterLogin, loadHostVerificationStatus, or loadForumFeed before later script definitions load. All 17 inline script blocks pass syntax checks.
- Old app_error_reports for hearttalk-web-2026.11.12 included 39 web + 7 Android promise reports for promptHostSelfieAfterLogin undefined; 2 web + 4 Android runtime reports for loadHostVerificationStatus undefined; 4 web runtime reports for loadForumFeed undefined. Latest source guards the early call sites.
- Pages workflow for commit b4d8200609242aaad0b6ea69be715eda19c2d97a was pending at handoff; verify final outcome and live smoke test. Unauthenticated home and Forums previously rendered without visible errors; authenticated flows remain untested.

### Incoming call push
- The frontend invokes send-hearttalk-call-push, but this function was missing from deployed Supabase functions.
- Deployed GitHub source to Supabase as send-hearttalk-call-push ACTIVE v1, verify_jwt=true.
- Function authenticates caller, confirms caller owns a currently ringing call (maximum 60 seconds), loads enabled recipient FCM tokens, and sends an FCM HTTP v1 high-priority notification.
- Critical remaining configuration: the Firebase service-account key in the uploaded JSON was revoked in Google Cloud because it was exposed. Verify and rotate Supabase Edge secret FIREBASE_SERVICE_ACCOUNT_JSON using a new key securely (never request JSON/key in chat). Until updated, FCM delivery is not verified and push may fail.

### Supabase security audit
- Applied and verified ALTER FUNCTION public.set_profile_updated_at() SET search_path = '' in production. Matching migration added as supabase/migrations/202611280005_set_profile_updated_at_fixed_search_path.sql.
- Security Advisor no longer reports this mutable search_path warning.
- Advisor still reports 16 RLS-enabled tables without client policies (ACL checks show no anon/authenticated table grants except authenticated SELECT on hearttalk_manual_upi_recharges, still blocked by RLS with no policy); 7 anon-executable SECURITY DEFINER trigger/internal functions; 89 authenticated-executable SECURITY DEFINER RPCs; leaked-password protection disabled. Do not blanket revoke access or create broad RLS policies. Audit each function/role and enable leaked-password protection with owner approval.
- Performance Advisor reports 54 missing foreign-key indexes, 76 auth RLS initplan warnings, 15 unused indexes, and 8 multiple permissive policy warnings. Review individually before changes.
- Cashfree Payment Gateway functions/credentials were left untouched. Legacy Razorpay functions remain in place but are not used by the current frontend; do not delete without dependency confirmation.

### Next verification order
1. Confirm GitHub Pages workflow 46109652222 completed successfully and smoke-test the new release.
2. Securely rotate Supabase Edge secret FIREBASE_SERVICE_ACCOUNT_JSON with a new Firebase service-account key.
3. Install debug APK 1.2.0 and test voice call -> Home -> WhatsApp/Gallery -> return; video call -> Home -> PiP; end call from both sides; screen-off and permission behavior.
4. Test logged-in paths: Host selfie onboarding/status, chat media, voice/video calls and completed-minute billing, gift delivery and 50/50 earnings, manual UPI withdrawal flow, Cashfree sandbox purchase/webhook credit, admin moderation and notifications.
5. Continue per-function SECURITY DEFINER and RLS audit; never apply blanket changes.


## 2026-11-28 — Follow-up production audit and fixes

### Verified production fixes
- Read-only production log review identified repeated HTTP 403 responses for `GET /rest/v1/hearttalk_gift_catalog`. Root cause: RLS was enabled, but authenticated users had no SELECT grant and no active-gift read policy.
- Applied additive Supabase migration `gift_catalog_authenticated_read_access` (version `20261128053053`): grants SELECT only to `authenticated`, adds an RLS policy for `active = true`, keeps anonymous SELECT disabled, and leaves purchase RPC validation unchanged.
- Verified with SQL: authenticated SELECT is granted, anon SELECT is false, RLS is enabled, and authenticated role sees 12 active rows only.
- Matching versioned SQL sources were added under `supabase/migrations/`: `20261128053053_gift_catalog_authenticated_read_access.sql` and `20261128053058_admin_live_gift_metrics.sql`. GitHub commits: `6c207b620cb3c6279ebdd0ccc4bf8d9bf64adb6c` and `29b97cbd34a7fc4d7adcfc38a2de7add0ff9c1ff`.
- Post-deployment `app_error_reports` query (from 2026-11-28T04:56:45Z onward) returned no rows. This is not a substitute for signed-in functional testing.
- Admin User Registry mapping fix commit: `235d8cd8fd264a24833940a82cb1f00803e9d3c4`. Pages run `46112691833` succeeded for build and deploy. The public smoke test was unauthenticated; user registry Block/Unblock actions still need a real admin browser verification.

- Production Admin UI called `admin_get_live_gift_metrics`, but that RPC was absent from the live database. Restored the original aggregate admin-only function from repository migration `202611210001_admin_live_gift_metrics.sql` as additive migration `admin_live_gift_metrics` (version `20261128053058`).
- Verified RPC permissions: SECURITY DEFINER, anon EXECUTE false, authenticated EXECUTE true, with internal `is_hearttalk_admin()` check. Simulated admin-context call returned the existing aggregate of 18 Host reward coins and 2 gifts.
- Live gift ledger/constraint audit: current constraint requires `host_share_coins = coin_price` and `platform_share_coins = coin_price`, while each side's cash value is `coin_price * 50 paise`. Both existing rows satisfy the intended ₹0.50 + ₹0.50 accounting. Two historical constraint failures were observed during the transition; no additional constraint change was made.

### Admin User Registry ID/date mapping fix
- Production function `admin_list_user_registry` returns `user_id` and `registered_at`; Admin UI expected `id` and `created_at`. Live Postgres logs showed two RPC failures caused by `target_user_id = "undefined"`.
- Updated only the normalization line in `admin/index.html`: maps `user_id` to `id` and `registered_at` to `created_at`, retaining existing properties and UI behavior.
- Commit: `235d8cd8fd264a24833940a82cb1f00803e9d3c4`.
- GitHub Pages run `46112691833` completed successfully: build, deploy, and report-build-status all succeeded.
- Read-only website smoke test completed after deployment: public homepage loaded, Home → Forums → Home navigation worked, Forums sub-tabs rendered, legal links were present, and no visible uncaught JavaScript errors were encountered in the unauthenticated test. Authenticated user/host/call/purchase flows were not tested by this smoke test.

### Current audit limits / remaining verification
- The latest Supabase migration API reports 14 tracked migrations after these two additions; this is not equivalent to proving every older SQL Editor migration is absent. Verify each important production object directly rather than relying on the migration count.
- The frontend currently invokes 9 Edge Function endpoints; all 9 were found ACTIVE in Supabase at this audit.
- Security Advisor still reports 7 anon-executable SECURITY DEFINER functions, 90 authenticated-executable SECURITY DEFINER functions, and leaked-password protection disabled. Review each function's intended caller and auth check individually; do not blanket revoke.
- Performance Advisor still reports 54 unindexed foreign keys, 76 RLS initplan warnings, 14 unused indexes, and 8 multiple permissive-policy warnings. No bulk index or policy changes were made.
- Cashfree Payouts remains sandbox-only. No payout transfer was initiated; the read-only connectivity check has not yet been confirmed through the Admin UI. The initiation handler keeps requests in `processing` after ambiguous/non-OK provider responses, so implement/verify a safe reconcile-and-recovery flow before any sandbox transfer tests.
- Firebase Google Cloud service-account key list was read-only verified: two active keys remain; the two old exposed IDs are absent. Supabase secret `FIREBASE_SERVICE_ACCOUNT_JSON` still needs secure rotation with a new credential through the Dashboard. Do not put its JSON value into chat or GitHub.
- Physical Android tests remain outstanding (background call continuity, screen off, PiP, notification permission, battery optimization, incoming call when app closed). The current APK artifact is debug, not a signed release.
- No claim that the entire app is bug-free or production-ready is warranted until authenticated end-to-end tests are completed.
