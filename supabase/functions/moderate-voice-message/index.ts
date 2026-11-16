// HeartTalk voice-message safety moderation.
// Required Supabase Edge Function secret: OPENAI_API_KEY
// Receives a voice message, transcribes it, and blocks delivery if an Indian mobile number is spoken.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function containsIndianMobileNumber(value: string): boolean {
  const text = String(value || "");
  return /(?:^|[^0-9])(?:\+?91[\s().-]*)?0?[6-9](?:[\s().-]*[0-9]){9}(?![0-9])/.test(text);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Please sign in first." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!supabaseUrl || !anonKey) return json({ error: "Supabase configuration is missing." }, 500);
  if (!openaiKey) return json({ error: "OPENAI_API_KEY secret is missing in Supabase Edge Function Secrets." }, 500);

  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "Your sign-in session is invalid. Please sign in again." }, 401);

  try {
    const incoming = await req.formData();
    const audio = incoming.get("audio");
    if (!(audio instanceof File)) return json({ error: "Voice audio file is required." }, 400);
    if (!audio.type.startsWith("audio/")) return json({ error: "Only audio files can be checked." }, 415);
    if (audio.size < 1 || audio.size > 12 * 1024 * 1024) return json({ error: "Voice message must be under 12 MB." }, 413);

    const openaiForm = new FormData();
    openaiForm.append("file", audio, audio.name || "hearttalk-voice-message.webm");
    openaiForm.append("model", "gpt-4o-mini-transcribe");
    openaiForm.append("prompt", "Transcribe the speech accurately. This is a safety check for spoken Indian mobile phone numbers. When any phone number is spoken digit by digit or as a number, write its digits together in the transcript. Preserve the spoken words otherwise.");
    const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: "Bearer " + openaiKey },
      body: openaiForm,
    });
    const result = await response.json();
    if (!response.ok) {
      console.error("HeartTalk voice transcription failed:", result?.error?.message || response.status);
      return json({ error: "Voice safety check could not complete. Please try again." }, 502);
    }

    const transcript = String(result?.text || "");
    const blocked = containsIndianMobileNumber(transcript);
    return json({ ok: true, blocked, transcript: blocked ? "" : undefined });
  } catch (error) {
    console.error("HeartTalk voice moderation error:", error);
    return json({ error: "Voice safety check failed. The message was not sent." }, 500);
  }
});
