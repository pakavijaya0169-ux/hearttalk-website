# HeartTalk Cashfree Production Setup

**Do not commit or share API credentials in GitHub, chat, screenshots, or browser code.**

## 1. Supabase Edge Function Secrets

In Supabase Dashboard → Project → Edge Functions → Secrets, set these values:

- `CASHFREE_CLIENT_ID`: Live App ID from Cashfree
- `CASHFREE_CLIENT_SECRET`: Live Secret Key from Cashfree
- `CASHFREE_ENV`: `production`
- `CASHFREE_WEBHOOK_SECRET`: the webhook signing secret generated/configured for the Cashfree webhook

Keep existing Supabase service-role and anon secrets intact.

## 2. Deploy these Edge Functions

Deploy the following from the repository (or your normal Supabase deploy process):

- `create-cashfree-order`
- `verify-cashfree-payment`
- `cashfree-webhook`

The website checkout mode is selected from the server response, so `CASHFREE_ENV` must be the same environment as the credentials.

## 3. Cashfree Webhook

In Cashfree Dashboard, create a payment webhook using this URL:

`https://dognojmymhlaewrjqswz.supabase.co/functions/v1/cashfree-webhook`

Subscribe to the payment-success event(s) that Cashfree provides for your account. Use the webhook signing secret in the `CASHFREE_WEBHOOK_SECRET` Supabase secret.

The webhook independently fetches and validates the order and successful payment on Cashfree before calling the coin-credit RPC. It must not rely on browser return data.

## 4. Go-live checklist

- Confirm Cashfree account approval covers the HeartTalk business model and coin purchases.
- Confirm live API credentials and webhook signing secret.
- Deploy all 3 functions.
- Configure secrets.
- Configure the webhook.
- Confirm final legal/refund/coin terms and support details before accepting real payments.
- Perform controlled payment verification only at the final testing stage.

**Current repository changes are committed, but functions are not deployed and live payments have not been tested.**
