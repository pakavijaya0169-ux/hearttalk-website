// Supabase Edge Function: livekit-token
// Required Edge Function secrets: LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET
// Deploy: supabase functions deploy livekit-token
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { AccessToken } from "npm:livekit-server-sdk@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authorization = req.headers.get("Authorization") || "";
    const jwt = authorization.replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "Sign in is required." }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const livekitUrl = Deno.env.get("LIVEKIT_URL");
    const apiKey = Deno.env.get("LIVEKIT_API_KEY");
    const apiSecret = Deno.env.get("LIVEKIT_API_SECRET");
    if (!supabaseUrl || !anonKey || !livekitUrl || !apiKey || !apiSecret) {
      console.error("Missing Supabase or LiveKit environment configuration.");
      return json({ error: "LiveKit server is not configured. Ask the project owner to add the required Edge Function secrets." }, 503);
    }

    const supabase = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await supabase.auth.getUser(jwt);
    const user = authData?.user;
    if (authError || !user) return json({ error: "Your session is invalid. Please sign in again." }, 401);

    const body = await req.json().catch(() => ({}));
    const roomName = typeof body.room === "string" ? body.room.trim() : "";
    if (!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(roomName)) {
      return json({ error: "A valid live room ID is required." }, 400);
    }

    const { data: room, error: roomError } = await supabase
      .from("live_rooms").select("id,host_id,status,title").eq("id", roomName).maybeSingle();
    if (roomError || !room) return json({ error: "Live room not found." }, 404);
    if (room.status === "ended") return json({ error: "This live room has ended." }, 410);
    if (room.status !== "live" && room.host_id !== user.id) {
      return json({ error: "This room is not live yet." }, 403);
    }

    const identity = user.id;
    const token = new AccessToken(apiKey, apiSecret, {
      identity,
      name: typeof body.username === "string" ? body.username.slice(0, 80) : "HeartTalk member",
      ttl: "15m",
    });
    token.addGrant({
      roomJoin: true,
      room: room.id,
      canPublish: room.host_id === user.id,
      canSubscribe: true,
      canPublishData: true,
    });
    const signedToken = await token.toJwt();
    return json({ url: livekitUrl, token: signedToken, room: room.id });
  } catch (error) {
    console.error("livekit-token error:", error);
    return json({ error: "Could not create a secure live room token." }, 500);
  }
});
