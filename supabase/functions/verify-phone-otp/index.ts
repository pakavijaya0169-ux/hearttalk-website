// Verifies a challenge created by request-phone-otp. Does not create a Supabase Auth session.
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
  try {
    const { phone, code } = await req.json();
    if (typeof phone !== "string" || !/^\\+[1-9]\\d{7,14}$/.test(phone) || typeof code !== "string" || !/^\\d{6}$/.test(code)) return json({ error: "invalid_input" }, 400);
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const pepper = Deno.env.get("OTP_PEPPER");
    if (!pepper) return json({ error: "otp_backend_not_configured" }, 503);
    const { data: challenge, error } = await supabase.from("hearttalk_phone_otps").select("id,otp_hash,expires_at,attempts").eq("phone_e164", phone).is("consumed_at", null).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (error) throw error;
    if (!challenge) return json({ error: "invalid_or_expired_code" }, 400);
    if (new Date(challenge.expires_at).getTime() < Date.now() || challenge.attempts >= 5) {
      await supabase.from("hearttalk_phone_otps").update({ consumed_at: new Date().toISOString() }).eq("id", challenge.id);
      return json({ error: "invalid_or_expired_code" }, 400);
    }
    const candidate = await digest(phone + ":" + code, pepper);
    if (candidate !== challenge.otp_hash) {
      await supabase.from("hearttalk_phone_otps").update({ attempts: challenge.attempts + 1 }).eq("id", challenge.id);
      return json({ error: "invalid_or_expired_code" }, 400);
    }
    await supabase.from("hearttalk_phone_otps").update({ consumed_at: new Date().toISOString() }).eq("id", challenge.id);
    return json({ ok: true, phone_verified: true, note: "Challenge verified. A trusted Supabase Auth session exchange must be completed before enabling app login." });
  } catch (e) {
    console.error("OTP verification failed", e);
    return json({ error: "internal_error" }, 500);
  }
});
