// Supabase Auth Send SMS Hook: queue Supabase-generated OTP for the owner's SIM gateway.
import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: { http_code: 405, message: "Method not allowed" } }, 405);
  try {
    const raw = await req.text();
    const secret = Deno.env.get("SEND_SMS_HOOK_SECRETS");
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!secret || !url || !serviceKey) throw new Error("Missing required server secrets");

    const hookSecret = secret.split("|")[0].replace(/^v1,whsec_/, "");
    const wh = new Webhook(hookSecret);
    const event = wh.verify(raw, Object.fromEntries(req.headers)) as {
      user?: { phone?: string | null };
      sms?: { otp?: string | null };
    };

    const rawPhone = String(event.user?.phone ?? "").trim();
    const otp = String(event.sms?.otp ?? "").trim();
    // Supabase normally supplies E.164. Normalize a plain Indian 10-digit number defensively.
    const digits = rawPhone.replace(/[^0-9]/g, "");
    const phone = rawPhone.startsWith("+")
      ? "+" + digits
      : digits.length === 10
        ? "+91" + digits
        : digits.length === 12 && digits.startsWith("91")
          ? "+" + digits
          : "";

    if (!/^\\+[1-9]\\d{7,14}$/.test(phone) || !/^\\d{4,8}$/.test(otp)) {
      console.error("Invalid SMS hook fields", {
        hasUser: Boolean(event.user),
        hasSms: Boolean(event.sms),
        phonePresent: Boolean(rawPhone),
        phoneLength: digits.length,
        otpPresent: Boolean(otp),
        otpLength: otp.length,
      });
      return json({ error: { http_code: 400, message: "Invalid SMS hook payload: phone or OTP missing/invalid" } }, 400);
    }

    const db = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { error } = await db.from("hearttalk_sms_queue").insert({
      phone,
      message: "Your HeartTalk verification code is " + otp + ". Do not share this code."
    });
    if (error) throw error;
    return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (error) {
    console.error("HeartTalk SMS queue hook failed", error);
    return json({ error: { http_code: 503, message: "SMS could not be queued" } }, 503);
  }
});