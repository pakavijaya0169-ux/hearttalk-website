// HeartTalk OTP request endpoint. SMS is sent only through a configured provider adapter.
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, OTP_PEPPER,
// SMS_GATEWAY_URL, SMS_GATEWAY_API_KEY. Provider contract: POST JSON {to, message},
// Authorization: Bearer <key>, 2xx means accepted. Do not expose OTP in API response.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, "0")).join("");
async function digest(value: string, pepper: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(pepper), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const gateway = Deno.env.get("SMS_GATEWAY_URL"), gatewayKey = Deno.env.get("SMS_GATEWAY_API_KEY");
  const pepper = Deno.env.get("OTP_PEPPER");
  if (!gateway || !gatewayKey || !pepper) return json({ error: "sms_delivery_not_configured", message: "A real SMS gateway and OTP_PEPPER must be configured before sending OTPs." }, 503);
  try {
    const { phone } = await req.json();
    if (typeof phone !== "string" || !/^\+[1-9]\d{7,14}$/.test(phone)) return json({ error: "invalid_phone" }, 400);
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: recent } = await supabase.from("hearttalk_phone_otps").select("created_at").eq("phone_e164", phone).is("consumed_at", null).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (recent && Date.now() - new Date(recent.created_at).getTime() < 60_000) return json({ error: "resend_cooldown", retry_after_seconds: 60 }, 429);
    const { count } = await supabase.from("hearttalk_phone_otps").select("id", { count: "exact", head: true }).eq("phone_e164", phone).gte("created_at", new Date(Date.now() - 60 * 60_000).toISOString());
    if ((count ?? 0) >= 5) return json({ error: "rate_limited" }, 429);
    const otp = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, "0");
    const otpHash = await digest(phone + ":" + otp, pepper);
    const { error: insertError } = await supabase.from("hearttalk_phone_otps").insert({ phone_e164: phone, otp_hash: otpHash, expires_at: new Date(Date.now() + 5 * 60_000).toISOString() });
    if (insertError) throw insertError;
    const sent = await fetch(gateway, { method: "POST", headers: { "Authorization": "Bearer " + gatewayKey, "Content-Type": "application/json" }, body: JSON.stringify({ to: phone, message: "Your HeartTalk verification code is " + otp + ". It expires in 5 minutes. Do not share it." }) });
    if (!sent.ok) {
      await supabase.from("hearttalk_phone_otps").update({ consumed_at: new Date().toISOString() }).eq("phone_e164", phone).eq("otp_hash", otpHash);
      return json({ error: "sms_delivery_failed" }, 502);
    }
    return json({ ok: true, expires_in_seconds: 300, resend_after_seconds: 60 });
  } catch (e) {
    console.error("OTP request failed", e);
    return json({ error: "internal_error" }, 500);
  }
});
