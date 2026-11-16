// HeartTalk AI notification banner generator
// Deploy as: supabase/functions/generate-hearttalk-banner/index.ts
// Required secret: OPENAI_API_KEY
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Admin sign-in required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "Supabase server configuration is missing" }, 500);
  if (!openaiKey) return json({ error: "OPENAI_API_KEY secret is not configured in Supabase Edge Function Secrets" }, 500);

  const admin = createClient(supabaseUrl, serviceKey);
  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY") || serviceKey, {
    global: { headers: { Authorization: auth } },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "Invalid sign-in session" }, 401);
  // Match the same admin-role check used by the HeartTalk Admin Dashboard.
  // Read through the signed-in user's JWT so the dashboard and function use identical RLS-visible data.
  const { data: role, error: roleError } = await userClient.from("hearttalk_user_roles")
    .select("role").eq("user_id", userData.user.id).maybeSingle();
  if (roleError) {
    console.error("HeartTalk banner admin-role lookup failed:", roleError.message);
    return json({ error: "Could not verify admin role: " + roleError.message }, 403);
  }
  if (role?.role !== "admin") {
    console.error("HeartTalk banner request rejected: admin role missing for user", userData.user.id);
    return json({ error: "This signed-in account does not have the HeartTalk admin role." }, 403);
  }

  let input: { prompt?: string };
  try { input = await req.json(); } catch { return json({ error: "Invalid JSON request" }, 400); }
  const prompt = String(input.prompt || "").trim();
  if (prompt.length < 8 || prompt.length > 1800) {
    return json({ error: "Prompt must be between 8 and 1800 characters." }, 400);
  }

  const fullPrompt = [
    "Create a polished, premium landscape promotional banner for the HeartTalk social connection app.",
    "Brand style: deep plum and dark purple background (#3A1038), sunset pink and peach accents (#FF5E7E), soft cream highlights.",
    "Use a refined modern composition, crisp lighting, attractive visual hierarchy, tasteful heart-inspired abstract motifs, and generous safe margins.",
    "Make it suitable for a mobile push notification campaign and an in-app promotional banner.",
    "Do not include fake UI screenshots, QR codes, watermarks, or tiny unreadable text. If the prompt requests exact wording, render it clearly and spell it exactly.",
    "User's design brief: " + prompt,
  ].join("\n");

  try {
    const response = await fetch("https://api.openai.com/v1/images/generations", {
      method: "POST",
      headers: { Authorization: "Bearer " + openaiKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "gpt-image-2.5-flare",
        prompt: fullPrompt,
        size: "1536x1024",
        quality: "medium",
        output_format: "png",
        n: 1,
      }),
    });
    const result = await response.json();
    if (!response.ok) {
      const detail = result?.error?.message || "OpenAI image generation failed";
      return json({ error: detail }, response.status === 429 ? 429 : 502);
    }
    const encoded = result?.data?.[0]?.b64_json;
    if (!encoded) return json({ error: "OpenAI did not return an image. Please try again." }, 502);

    const binary = atob(encoded);
    const bytes = Uint8Array.from(binary, (ch) => ch.charCodeAt(0));
    const path = "ai-generated/" + userData.user.id + "/" + crypto.randomUUID() + ".png";
    const { error: uploadError } = await admin.storage.from("notification-images").upload(path, bytes, {
      contentType: "image/png",
      upsert: false,
      cacheControl: "31536000",
    });
    if (uploadError) throw new Error("Generated image could not be saved: " + uploadError.message);

    const { data: publicData } = admin.storage.from("notification-images").getPublicUrl(path);
    return json({ ok: true, image_url: publicData.publicUrl, path });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ error: message.slice(0, 900) }, 500);
  }
});
