// Authenticated caller-triggered push for ringing HeartTalk calls.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
function b64url(input:Uint8Array|string){const bytes=typeof input==="string"?new TextEncoder().encode(input):input;let binary="";for(const b of bytes)binary+=String.fromCharCode(b);return btoa(binary).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");}
function pemBytes(pem:string){const raw=atob(pem.replace(/-----BEGIN PRIVATE KEY-----/g,"").replace(/-----END PRIVATE KEY-----/g,"").replace(/\s/g,""));return Uint8Array.from(raw,c=>c.charCodeAt(0));}
async function googleToken(sa:any){const now=Math.floor(Date.now()/1000);const head=b64url(JSON.stringify({alg:"RS256",typ:"JWT"}));const claims=b64url(JSON.stringify({iss:sa.client_email,scope:"https://www.googleapis.com/auth/firebase.messaging",aud:"https://oauth2.googleapis.com/token",iat:now,exp:now+3600}));const unsigned=head+"."+claims;const key=await crypto.subtle.importKey("pkcs8",pemBytes(sa.private_key),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);const sig=new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key,new TextEncoder().encode(unsigned)));const assertion=unsigned+"."+b64url(sig);const response=await fetch("https://oauth2.googleapis.com/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion})});const data=await response.json();if(!response.ok||!data.access_token)throw new Error("FCM OAuth token request failed");return data.access_token;}
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"POST required"},405);
 const auth=req.headers.get("Authorization")||"";if(!auth.startsWith("Bearer "))return json({error:"Sign-in required"},401);
 try{
  const url=Deno.env.get("SUPABASE_URL")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,anon=Deno.env.get("SUPABASE_ANON_KEY")||service;
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:user,error:userError}=await userClient.auth.getUser();if(userError||!user?.user)return json({error:"Invalid session"},401);
  const body=await req.json().catch(()=>({}));const callId=String(body.call_id||"");
  if(!/^[0-9a-f-]{36}$/i.test(callId))return json({error:"Invalid call ID"},400);
  const {data:call,error:callError}=await admin.from("call_sessions").select("id,caller_id,callee_id,call_type,status,created_at").eq("id",callId).maybeSingle();
  if(callError||!call)return json({error:"Call not found"},404);
  if(call.caller_id!==user.user.id)return json({error:"Only the caller may trigger this notification"},403);
  if(call.status!=="ringing"||Date.now()-new Date(call.created_at).getTime()>60000)return json({error:"Call is no longer ringing"},409);
  const {data:tokens,error:tokenError}=await admin.from("hearttalk_push_tokens").select("fcm_token").eq("user_id",call.callee_id).eq("enabled",true);
  if(tokenError)return json({error:"Could not load recipient tokens"},500);
  if(!tokens?.length)return json({sent:0,message:"Recipient has no registered push tokens"});
  const {data:caller}=await admin.from("profiles").select("display_name").eq("id",call.caller_id).maybeSingle();
  const raw=Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");if(!raw)return json({error:"Firebase service account is not configured"},503);
  const sa=JSON.parse(raw);if(!sa.project_id||!sa.client_email||!sa.private_key)return json({error:"Firebase service account invalid"},503);
  const token=await googleToken(sa);let sent=0,failed=0;
  for(const item of tokens){const res=await fetch("https://fcm.googleapis.com/v1/projects/"+sa.project_id+"/messages:send",{method:"POST",headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},body:JSON.stringify({message:{token:item.fcm_token,notification:{title:call.call_type==="video"?"Incoming video call":"Incoming voice call",body:(caller?.display_name||"HeartTalk member")+" is calling you."},data:{title:"Incoming "+call.call_type+" call",body:(caller?.display_name||"HeartTalk member")+" is calling you.",url:"https://pakavijaya0169-ux.github.io/hearttalk-website/",call_id:callId,call_type:call.call_type,tag:"hearttalk-call-"+callId},android:{priority:"high",ttl:"60s"}}})});if(res.ok)sent++;else failed++;}
  return json({sent,failed,call_id:callId});
 }catch(e){console.error("send-hearttalk-call-push",e);return json({error:"Call push delivery failed"},500);}
});