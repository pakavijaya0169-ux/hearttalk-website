# HeartTalk Commerce + Razorpay TEST Mode Setup

This change adds the shared commerce backend used by the website and Android WebView APK.

## Before testing
1. Apply `supabase/schema.sql` if it has not already been applied.
2. Ensure the HeartTalk admin-role foundation is installed: `supabase/migrations/202611100001_security_admin_foundation.sql`.
3. Run `supabase/migrations/202611120001_commerce_payments_activation.sql` in Supabase Dashboard → SQL Editor.
4. Deploy the three Edge Functions:
   ```sh
   supabase functions deploy create-razorpay-order
   supabase functions deploy verify-razorpay-payment
   supabase functions deploy razorpay-webhook --no-verify-jwt
   ```
5. Add Supabase Edge Function secrets. Use TEST keys only:
   ```sh
   supabase secrets set RAZORPAY_KEY_ID=rzp_test_xxxxxxxxxx
   supabase secrets set RAZORPAY_KEY_SECRET=your_test_key_secret
   supabase secrets set RAZORPAY_WEBHOOK_SECRET=your_webhook_secret
   ```
   Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. If your project does not expose one of these defaults, set it in Edge Function secrets.
6. In Razorpay Dashboard TEST MODE, add a webhook URL:
   `https://dognojmymhlaewrjqswz.supabase.co/functions/v1/razorpay-webhook`
   Subscribe to `payment.captured`, then copy the webhook secret into `RAZORPAY_WEBHOOK_SECRET`.
7. Wait for GitHub Pages to publish the updated `index.html` and `admin/index.html`. The Android app loads the same hosted website URL, so the commerce UI is shared by web and APK.

## Security design
- Coin package price and coin quantity are read from the database; the browser cannot set either.
- The order is created server-side with Razorpay.
- Checkout signature is verified server-side and the Razorpay payment is fetched to confirm captured status, amount and currency.
- A service-role-only SQL function credits the wallet ledger once. Repeated verification/webhook delivery is idempotent.
- Admin transaction records are exposed only through an admin-checked RPC.
- Host gift earnings are tracked as coins. They are not rupees and cannot be withdrawn as cash in this phase.

## Important
Do not add Razorpay secrets to HTML, JavaScript, GitHub, APK resources, or any client-side settings. Never use TEST credentials for real customers. Do not switch to LIVE keys until Razorpay merchant approval, business/KYC/tax requirements, refund handling, terms, and payout compliance are complete.


## Admin Support Inbox & App Error Center (2026-11-12)

After the Razorpay commerce migration, apply the additional admin support migration:

1. Open Supabase Dashboard → SQL Editor → New query.
2. Copy the complete file `supabase/migrations/202611120002_admin_support_error_center.sql` from GitHub.
3. Run it once. It creates the support conversation/message tables and app error report table, with user-scoped RLS and admin-only RPCs.
4. Deploy the updated static website/admin files from the repository (GitHub Pages will publish after the main-branch merge).

The user-facing app then shows a Support button for signed-in users. Messages are stored in Supabase and appear in Admin → Customer Support. Admin replies are written to the same conversation. Runtime JavaScript errors and unhandled promise rejections from signed-in sessions are recorded in Admin → App Errors. This does not capture every native Android crash; native crash reporting requires a dedicated Android crash SDK.

Do not put payment credentials, passwords, OTPs, or other secrets in support messages.
