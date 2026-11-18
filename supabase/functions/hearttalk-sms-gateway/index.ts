// Private API for the dedicated Android SIM gateway phone.
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, HEARTTALK_SIM_GATEWAY_TOKEN.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const expected = Deno.env.get("HEARTTALK_SIM_GATEWAY_TOKEN");
  const supplied = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!expected || !supplied || supplied !== expected) return json({ error: "Unauthorized" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Server not configured" }, 503);
  const db = createClient(url, serviceKey, { auth: { persistSession: false } });

  try {
    const body = await req.json().catch(() => ({}));
    if (body.action === "ack" && Number.isInteger(body.id)) {
      const status = body.sent === true ? "sent" : "failed";
      const { error } = await db.from("hearttalk_sms_queue").update({
        status,
        sent_at: status === "sent" ? new Date().toISOString() : null,
        error: status === "failed" ? String(body.error || "SMS send failed").slice(0, 300) : null
      }).eq("id", body.id).eq("status", "processing");
      if (error) throw error;
      return json({ ok: true });
    }

    const { data: job, error: readError } = await db.from("hearttalk_sms_queue")
      .select("id,phone,message")
      .eq("status", "pending")
      .gt("expires_at", new Date().toISOString())
      .order("created_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (readError) throw readError;
    if (!job) return json({ job: null });

    const { data: claimed, error: claimError } = await db.from("hearttalk_sms_queue")
      .update({ status: "processing", locked_at: new Date().toISOString() })
      .eq("id", job.id)
      .eq("status", "pending")
      .select("id,phone,message")
      .maybeSingle();
    if (claimError) throw claimError;
    return json({ job: claimed || null });
  } catch (error) {
    console.error("SIM gateway API failed", error);
    return json({ error: "Gateway request failed" }, 500);
  }
});
