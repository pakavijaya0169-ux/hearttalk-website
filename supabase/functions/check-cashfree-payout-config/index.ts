// Read-only Cashfree Payouts Sandbox connectivity check.
// Never returns credentials or performs a transfer.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});

Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!jwt)return reply({error:"Authentication required"},401);
  const url=Deno.env.get("SUPABASE_URL");
  const anon=Deno.env.get("SUPABASE_ANON_KEY");
  const clientId=Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID");
  const clientSecret=Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
  const env=(Deno.env.get("CASHFREE_PAYOUT_ENV")||"sandbox").toLowerCase();
  if(!url||!anon)return reply({error:"Supabase function configuration is incomplete"},503);

  const auth=createClient(url,anon,{global:{headers:{Authorization:`Bearer ${jwt}`}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:userData,error:userError}=await auth.auth.getUser(jwt);
  if(userError||!userData.user)return reply({error:"Session expired"},401);
  const {data:allowed,error:permissionError}=await auth.rpc("has_hearttalk_admin_permission",{p_permission:"withdrawals.manage"});
  if(permissionError||allowed!==true)return reply({error:"Withdrawal management permission required"},403);

  const missing:string[]=[];
  if(!clientId)missing.push("CASHFREE_PAYOUT_CLIENT_ID");
  if(!clientSecret)missing.push("CASHFREE_PAYOUT_CLIENT_SECRET");
  if(missing.length)return reply({configured:false,environment:env,missing,message:"Cashfree Payouts Sandbox credentials are missing. Add the listed secrets in Supabase Edge Function Secrets; values are never returned."});
  if(env!=="sandbox")return reply({configured:true,environment:env,api_checked:false,message:"Production payout mode is blocked. Set CASHFREE_PAYOUT_ENV=sandbox to run this safe test."},403);

  // GET on a unique, non-existent transfer ID validates API authentication without creating money movement.
  const probeId="HTP_HEARTTALK_CONFIG_CHECK";
  const response=await fetch("https://sandbox.cashfree.com/payout/transfers?transfer_id="+encodeURIComponent(probeId),{
   method:"GET",
   headers:{"Accept":"application/json","x-api-version":"2024-01-01","x-client-id":clientId,"x-client-secret":clientSecret}
  });
  if(response.status===404){
   return reply({configured:true,environment:"sandbox",api_checked:true,credentials_accepted:true,message:"Cashfree Payouts Sandbox credentials accepted. Probe transfer was not found as expected; no transfer was created."});
  }
  if(response.ok){
   return reply({configured:true,environment:"sandbox",api_checked:true,credentials_accepted:true,message:"Cashfree Payouts Sandbox API accepted the credentials. No transfer was created."});
  }
  if(response.status===401||response.status===403){
   return reply({configured:true,environment:"sandbox",api_checked:true,credentials_accepted:false,http_status:response.status,message:"Cashfree rejected the Payouts credentials or this account lacks Payouts API access. Check the separate Payouts Sandbox API credentials and activation."});
  }
  if(response.status===429){
   return reply({configured:true,environment:"sandbox",api_checked:true,credentials_accepted:null,http_status:429,message:"Cashfree Sandbox rate limit reached. Retry the read-only check later."},429);
  }
  console.error("Cashfree Payouts read-only config check returned HTTP",response.status);
  return reply({configured:true,environment:"sandbox",api_checked:true,credentials_accepted:null,http_status:response.status,message:"Cashfree returned an unexpected response. Check Payouts Sandbox API configuration and function logs."},502);
 }catch(error){
  console.error("check-cashfree-payout-config:",error);
  return reply({error:"Cashfree Payouts Sandbox connectivity check failed"},500);
 }
});
