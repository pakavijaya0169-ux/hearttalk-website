// Scheduled HeartTalk push dispatcher. Configure an external/Supabase Cron trigger to POST every minute.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
Deno.serve(async(req)=>{
 if(req.method!=="POST")return json({error:"POST required"},405);
 const secret=Deno.env.get("SCHEDULED_PUSH_SECRET")||"";
 const auth=req.headers.get("Authorization")||"";
 if(!secret||auth!=="Bearer "+secret)return json({error:"Unauthorized"},401);
 const url=Deno.env.get("SUPABASE_URL")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
 const now=new Date().toISOString();
 const {data:due,error}=await admin.from("hearttalk_push_campaigns").select("id")
  .eq("status","scheduled").lte("scheduled_at",now).order("scheduled_at",{ascending:true}).limit(25);
 if(error)return json({error:"Could not load due campaigns"},500);
 const results=[];
 for(const campaign of (due||[])){
  try{
   const response=await fetch(url+"/functions/v1/send-hearttalk-push",{method:"POST",headers:{"Authorization":"Bearer "+secret,"Content-Type":"application/json"},body:JSON.stringify({campaign_id:campaign.id})});
   const payload=await response.json().catch(()=>({}));
   results.push({campaign_id:campaign.id,status:response.status,ok:response.ok,result:payload});
  }catch(e){results.push({campaign_id:campaign.id,ok:false,error:String(e)});}
 }
 return json({checked:(due||[]).length,results});
});