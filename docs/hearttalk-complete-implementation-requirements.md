# HeartTalk Complete Implementation Requirements

This checklist is the product specification requested by Vijaya. It is not a claim that all features are implemented or activated.

## Male user flow
- Email OTP must arrive in Inbox (deliverability depends on Supabase/provider configuration; SPF/DKIM/DMARC and SMTP settings must be verified).
- After OTP: accept Terms and Conditions, then choose language, then home.
- One-time login bonus: 10 coins per account, idempotent.
- Home: active approved female Hosts; language preference filter; side-scrolling/auto-scroll Host cards.
- Host profile actions: chat, voice call, video call.
- Voice billing: 1 coin per completed 60-second block; 56 seconds costs zero.
- Video billing: 2 coins per completed 60-second block; 56 seconds costs zero.
- Chat billing: 4 coins per completed 5-minute block; 2.5 minutes costs zero.
- Server timestamps and atomic ledger operations are authoritative. Client clocks/prices/durations cannot authorize charges.
- Coin-only wallet for ordinary users; no cash wallet or withdrawal UI.
- Cashfree: verify webhook signature, transaction state and idempotency before wallet credit. ₹20 package grants 25 coins (20 paid + 5 bonus); target webhook processing/credit within 30 seconds, but provider delivery latency cannot be guaranteed.
- Busy Host must show Busy and prevent a second call.
- Unanswered ringing call auto-ends at 60 seconds and records missed call.
- Incoming call/message/gift/live room/offers notifications. Push delivery requires supported device/browser permission and service worker setup.
- Screen capture prevention is best-effort only; cannot guarantee screenshots/recording blocked on every platform.
- Network reconnect and media diagnostics; critical errors logged and sent to Admin WhatsApp via configured provider.

## Host (female) flow
- Email OTP, accept Terms, mandatory 3-second video selfie submission.
- Host access/earning only after Admin approval and eligible KYC; 18+, female profile, approved selfie.
- Host cash wallet shows earnings, available/pending/withdrawable, earned coins, transaction history, gifts, call/chat earnings.
- Example display: 50 coins earned = ₹25 (at 50% Host share); platform split must not be exposed to Hosts or ordinary users.
- First withdrawal requires bank details and identity/KYC information, stored securely and access-limited.
- Minimum withdrawal ₹500; weekly limit/approval rules; payouts stay disabled until compliance approval and provider setup.
- Live Room Host must receive at least one gift to fulfill the requested room participation condition; do not fabricate gift receipt.
- Top 3 earnings ranks show Gold/Silver/Bronze Host tags only; exact earnings not public.
- Support/report path and notifications.

## Live rooms
- Exactly one Host per room; maximum 5 participants total unless product definition clarifies otherwise.
- Host active/live and eligible before room creation.
- Gifts deduct sender coins; Host and platform shares recorded server-side 50/50; split is visible only to Admin.
- Prevent room capacity race conditions, duplicate Host/room, and duplicate gift credit.

## Admin
- Host approval/selfie/KYC queue, suspend/reactivate.
- Withdraw approvals; payment reconciliation and failed payments.
- Daily Host/platform earnings, coin circulation, users by gender, active users, approved/pending Hosts, active calls, active live rooms, room participants, gift metrics.
- Offers, push notifications, reports, complaints, error/security logs.
- Revenue split is Admin-only.

## Security and operational gates
- No live withdrawal activation before compliance approval.
- Never trust browser timers, client-side prices, client-supplied durations, or success callbacks.
- Every financial mutation must be transactional, idempotent, and auditable.
- Supabase SQL migrations and tests must be reviewed and run in the project; repository work alone does not activate database changes.
- End-to-end tests must cover short calls (<60 sec), 60 sec, 61 sec, chat <5 min, 5 min, repeated webhook, insufficient coins, busy Host, 60-sec missed call, room capacity, duplicate gifts, and Admin-only revenue visibility.
