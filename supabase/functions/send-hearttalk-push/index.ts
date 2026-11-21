// HeartTalk FCM HTTP v1 sender
// Deploy as: supabase/functions/send-hearttalk-push/index.ts
// Required secret: FIREBASE_SERVICE_ACCOUNT_JSON (entire service-account JSON)
// Uses Supabase's built-in SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function b64url(input: Uint8Array | string) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function pemToBytes(pem: string) {
  const base64 = pem.replace(/-----BEGIN PRIVATE KEY-----/g, "").replace(/-----END PRIVATE KEY-----/g, "").replace(/\s/g, "");
  const raw = atob(base64);
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
async function googleAccessToken(sa: Record<string, string>) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = header + "." + claims;
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToBytes(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned),
  ));
  const assertion = unsigned + "." + b64url(signature);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const data = await response.json();
  if (!response.ok || !data.access_token) throw new Error(data.error_description || data.error || "Google OAuth token request failed");
  return data.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Admin sign-in required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceKey);
  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY") || serviceKey, {
    global: { headers: { Authorization: auth } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "Invalid session" }, 401);
  const { data: role, error: roleError } = await adminClient
    .from("hearttalk_user_roles").select("role").eq("user_id", userData.user.id).eq("role", "admin").maybeSingle();
  if (roleError || !role) return json({ error: "Admin role required" }, 403);

  let body: { campaign_id?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  if (!body.campaign_id) return json({ error: "campaign_id is required" }, 400);

  const { data: campaign, error: campaignError } = await adminClient
    .from("hearttalk_push_campaigns").select("id,title,body,image_url,audience,status,scheduled_at")
    .eq("id", body.campaign_id).maybeSingle();
  if (campaignError || !campaign) return json({ error: campaignError?.message || "Campaign not found" }, 404);
  if (!["queued", "scheduled"].includes(campaign.status)) return json({ error: "Campaign must be queued or scheduled before sending" }, 409);
  if (campaign.status === "scheduled" && (!campaign.scheduled_at || new Date(campaign.scheduled_at).getTime() > Date.now())) {
    return json({ error: "Scheduled campaign is not due yet.", scheduled_at: campaign.scheduled_at }, 409);
  }

  const audience = campaign.audience as string;
  if (!["all", "female", "male"].includes(audience)) {
    return json({ error: "This sender currently supports All users, Female users and Male users. Choose one of these audiences." }, 400);
  }

  // Atomic claim prevents concurrent invocations from sending the same campaign twice.
  const { data: claimed, error: markError } = await adminClient.from("hearttalk_push_campaigns")
    .update({ status: "sending", last_error: null, updated_at: new Date().toISOString() })
    .eq("id", campaign.id).in("status", ["queued", "scheduled"]).select("id").maybeSingle();
  if (markError) return json({ error: markError.message }, 500);
  if (!claimed) return json({ error: "Campaign was already claimed or its status changed." }, 409);

  try {
    let allowedUserIds: string[] | null = null;
    if (audience === "female" || audience === "male") {
      const { data: profiles, error } = await adminClient.from("profiles").select("id").eq("gender", audience);
      if (error) throw new Error("Could not filter profiles by gender: " + error.message);
      allowedUserIds = (profiles || []).map((p: { id: string }) => p.id);
      if (!allowedUserIds.length) {
        await adminClient.from("hearttalk_push_campaigns").update({
          status: "sent", delivery_count: 0, failure_count: 0, sent_at: new Date().toISOString(),
          last_error: "No profiles matched this gender audience.", updated_at: new Date().toISOString(),
        }).eq("id", campaign.id);
        return json({ ok: true, delivered: 0, failed: 0, message: "No profiles matched this audience." });
      }
    }

    let tokens: { id: string; user_id: string; fcm_token: string }[] = [];
    if (allowedUserIds === null) {
      const { data, error } = await adminClient.from("hearttalk_push_tokens")
        .select("id,user_id,fcm_token").eq("enabled", true);
      if (error) throw error;
      tokens = data || [];
    } else {
      for (let i = 0; i < allowedUserIds.length; i += 500) {
        const ids = allowedUserIds.slice(i, i + 500);
        const { data, error } = await adminClient.from("hearttalk_push_tokens")
          .select("id,user_id,fcm_token").eq("enabled", true).in("user_id", ids);
        if (error) throw error;
        tokens.push(...(data || []));
      }
    }

    if (!tokens.length) {
      await adminClient.from("hearttalk_push_campaigns").update({
        status: "failed", delivery_count: 0, failure_count: 0,
        last_error: "No registered, enabled FCM device tokens for this audience.",
        updated_at: new Date().toISOString(),
      }).eq("id", campaign.id);
      return json({ error: "No registered device tokens for this audience. Ask users to enable notifications first." }, 409);
    }

    const rawServiceAccount = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
    if (!rawServiceAccount) throw new Error("FIREBASE_SERVICE_ACCOUNT_JSON secret is missing");
    const sa = JSON.parse(rawServiceAccount);
    if (!sa.project_id || !sa.client_email || !sa.private_key) throw new Error("Firebase service account JSON is missing project_id, client_email or private_key");
    const accessToken = await googleAccessToken(sa);

    let delivered = 0, failed = 0;
    const failedTokenIds: string[] = [];
    for (const token of tokens) {
      const fcmResponse = await fetch(
        `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
        {
          method: "POST",
          headers: { Authorization: "Bearer " + accessToken, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token: token.fcm_token,
              notification: { title: campaign.title, body: campaign.body, ...(campaign.image_url ? { image: campaign.image_url } : {}) },
              data: {
                title: campaign.title, body: campaign.body,
                ...(campaign.image_url ? { image_url: campaign.image_url } : {}),
                url: "https://pakavijaya0169-ux.github.io/hearttalk-website/",
                tag: campaign.id,
              },
              webpush: {
                notification: {
                  title: campaign.title, body: campaign.body,
                  icon: "https://pakavijaya0169-ux.github.io/hearttalk-website/icons/icon-192.svg",
                  ...(campaign.image_url ? { image: campaign.image_url } : {}),
                },
                fcm_options: { link: "https://pakavijaya0169-ux.github.io/hearttalk-website/" },
              },
            },
          }),
        },
      );
      if (fcmResponse.ok) delivered++;
      else {
        failed++;
        const err = await fcmResponse.json().catch(() => ({}));
        const status = err?.error?.details?.[0]?.errorCode || err?.error?.status;
        if (status === "UNREGISTERED") failedTokenIds.push(token.id);
      }
    }

    if (failedTokenIds.length) {
      await adminClient.from("hearttalk_push_tokens").update({ enabled: false, updated_at: new Date().toISOString() }).in("id", failedTokenIds);
    }
    await adminClient.from("hearttalk_push_campaigns").update({
      status: failed === tokens.length ? "failed" : "sent",
      delivery_count: delivered, failure_count: failed,
      sent_at: new Date().toISOString(),
      last_error: failed ? `${failed} device(s) failed; invalid tokens disabled where identified.` : null,
      updated_at: new Date().toISOString(),
    }).eq("id", campaign.id);
    return json({ ok: true, delivered, failed, audience });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await adminClient.from("hearttalk_push_campaigns").update({
      status: "failed", last_error: message.slice(0, 1000), updated_at: new Date().toISOString(),
    }).eq("id", campaign.id);
    return json({ error: message }, 500);
  }
});
