// Supabase Edge Function: get-turn-credentials
// Store METERED_TURN_API_KEY in Supabase Edge Function Secrets.
// The Metered key is never sent to the browser.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), {
    status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return new Response(JSON.stringify({ error: "Authentication required" }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const meteredKey = Deno.env.get("METERED_TURN_API_KEY");
    if (!meteredKey) throw new Error("Server TURN credential is not configured.");

    const supabase = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await supabase.auth.getUser(token);
    if (userError || !userData.user) return new Response(JSON.stringify({ error: "Invalid session" }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

    const response = await fetch(
      "https://hearttalkcalls.metered.live/api/v1/turn/credentials?apiKey=" + encodeURIComponent(meteredKey),
    );
    if (!response.ok) throw new Error("TURN provider request failed.");
    const iceServers = await response.json();
    if (!Array.isArray(iceServers) || iceServers.length === 0) throw new Error("No TURN servers were returned.");

    return new Response(JSON.stringify({ iceServers }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  } catch (error) {
    console.error("get-turn-credentials:", error);
    return new Response(JSON.stringify({ error: "Could not prepare secure calling connection." }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  }
});
