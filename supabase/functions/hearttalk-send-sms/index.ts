// Supabase Auth Send SMS Hook for HeartTalk.
// Supabase generates and verifies the OTP and creates the Auth session.
// This function only delivers the Auth-generated OTP through a configured SMS gateway.
// Required secrets: SEND_SMS_HOOK_SECRETS, SMS_GATEWAY_URL, SMS_GATEWAY_API_KEY.
import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: { http_code: 405, message: "Method not allowed" } }, 405);
  try {
    const raw = await req.text();
    const secret = Deno.env.get("SEND_SMS_HOOK_SECRETS");
    const gateway = Deno.env.get("SMS_GATEWAY_URL");
    const gatewayKey = Deno.env.get("SMS_GATEWAY_API_KEY");
    if (!secret || !gateway || !gatewayKey) {
      console.error("Send SMS hook secrets are not configured");
      return json({ error: { http_code: 503, message: "SMS delivery is not configured" } }, 503);
    }
    const hookSecret = secret.split("|")[0].replace(/^v1,whsec_/, "");
    const wh = new Webhook(hookSecret);
    const event = wh.verify(raw, Object.fromEntries(req.headers)) as {
      user?: { phone?: string };
      sms?: { otp?: string };
    };
    const phone = event.user?.phone;
    const otp = event.sms?.otp;
    if (!phone || !/^\+[1-9]\d{7,14}$/.test(phone) || !otp || !/^\d{4,8}$/.test(otp)) {
      return json({ error: { http_code: 400, message: "Invalid SMS hook payload" } }, 400);
    }
    const response = await fetch(gateway, {
      method: "POST",
      headers: { Authorization: "Bearer " + gatewayKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        to: phone,
        message: "Your HeartTalk verification code is " + otp + ". Do not share this code."
      })
    });
    if (!response.ok) {
      console.error("SMS gateway returned status", response.status);
      return json({ error: { http_code: 502, message: "SMS provider failed to accept the message" } }, 502);
    }
    return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (error) {
    console.error("Send SMS hook failed", error);
    return json({ error: { http_code: 400, message: "Invalid or unverifiable Auth hook request" } }, 400);
  }
});
