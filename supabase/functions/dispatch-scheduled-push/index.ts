// HeartTalk scheduled push dispatcher. Invoke from a trusted cron with SCHEDULED_PUSH_SECRET.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
function constantTimeEqual(a:string,b:string){if(a.length!==b.length)return false;let mismatch=0;for(let i=0;i<a.length;i++)mismatch|=a.charCodeAt(i)^b.charCodeAt(i);return mismatch===0;}

Deno.serve(async(req)=>{
  if(req.method!=="POST")return json({error:"POST required"},405);
  const secret=Deno.env.get("SCHEDULED_PUSH_SECRET")||"";
  const bearer=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!secret||!constantTimeEqual(bearer,secret))return json({error:"Unauthorized"},401);
  const url=Deno.env.get("SUPABASE_URL"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!service)return json({error:"Server configuration missing"},503);
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const senderUrl=url+"/functions/v1/send-hearttalk-push";
  const now=new Date().toISOString();
  const {data:campaigns,error}=await admin.from("hearttalk_push_campaigns")
    .select("id").eq("status","scheduled").lte("scheduled_at",now).order("scheduled_at",{ascending:true}).limit(50);
  if(error)return json({error:"Could not load due campaigns"},500);
  let attempted=0,succeeded=0,failed=0;
  for(const campaign of campaigns||[]){
    attempted++;
    try{
      const response=await fetch(senderUrl,{method:"POST",headers:{"Authorization":"Bearer "+secret,"Content-Type":"application/json"},body:JSON.stringify({campaign_id:campaign.id})});
      const result=await response.json().catch(()=>({}));
      if(response.ok&&result.ok)succeeded++;else failed++;
    }catch{failed++;}
  }
  return json({ok:true,attempted,succeeded,failed,checked_at:now});
});
