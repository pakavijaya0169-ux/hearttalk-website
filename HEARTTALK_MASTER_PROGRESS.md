# HEARTTALK — MASTER PROGRESS

Last updated: 2026-11-25
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

## Other product decisions / requirements to preserve
- Host/platform revenue share: host 60%, platform 40% (latest agreed).
- Call pricing discussed: audio 2 coins/minute; video 5 coins/minute.
- Login bonus: 10 coins.
- Product goals include chat, audio/video calls, live streaming, wallet/coins, gifts, admin dashboard, host earnings, withdrawals, moderation and safety.
- User wants horizontal scrolling host profiles on the home screen and language-based host discovery.
- App store positioning must accurately describe social communication/friendship. Do not disguise a dating or paid-host model if that is what the actual functionality amounts to; review platform policies carefully.

## Important security rules
- Never write secrets or tokens into this file, source code, logs, screenshots, or chat.
- The GitHub Actions secret name is `SUPABASE_ACCESS_TOKEN`; its value must remain private.
- The user created a Supabase Personal Access Token with broad project access and no expiry. Recommend revoking/rotating it if it is exposed or no longer needed; do not request its value.
- Do not run production payment tests without explicit confirmation of provider approval and correct live credentials.

## Handoff instruction for the next ChatGPT conversation
Read this file first, then inspect the live GitHub repository and latest GitHub Actions runs before changing anything. All three Cashfree Edge Functions are deployed successfully (run `45539338698`). Frontend verification invocation has been inspected. Next verify the remote RPC migration and Cashfree live approval/credentials/webhook signing secret before any live charge. Never expose secrets or run a production payment without those checks.
